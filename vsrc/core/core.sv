// Module: core
// Description: Configurable in-order issue core with tagged independent completion and ordered retirement.
module core (
    // 端口声明中使用包类型时需要写完整包名
    input  logic                              clk,
    input  logic                              rst,
    // 中断输入须与 clk 同步；异步引脚同步由 SoC 外设负责。
    input  logic                              irq_software, irq_timer, irq_external,
    output logic                              imem_req_valid,
    output logic [core_config_pkg::XLEN-1:0]  imem_req_addr,
    input  logic                              imem_req_ready,
    input  logic                              imem_rsp_valid,
    input  logic [core_config_pkg::FETCH_DATA_W-1:0] imem_rsp_data,
    input  logic                              imem_rsp_error,
    input  logic                              imem_rsp_error_1,
    output logic                              imem_rsp_ready,
    output logic                              dmem_req_valid,
    output logic                              dmem_req_write,
    output core_types_pkg::mem_size_e         dmem_req_size,
    output logic [core_config_pkg::XLEN-1:0]  dmem_req_addr,
    output logic [core_config_pkg::XLEN-1:0]  dmem_req_wdata,
    output logic [core_config_pkg::DBUS_BYTES-1:0] dmem_req_wstrb,
    input  logic                              dmem_req_ready,
    input  logic                              dmem_rsp_valid,
    input  logic [core_config_pkg::XLEN-1:0]  dmem_rsp_rdata,
    input  logic                              dmem_rsp_error,
    output logic                              dmem_rsp_ready,
    // commit 用于退休统计、差分测试和波形调试。
    output logic                              commit_valid,
    output logic [core_config_pkg::XLEN-1:0]  commit_pc,
    output logic [31:0]                       commit_inst,
    output logic [core_config_pkg::GPR_ADDR_W-1:0] commit_rd,
    output logic                              commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0]  commit_rd_data,
    output logic                              commit_exception,
    // 仅在无异常 FENCE.I 退休时失效外部指令缓存；普通 FENCE 不触发。
    output logic                              fence_i_commit,
    output pipeline_pkg::retire_trace_t       commit_trace [2]
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    // 六级流水线的五组级间寄存器；_q 表示真正的时序状态。
    if_d1_t if_d1_q;
    d1_d2_t d1_d2_q;
    d2_ex_t d2_ex_q;
    ex_mem_t ex_mem_q;
    mem_wb_t mem_wb_q;
    // 第二执行槽只承载普通整数ALU，和第一槽按年龄前缀一起推进。
    if_d1_t if_d1_q_1, fetch_packet_1;
    d1_d2_t d1_packet_1, d1_d2_q_1;
    d2_ex_t d2_packet_1, d2_ex_q_1;
    retire_alloc_t alloc_meta_1, head_meta_1;
    retire_id_t alloc_id_1, head_id_1;
    retire_result_t head_result_1;
    retire_completion_t secondary_completion;
    retire_query_t retire_query_1;
    retire_query_result_t retire_query_result_1;
    // legacy 后端没有完成预检路径；固定零 ID 保持端口完整，probe_accept 不参与逻辑。
    retire_id_t legacy_probe_id [5];
    always_comb for (int probe = 0; probe < 5; probe++) legacy_probe_id[probe] = '0;
    gpr_forward_t wb_gpr_write_1;
    csr_forward_t unused_csr_write_1;
    retire_gpr_forward_t secondary_forward;
    xlen_t rs1_data_1, rs2_data_1;
    logic dispatch_valid_1, dispatch_ready_1, dispatch_fire, dispatch_fire_1;
    logic head_valid_1, head_complete_1, queue_retire_fire_1, second_retire_ready;
    logic secondary_valid, secondary_ready, secondary_issue_ready, secondary_busy, secondary_reject;
    logic decode_pair_eligible, issue_pair_eligible, second_operands_ready;
    logic decode_partial, d1_partial, fetch_ready_ctrl;
    logic d1_serialize_ctrl;
    redirect_t d1_redirect_ctrl;
    redirect_t unused_d1_redirect_1;
    logic unused_d1_serialize_1;
    xlen_t predictor_pc, predictor_pc_1;
    pred_info_t prediction_1;
    logic fetch_event_fire, fetch_event_second, fetch_pair_busy;
    logic [1:0] fetch_pop_count;
    logic unused_commit_valid_1, unused_commit_rd_we_1, unused_commit_exception_1;
    xlen_t unused_commit_pc_1, unused_commit_rd_data_1;
    logic [31:0] unused_commit_inst_1;
    gpr_addr_t unused_commit_rd_1;

    if_d1_t fetch_packet;
    d1_d2_t d1_packet;
    d2_ex_t d2_packet;
    ex_mem_t ex_packet;
    mem_wb_t mem_packet;

    // 退休队列是指令年龄与架构提交的唯一所有者；执行流水只携带分配 ID。
    retire_alloc_t alloc_meta, head_meta;
    retire_id_t alloc_id, head_id;
    retire_completion_t wb_completion, lsu_completion, mdu_completion, completion;
    retire_result_t head_result;
    logic dispatch_valid, dispatch_ready;
    logic wb_complete_valid, wb_complete_ready;
    logic lsu_complete_valid, lsu_complete_ready;
    logic mdu_complete_valid, mdu_complete_ready;
    logic complete_valid, complete_ready, complete_reject;
    logic head_valid, head_complete, queue_retire_fire;
    logic [RETIRE_COUNT_W-1:0] retire_occupancy;
    logic retire_recovering, retire_drain_complete;
    retire_query_t retire_query;
    retire_query_result_t retire_query_result;
    logic csr_is_head, lsu_is_head;

    // 预测、重定向与错误路径清理。
    pred_info_t prediction;
    redirect_t d1_redirect;
    redirect_t ex_redirect;
    redirect_t wb_redirect;
    redirect_t selected_redirect;
    pred_update_t predictor_update;
    logic predictor_reset;
    logic d1_flush;
    logic ras_top_valid;
    xlen_t ras_top_addr;
    retire_ras_entry_t ras_entries [RETIRE_ENTRIES];
    logic [RETIRE_IDX_W-1:0] ras_head_slot;

    // GPR 读写和前递。
    xlen_t rs1_data;
    xlen_t rs2_data;
    gpr_forward_t mem_gpr_forward;
    gpr_forward_t wb_gpr_write;
    retire_gpr_forward_t tagged_mem_forward, tagged_wb_forward, tagged_lsu_forward, tagged_mdu_forward;
    xlen_t ex_rs1_value, ex_rs2_value;

    // CSR 读取、旁路、提交与 Trap 状态。
    xlen_t csr_committed_data;
    csr_forward_t mem_csr_forward;
    csr_forward_t wb_csr_write;
    logic trap_enter;
    logic mret_commit;
    xlen_t trap_pc;
    xlen_t trap_cause;
    logic irq_pending, interrupt_take;
    irq_cause_e irq_cause;
    xlen_t interrupt_pc;
    xlen_t trap_tval;
    logic retire_valid;
    logic execution_cancel; // 同步 WB 事件取消年轻执行；排空后的 IRQ 只做全局重定向
    xlen_t mtvec;
    xlen_t mepc;

    // 冒险、存储器反压、序列化与流水线动作。
    logic dispatch_waw_stall;
    logic mem_request_stall;
    logic mem_age_stall;
    logic wb_stall, lsu_wait;
    logic execution_stall, ex_execution_stall;
    logic ex_is_lsu, lsu_issue_valid, lsu_issue_ready;
    logic lsu_busy, lsu_draining, lsu_owner_valid, lsu_request_pending;
    retire_id_t lsu_owner_id;
    lsu_descriptor_t lsu_descriptor;
    xlen_t lsu_store_wdata;
    logic [DBUS_BYTES-1:0] lsu_store_wstrb;
    logic mdu_req_valid;
    logic mdu_req_ready;
    muldiv_req_t mdu_request;
    logic mem_issue_enable;
    logic mdu_operands_ready;
    pipeline_actions_t pipeline_actions;
    logic fetch_ready;
    logic ex_stage_advance;
    logic d1_serialize_req;
    logic ex_serialize_req;
    logic serialize_start;
    logic frontend_flush;
    logic fetch_request_enable;

    // 参数断言仅用于仿真与 lint。
`ifndef SYNTHESIS
    initial begin
        assert ((XLEN == 32) || (XLEN == 64))
            else $error("CORE_XLEN must be 32 or 64");
        assert (ISSUE_WIDTH inside {1,2}) else $fatal(1, "CORE_ISSUE_WIDTH must be 1 or 2");
    end
`endif

    // EX 推进只交付执行结果；D1/EX 纠错不写预测表，取消项不会留下提前训练。
    assign ex_stage_advance = d2_ex_q.valid && (pipeline_actions.ex_mem == PIPE_ADVANCE);

    // FENCE.I 同时清除旧代码的 BTB/PHT 状态，避免代码改写后继续沿旧预测取指。
    assign fence_i_commit = commit_valid && !commit_exception &&
                            (head_meta.sys_op == SYS_FENCE_I);
    assign predictor_reset = rst || fence_i_commit;

    // 单退休口每条正常分支训练一次；快照和实际结果已由同一个完整 ID 汇合。
    predictor_commit_update u_predictor_commit_update (
        .retire_fire(queue_retire_fire), .head_meta, .head_result,
        .update(predictor_update)
    );

    // 分支预测器
    predictor u_predictor (
        .clk,
        .rst(predictor_reset),
        .lookup_pc(predictor_pc), .lookup_pc_1(predictor_pc_1), .prediction_1,
        .ras_top_valid, .ras_top_addr,
        .prediction,
        .update(predictor_update)
    );

    // 真正 WB 事件清全队列；D1/EX 纠错仅重建存活调用链，不取消更老的独立执行单元。
    // IRQ pending 撤销不是恢复事件，FENCE.I 则明确清除两套栈和所有预测表。
    generate
        if (RAS_ENABLE) begin
            ras_controller u_ras_controller (
                .clk, .rst, .clear(fence_i_commit),
                .fetch_fire(fetch_event_fire), .fetch_pc(predictor_pc),
                .fetch_second(fetch_event_second), .prediction_1,
                .predicted_op(prediction.ras_op),
                .normal_retire(queue_retire_fire && !head_result.exc.valid), .head_meta, .head_id,
                .entries(ras_entries), .head_slot(ras_head_slot),
                .recover(selected_redirect.valid || frontend_flush), .flush_all(wb_redirect.valid),
                .ex_exception_valid(ex_serialize_req && ex_packet.exc.valid),
                .ex_exception_id(d2_ex_q.retire_id),
                .dispatch_fire(dispatch_valid && dispatch_ready), .alloc_meta,
                .normal_retire_1(queue_retire_fire_1), .head_id_1,
                .d1_advance(pipeline_actions.d1_d2 == PIPE_ADVANCE && !decode_partial), .d1_packet,
                .top_valid(ras_top_valid), .top_addr(ras_top_addr)
            );
        end else begin
            assign ras_top_valid = 1'b0;
            assign ras_top_addr = '0;
        end
    endgenerate

    // 各功能单元与流水级连线。
    // WB Trap/MRET/FENCE 正常完成序列化；更老的 D1/EX 控制流重定向取消错误路径序列化。
    serialize_controller u_serialize_controller (
        .clk,
        .rst,
        .serialize_start,
        .serialize_complete(wb_redirect.valid),
        .serialize_cancel(selected_redirect.valid && !wb_redirect.valid), // 更老的重定向就能清除
        .frontend_flush,
        .fetch_request_enable
    );

    // IRQ 排空只停新请求，保留已接受的 IF 包；中断撤销不能丢失已推进 PC 对应的指令。
    // 真正进入 Trap 后，仍由 selected_redirect 杀死旧路径取指。
    generate
        if (ISSUE_WIDTH == 1) begin
            assign predictor_pc = imem_req_addr;
            assign predictor_pc_1 = imem_req_addr + xlen_t'(4);
            assign fetch_event_fire = imem_req_valid && imem_req_ready;
            assign fetch_event_second = 1'b0;
            assign fetch_packet_1 = '0;
            assign fetch_pair_busy = 1'b0;
            if_stage u_if_stage (
                .clk,
                .rst,
                .fetch_request_enable(fetch_request_enable && !irq_pending),
                .out_ready(fetch_ready),
                .flush(frontend_flush),
                .redirect(selected_redirect),
                .prediction,
                .out_packet(fetch_packet),
                .imem_req_valid,
                .imem_req_addr,
                .imem_req_ready,
                .imem_rsp_valid,
                .imem_rsp_data,
                .imem_rsp_error,
                .imem_rsp_ready
            );
        end else begin
            fetch_pair_stage u_fetch_pair_stage (
                .clk, .rst, .fetch_request_enable(fetch_request_enable && !irq_pending),
                .flush(frontend_flush), .redirect(selected_redirect), .prediction, .prediction_1,
                .lookup_pc(predictor_pc), .lookup_pc_1(predictor_pc_1),
                .fetch_fire(fetch_event_fire), .fetch_second(fetch_event_second),
                .out_packet(fetch_packet), .out_packet_1(fetch_packet_1), .pop_count(fetch_pop_count),
                .imem_req_valid, .imem_req_addr, .imem_req_ready, .imem_rsp_valid,
                .imem_rsp_data, .imem_rsp_error, .imem_rsp_error_1, .imem_rsp_ready, .busy(fetch_pair_busy),
                .debug_push_count(), .debug_occupancy()
            );
        end
    endgenerate

    // 两个弹性前端寄存组按前缀消费；只发第一条时保留第二条，不丢包或越序。
    assign dispatch_fire = dispatch_valid && dispatch_ready;
    assign dispatch_valid_1 = (ISSUE_WIDTH == 2) && dispatch_valid && issue_pair_eligible;
    assign dispatch_fire_1 = dispatch_valid_1 && dispatch_ready_1;
    assign decode_partial = dispatch_fire && d1_d2_q_1.valid && !dispatch_fire_1;
    assign d1_partial = (ISSUE_WIDTH == 2) && if_d1_q_1.valid && !decode_pair_eligible;
    assign fetch_ready = fetch_ready_ctrl && !decode_partial && !d1_partial;
    assign fetch_pop_count = fetch_ready && fetch_packet.valid ?
        (fetch_packet_1.valid ? 2'd2 : 2'd1) : 2'd0;
    always_comb begin
        d1_redirect_ctrl = d1_redirect;
        d1_redirect_ctrl.valid = d1_redirect.valid && !decode_partial;
        d1_serialize_ctrl = d1_serialize_req && !decode_partial;
    end

    d1_stage u_d1_stage (
        .in_packet(if_d1_q),
        .out_packet(d1_packet),
        .redirect(d1_redirect),
        .serialize_req(d1_serialize_req)
    );
    d1_stage u_d1_stage_1 (
        .in_packet(if_d1_q_1), .out_packet(d1_packet_1),
        .redirect(unused_d1_redirect_1), .serialize_req(unused_d1_serialize_1)
    );
    issue_pairing u_decode_pairing (
        .first_packet(d1_packet), .second_packet(d1_packet_1),
        .second_waw_block(1'b0), .second_operands_ready(1'b1), .pair_eligible(decode_pair_eligible)
    );

    regfile u_regfile (
        .clk,
        .rs1_addr(d1_d2_q.rs1),
        .rs2_addr(d1_d2_q.rs2),
        .rs1_data,
        .rs2_data,
        .write_enable(wb_gpr_write.valid),
        .write_addr(wb_gpr_write.addr),
        .write_data(wb_gpr_write.data),
        .rs1_addr_1(d1_d2_q_1.rs1), .rs2_addr_1(d1_d2_q_1.rs2), .rs1_data_1, .rs2_data_1,
        .write_enable_1(wb_gpr_write_1.valid), .write_addr_1(wb_gpr_write_1.addr),
        .write_data_1(wb_gpr_write_1.data)
    );

    d2_stage u_d2_stage (
        .in_packet(d1_d2_q),
        .rs1_data,
        .rs2_data,
        .alloc_id, .alloc_meta,
        .rs1_dependency(retire_query_result.rs1_dependency),
        .rs2_dependency(retire_query_result.rs2_dependency),
        .out_packet(d2_packet)
    );
    d2_stage u_d2_stage_1 (
        .in_packet(d1_d2_q_1),
        .rs1_data(retire_query_result_1.rs1_dependency.pending ?
            retire_query_result_1.dispatch_rs1.data : rs1_data_1),
        .rs2_data(retire_query_result_1.rs2_dependency.pending ?
            retire_query_result_1.dispatch_rs2.data : rs2_data_1),
        .alloc_id(alloc_id_1), .alloc_meta(alloc_meta_1),
        .rs1_dependency('0), .rs2_dependency('0), .out_packet(d2_packet_1)
    );
    assign second_operands_ready =
        (!retire_query_result_1.rs1_dependency.pending || retire_query_result_1.dispatch_rs1.valid) &&
        (!retire_query_result_1.rs2_dependency.pending || retire_query_result_1.dispatch_rs2.valid);
    issue_pairing u_issue_pairing (
        .first_packet(d1_d2_q), .second_packet(d1_d2_q_1),
        .second_waw_block(retire_query_result_1.waw_block), .second_operands_ready,
        .pair_eligible(issue_pair_eligible)
    );

    // D2 只绑定生产者；EX 查询已分配 ID 的真实值。查询源不经过自身的 WAW/容量许可。
    always_comb begin
        retire_query = '0;
        retire_query.dispatch_valid = d1_d2_q.valid && !d1_d2_q.exc.valid;
        retire_query.rs1_used = d1_d2_q.uop.rs1_used;
        retire_query.rs2_used = d1_d2_q.uop.rs2_used;
        retire_query.rs1 = d1_d2_q.rs1;
        retire_query.rs2 = d1_d2_q.rs2;
        retire_query.rd = d1_d2_q.rd;
        retire_query.gpr_write = d1_d2_q.uop.gpr_write;
        retire_query.consumer_valid = d2_ex_q.valid;
        retire_query.consumer_id = d2_ex_q.retire_id;
        retire_query.rs1_dependency = d2_ex_q.rs1_dependency;
        retire_query.rs2_dependency = d2_ex_q.rs2_dependency;
        retire_query_1 = '0;
        retire_query_1.dispatch_valid = d1_d2_q_1.valid && !d1_d2_q_1.exc.valid;
        retire_query_1.rs1_used = d1_d2_q_1.uop.rs1_used;
        retire_query_1.rs2_used = d1_d2_q_1.uop.rs2_used;
        retire_query_1.rs1 = d1_d2_q_1.rs1;
        retire_query_1.rs2 = d1_d2_q_1.rs2;
        retire_query_1.rd = d1_d2_q_1.rd;
        retire_query_1.gpr_write = d1_d2_q_1.uop.gpr_write;
    end
    assign dispatch_waw_stall = retire_query_result.waw_block;
    // 控制流解析只等待真实操作数/执行边界；独立旧 MDU 的年龄由唯一退休队列保证。
    // 只读寄存队头的身份，不把完成/退休旁路接回 CSR 或 LSU 许可。
    assign csr_is_head = head_valid && d2_ex_q.valid && head_id == d2_ex_q.retire_id;
    assign lsu_is_head = head_valid && lsu_owner_valid && head_id == lsu_owner_id;
    assign wb_stall = wb_complete_valid && !wb_complete_ready;

    // EX 直接把合法访存交给描述符寄存边界，替代该指令原有的 EX/MEM 包。
    // 内部 issue_valid 是实际转交脉冲；EX 未获 ready 时仍持有原包，不重复接纳。
    assign ex_is_lsu = ex_packet.valid && !ex_packet.exc.valid &&
                       (ex_packet.uop.mem_read || ex_packet.uop.mem_write);
    assign execution_stall = ex_execution_stall || (ex_is_lsu && !lsu_issue_ready) ||
                             (d2_ex_q_1.valid && !secondary_issue_ready);
    assign lsu_issue_valid = ex_stage_advance && ex_is_lsu;
    assign mem_age_stall = lsu_request_pending && !lsu_is_head;
    assign mem_request_stall = dmem_req_valid && !dmem_req_ready;
    // 以下等待仅供协议/覆盖观察，不能反压普通流水；第二条 LSU 由 EX 的 ready 等待持包。
    // 完成接纳沿可以直接接下一描述符，不为统一控制额外增加空拍。
    assign lsu_wait = lsu_busy && !lsu_request_pending &&
                      !(lsu_complete_valid && lsu_complete_ready);
    store_unit u_lsu_store_unit (
        .store_data(ex_packet.store_data), .address(ex_packet.result),
        .size(ex_packet.uop.mem_size), .bus_wdata(lsu_store_wdata), .bus_wstrb(lsu_store_wstrb)
    );
    always_comb begin
        lsu_descriptor = '{id:ex_packet.retire_id, address:ex_packet.result,
            write:ex_packet.uop.mem_write, size:ex_packet.uop.mem_size,
            unsigned_load:ex_packet.uop.load_unsigned, wdata:lsu_store_wdata, wstrb:lsu_store_wstrb};
    end

    // 每个已寄存生产者独立广播；仲裁未选中的 MDU 值也可供依赖者使用。
    // Load 仅使用 LSU 格式化后的寄存非异常值，MEM 地址不属于 GPR 结果。
    always_comb begin
        tagged_mem_forward = '{valid:mem_gpr_forward.valid && ex_mem_q.rd != '0,
            id:ex_mem_q.retire_id, data:mem_gpr_forward.data};
        tagged_wb_forward = '{valid:wb_complete_valid && !wb_completion.result.exc.valid &&
            mem_wb_q.uop.gpr_write && mem_wb_q.rd != '0,
            id:wb_completion.id, data:wb_completion.result.gpr_data};
        tagged_mdu_forward = '{valid:mdu_complete_valid, id:mdu_completion.id,
            data:mdu_completion.result.gpr_data};
        secondary_forward = '{valid:secondary_valid && !secondary_completion.result.exc.valid,
            id:secondary_completion.id, data:secondary_completion.result.gpr_data};
    end

    ex_operand_register u_ex_operand_register (
        .clk, .rst, .action(pipeline_actions.d2_ex), .in_packet(d2_packet),
        .queue_rs1(retire_query_result.rs1_forward), .queue_rs2(retire_query_result.rs2_forward),
        .wb_forward(tagged_wb_forward), .mdu_forward(tagged_mdu_forward),
        .lsu_forward(tagged_lsu_forward),
        .mem_forward(tagged_mem_forward), .aux_forward(secondary_forward), .out_packet(d2_ex_q),
        .rs1_value(ex_rs1_value), .rs2_value(ex_rs2_value), .operands_ready(mdu_operands_ready)
    );

    // 合法 WB 全局清除时，访存响应已返回，且同拍禁止年轻 MEM 请求。
    // 恢复只观察真实所有者：普通后端包、LSU 描述符/响应和 MDU；不复制在途状态。
    // 外部总线与 core 必须协调复位，不承诺仅 core 复位后接收遗留响应。
    assign retire_drain_complete = !d2_ex_q.valid && !ex_mem_q.valid && !mem_wb_q.valid &&
                                   !lsu_busy && mdu_req_ready && !secondary_busy && !d2_ex_q_1.valid;

    retire_queue u_retire_queue (
        .branch_recovery('0), .producer_entries(),
        .ras_entries, .ras_head_slot,
        .clk, .rst, .flush_all(wb_redirect.valid), .drain_complete(retire_drain_complete),
        .alloc_valid(dispatch_valid), .alloc_ready(dispatch_ready), .alloc_meta, .alloc_id,
        .alloc_valid_1(dispatch_valid_1), .alloc_ready_1(dispatch_ready_1), .alloc_meta_1, .alloc_id_1,
        .complete_valid, .complete_ready, .completion, .complete_reject,
        .complete_valid_1(secondary_valid), .complete_ready_1(secondary_ready),
        .completion_1(secondary_completion), .complete_reject_1(secondary_reject),
        .query(retire_query), .query_result(retire_query_result),
        .query_1(retire_query_1), .query_result_1(retire_query_result_1),
        .head_valid, .head_complete, .head_id, .head_meta, .head_result,
        .head_valid_1, .head_complete_1, .head_id_1, .head_meta_1, .head_result_1,
        .retire_ready(!rst), .retire_fire(queue_retire_fire),
        .retire_ready_1(second_retire_ready), .retire_fire_1(queue_retire_fire_1),
        .occupancy(retire_occupancy), .recovering(retire_recovering),
        .probe_id(legacy_probe_id), .probe_accept(), .probe_live()
    );
    assign second_retire_ready = !rst && (ISSUE_WIDTH == 2) && !head_result.exc.valid &&
        !(head_meta.kind inside {RET_CSR, RET_SERIAL}) && head_meta_1.kind == RET_EXEC &&
        !head_result_1.exc.valid;
    alu_secondary u_alu_secondary (
        .clk, .rst, .cancel(execution_cancel),
        .issue_valid(ex_stage_advance && d2_ex_q_1.valid), .issue_ready(secondary_issue_ready),
        .packet(d2_ex_q_1), .complete_valid(secondary_valid), .complete_ready(secondary_ready),
        .completion(secondary_completion), .busy(secondary_busy)
    );

    ex_stage u_ex_stage (
        .clk,
        .rst,
        .csr_is_head,
        .mdu_operands_ready,
        .advance(ex_stage_advance),
        .cancel(execution_cancel),
        .mdu_req_ready,
        .mdu_req_valid,
        .mdu_request,
        .in_packet(d2_ex_q),
        .rs1_value(ex_rs1_value), .rs2_value(ex_rs2_value),
        .csr_committed_data,
        .mem_csr_forward,
        .wb_csr_forward(wb_csr_write),
        .out_packet(ex_packet),
        .redirect(ex_redirect),
        .serialize_req(ex_serialize_req),
        .execution_stall(ex_execution_stall)
    );

    csr_file u_csr_file (
        .clk,
        .rst,
        .irq_software, .irq_timer, .irq_external, .irq_pending, .irq_cause,
        .read_addr(d2_ex_q.csr_addr),
        .read_data(csr_committed_data),
        .write_valid(wb_csr_write.valid),
        .write_addr(wb_csr_write.addr),
        .write_legal_data(wb_csr_write.data),
        .retire_valid,
        .retire_extra(queue_retire_fire_1),
        .trap_enter,
        .trap_pc,
        .trap_cause,
        .trap_tval,
        .mret_commit,
        .mtvec,
        .mepc
    );

    mdu_completion_adapter u_mdu_completion_adapter (
        .clk, .rst,
        .cancel(execution_cancel),
        .req_valid(mdu_req_valid),
        .req_ready(mdu_req_ready),
        .request(mdu_request),
        .request_id(d2_ex_q.retire_id),
        .completion_valid(mdu_complete_valid), .completion_ready(mdu_complete_ready),
        .completion(mdu_completion)
    );
    completion_arbiter u_completion_arbiter (
        .clk, .rst, .flush(wb_redirect.valid),
        .wb_valid(wb_complete_valid), .wb_ready(wb_complete_ready), .wb_completion,
        .lsu_valid(lsu_complete_valid), .lsu_ready(lsu_complete_ready), .lsu_completion,
        .mdu_valid(mdu_complete_valid), .mdu_ready(mdu_complete_ready), .mdu_completion,
        .complete_valid, .complete_ready, .completion
    );

    lsu_transaction u_lsu_transaction (
        .clk, .rst, .cancel(execution_cancel),
        .issue_valid(lsu_issue_valid), .issue_ready(lsu_issue_ready), .descriptor(lsu_descriptor),
        .head_valid, .head_id,
        .dmem_req_valid, .dmem_req_ready, .dmem_req_write, .dmem_req_size,
        .dmem_req_addr, .dmem_req_wdata, .dmem_req_wstrb,
        .dmem_rsp_valid, .dmem_rsp_ready, .dmem_rsp_rdata, .dmem_rsp_error,
        .complete_valid(lsu_complete_valid), .complete_ready(lsu_complete_ready),
        .completion(lsu_completion), .registered_forward(tagged_lsu_forward),
        .busy(lsu_busy), .draining(lsu_draining), .owner_valid(lsu_owner_valid),
        .owner_id(lsu_owner_id), .request_pending(lsu_request_pending)
    );
`ifndef SYNTHESIS
    // 严格队头排除了取消已授权的 MMIO 副作用；描述符和普通流水不能重复持有同一访存。
    always_ff @(posedge clk) begin
        if (!rst) begin
            assert (!lsu_issue_valid || lsu_issue_ready)
                else $fatal(1, "LSU descriptor advanced without acceptance");
            assert (!(execution_cancel && dmem_req_valid))
                else $fatal(1, "Architectural cancellation crossed an authorized LSU request");
            assert (!(ex_mem_q.valid && !ex_mem_q.exc.valid &&
                      (ex_mem_q.uop.mem_read || ex_mem_q.uop.mem_write)) &&
                    !(mem_wb_q.valid && !mem_wb_q.exc.valid &&
                      (mem_wb_q.uop.mem_read || mem_wb_q.uop.mem_write)))
                else $fatal(1, "Normal LSU descriptor duplicated in ordinary pipeline");
        end
    end
`endif
    mem_stage u_mem_stage (
        .issue_enable(mem_issue_enable), .in_packet(ex_mem_q),
        .out_packet(mem_packet),
        .gpr_forward(mem_gpr_forward),
        .csr_forward(mem_csr_forward)
    );

    wb_stage u_wb_stage (
        .in_packet(mem_wb_q),
        .completion(wb_completion),
        .completion_valid(wb_complete_valid)
    );

    // 只有已完成的队头能写架构状态；WB 同拍完成旁路不额外增加退休周期。
    commit_control u_commit_control (
        .retire_fire(queue_retire_fire), .head_meta, .head_result,
        .gpr_write(wb_gpr_write),
        .csr_write(wb_csr_write),
        .commit_valid,
        .commit_pc,
        .commit_inst,
        .commit_rd,
        .commit_rd_we,
        .commit_rd_data,
        .commit_exception
    );
    commit_control u_commit_control_1 (
        .retire_fire(queue_retire_fire_1), .head_meta(head_meta_1), .head_result(head_result_1),
        .gpr_write(wb_gpr_write_1), .csr_write(unused_csr_write_1),
        .commit_valid(unused_commit_valid_1), .commit_pc(unused_commit_pc_1),
        .commit_inst(unused_commit_inst_1), .commit_rd(unused_commit_rd_1),
        .commit_rd_we(unused_commit_rd_we_1), .commit_rd_data(unused_commit_rd_data_1),
        .commit_exception(unused_commit_exception_1)
    );
    always_comb begin
        commit_trace[0] = '{valid:commit_valid, id:head_id, pc:commit_pc,
            next_pc:head_result.next_pc, inst:commit_inst, rd:commit_rd,
            rd_we:commit_rd_we, rd_data:commit_rd_data, exception:commit_exception};
        commit_trace[1] = '{valid:queue_retire_fire_1, id:head_id_1, pc:head_meta_1.pc,
            next_pc:head_result_1.next_pc, inst:head_meta_1.inst, rd:wb_gpr_write_1.addr,
            rd_we:wb_gpr_write_1.valid, rd_data:head_result_1.gpr_data,
            exception:queue_retire_fire_1 && head_result_1.exc.valid};
    end

    interrupt_entry u_interrupt_entry (
        .clk, .rst, .irq_pending,
        .pipeline_busy(if_d1_q.valid || d1_d2_q.valid || d2_ex_q.valid ||
                       ex_mem_q.valid || mem_wb_q.valid || (retire_occupancy != '0) ||
                       retire_recovering || lsu_busy || !mdu_req_ready || secondary_busy ||
                       if_d1_q_1.valid || d1_d2_q_1.valid || d2_ex_q_1.valid || fetch_pair_busy),
        .retire_valid, .commit_next_pc(queue_retire_fire_1 ? head_result_1.next_pc : head_result.next_pc),
        .wb_redirect, .interrupt_take, .interrupt_pc
    );

    trap_controller u_trap_controller (
        .head_meta, .head_result,
        .commit_valid,
        .interrupt_take, .interrupt_pc, .interrupt_cause(irq_cause),
        .mtvec,
        .mepc,
        .trap_enter,
        .mret_commit,
        .trap_pc,
        .trap_cause,
        .trap_tval,
        .retire_valid,
        .execution_cancel,
        .redirect(wb_redirect)
    );

    pipeline_ctrl u_pipeline_ctrl (
        .wb_redirect,
        .ex_redirect,
        .d1_redirect(d1_redirect_ctrl),
        .ex_serialize_req,
        .d1_serialize_req(d1_serialize_ctrl),
        .wb_wait(wb_stall),
        .execution_stall,
        .dispatch_waw_stall,
        .decode_valid(d1_d2_q.valid), .dispatch_ready, .dispatch_valid,
        .redirect(selected_redirect),
        .serialize_start,
        .fetch_ready(fetch_ready_ctrl),
        .mem_issue_enable,
        .d1_flush,
        .actions(pipeline_actions)
    );

    // 流水级间寄存器：每个寄存器独立处理 ADVANCE/HOLD/CLEAR。
    always_ff @(posedge clk) begin
        if (rst) begin
            if_d1_q <= '0;
            if_d1_q_1 <= '0;
        end else if (pipeline_actions.if_d1 == PIPE_CLEAR) begin
            if_d1_q.valid <= 1'b0;
            if_d1_q_1.valid <= 1'b0;
        end else if (pipeline_actions.if_d1 == PIPE_ADVANCE && !decode_partial) begin
            if (d1_partial) begin
                if_d1_q <= if_d1_q_1;
                if_d1_q_1.valid <= 1'b0;
            end else begin
                if_d1_q <= fetch_packet;
                if_d1_q_1 <= fetch_packet_1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            d1_d2_q <= '0;
            d1_d2_q_1 <= '0;
        end else if (pipeline_actions.d1_d2 == PIPE_CLEAR) begin
            d1_d2_q.valid <= 1'b0;
            d1_d2_q_1.valid <= 1'b0;
        end else if (pipeline_actions.d1_d2 == PIPE_ADVANCE) begin
            if (decode_partial) begin
                d1_d2_q <= d1_d2_q_1;
                d1_d2_q_1.valid <= 1'b0;
            end else begin
                d1_d2_q <= d1_packet;
                d1_d2_q_1 <= d1_packet_1;
                d1_d2_q_1.valid <= (ISSUE_WIDTH == 2) && decode_pair_eligible;
            end
        end
    end

    // 第二槽在D2已捕获全部来源，不依赖未来RF变化；它与同组第一槽真正发射同步。
    always_ff @(posedge clk) begin
        if (rst || pipeline_actions.d2_ex == PIPE_CLEAR)
            d2_ex_q_1.valid <= 1'b0;
        else if (pipeline_actions.d2_ex == PIPE_ADVANCE) begin
            d2_ex_q_1 <= d2_packet_1;
            d2_ex_q_1.valid <= dispatch_fire_1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst)
            ex_mem_q <= '0;
        else if (pipeline_actions.ex_mem == PIPE_CLEAR)
            ex_mem_q.valid <= 1'b0;
        else if (pipeline_actions.ex_mem == PIPE_ADVANCE) begin
            if (ex_is_lsu)
                // 正常访存不再复制宽数据到旧流水槽；早期异常仍走普通流水。
                ex_mem_q.valid <= 1'b0;
            else
                ex_mem_q <= ex_packet;
        end
    end

    always_ff @(posedge clk) begin
        if (rst)
            mem_wb_q <= '0;
        else if (pipeline_actions.mem_wb == PIPE_CLEAR)
            mem_wb_q.valid <= 1'b0;
        else if (pipeline_actions.mem_wb == PIPE_ADVANCE)
            mem_wb_q <= mem_packet;
    end
endmodule
