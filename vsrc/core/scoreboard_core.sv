// Module: scoreboard_core
// Description: Dual-issue backend with tagged scheduling, independent completion and precise retirement.
`ifndef CORE_COMPLETION_WAKEUP_ENABLE
`define CORE_COMPLETION_WAKEUP_ENABLE 1
`endif
`ifndef CORE_STORE_HINT_ENABLE
`define CORE_STORE_HINT_ENABLE 1
`endif
module scoreboard_core (
    input logic clk, rst,
    input logic irq_software, irq_timer, irq_external,
    output logic imem_req_valid,
    output core_types_pkg::xlen_t imem_req_addr,
    input logic imem_req_ready, imem_rsp_valid,
    input logic [63:0] imem_rsp_data,
    input logic imem_rsp_error, imem_rsp_error_1,
    output logic imem_rsp_ready,
    output logic [1:0] mem_req_valid,
    input logic [1:0] mem_req_ready,
    output scoreboard_pkg::memory_request_t mem_request [2],
    input logic [1:0] mem_rsp_valid,
    output logic [1:0] mem_rsp_ready,
    input scoreboard_pkg::memory_response_t mem_response [2],
    output logic commit_valid,
    output core_types_pkg::xlen_t commit_pc,
    output logic [31:0] commit_inst,
    output core_types_pkg::gpr_addr_t commit_rd,
    output logic commit_rd_we,
    output core_types_pkg::xlen_t commit_rd_data,
    output logic commit_exception, fence_i_commit,
    output pipeline_pkg::retire_trace_t commit_trace [2],
    output logic [1:0] issue_fire
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;

    if_d1_t fetched [2];
    d1_d2_t decoded [2], decode_intake [2], decode_q [2];
    d2_ex_t renamed [2], queued [2], scheduled [2];
    logic [1:0] issue_enqueue_count, issue_capacity, issue_occupancy;
    logic issue_busy;
    logic iq_mdu_available;
    branch_result_t queued_branch [2], scheduled_branch [2];
    logic [1:0] branch_taken;
    xlen_t branch_target [2];
    logic [1:0] issue_present;
    d2_ex_t raw_scheduled [2];
    pred_info_t prediction [2];
    pred_update_t training [2], predictor_update;
    xlen_t lookup_pc, lookup_pc_1;
    logic ras_top_valid;
    xlen_t ras_top_addr;
    logic fetch_fire, fetch_second, fetch_busy;
    logic [1:0] fetch_pop_count, dispatch_count, issue_count, iq_capacity, iq_ready;
    logic [1:0] iq_push_memory;
    logic [1:0] alloc_fire, alloc_ready, retire_fire, head_valid, head_complete;
    logic [1:0] completion_valid, completion_accept, completion_reject, complete_ready, training_capacity;
    logic [1:0] retire_ready, lane_ready, integer_ready;
    // 分支判定从 ISS 寄存包产生；包内 branch_reported 防止重复上报。
    logic branch_wrong;
    logic [1:0] mark_reported;
    // LSQ 每个物理槽仍保存自己的结果；中央只接收本地选出的两项完成。
    // 中央完成源由 11 降为 5，减少跨模块连线、扇出和放置拥塞。
    // LSQ 本地选择仍按年龄选最老两项，取消/错误/逐槽结果语义不变。
    localparam int LSU_COMPLETIONS = 2;
    localparam int COMPLETION_SOURCES = 3 + LSU_COMPLETIONS;
    localparam bit COMPLETION_WAKEUP_ENABLE = `CORE_COMPLETION_WAKEUP_ENABLE;
    localparam bit STORE_HINT_ENABLE = `CORE_STORE_HINT_ENABLE;
    localparam int BROADCAST_SOURCES = LSU_HINT_FIRST + (STORE_HINT_ENABLE ? LOAD_QUEUE_ENTRIES : 0);
    logic [COMPLETION_SOURCES-1:0] source_valid, source_preview_valid, source_ready, completion_busy;
    // 每个完成源的接受位在年龄仲裁前由 ROB 预检，选中后不再等待动态读。
    logic [COMPLETION_SOURCES-1:0] source_accept, source_live;
    logic [1:0] completion_live, operand_completion_valid;
    retire_id_t accept_probe_id [COMPLETION_SOURCES];
    logic [1:0] selected_completion_valid;
    logic [COMPLETION_SOURCES-1:0] completion_input_valid, completion_input_ready;
    retire_completion_t completion_input [COMPLETION_SOURCES];
    retire_completion_t completed [2], sources [COMPLETION_SOURCES], computed [2];
    retire_alloc_t alloc_meta [2], head_metadata [2];
    retire_result_t head_results [2];
    retire_id_t alloc_id [2], head_ids [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_ras_entry_t ras_entries [RETIRE_ENTRIES];
    gpr_dependency_t rename_source [2][2];
    retire_gpr_forward_t broadcast [BROADCAST_SOURCES];
    gpr_forward_t gpr_write [2];
    csr_forward_t csr_write [2];
    xlen_t rf_rs1 [2], rf_rs2 [2];
    logic [RETIRE_COUNT_W-1:0] rob_occupancy;
    logic [$clog2(SCHEDULER_ENTRIES+1)-1:0] iq_occupancy;
    logic [RETIRE_IDX_W-1:0] head_slot;
    // 两个局部视图与 ROB 使用同一退休增量；不是延迟一拍的 head。
    // ADS UG990102 8.2.17：保留等价寄存器，避免综合重新合并跨模块年龄网络。
    logic [RETIRE_IDX_W-1:0] lsu_head_slot /* synthesis syn_preserve=1 */;
    logic [RETIRE_IDX_W-1:0] completion_head_slot /* synthesis syn_preserve=1 */;
    logic [1:0] head_advance;
    logic rob_recovering, drain_complete, checkpoint_ready, branch_resolved;
    retire_id_t resolved_id;
    branch_recovery_t recovery, branch_recovery;
    redirect_t wb_redirect, selected_redirect;
    redirect_t d1_redirect [2], decode_jump_q, frontend_redirect;
    logic mdu_lane;
    schedule_class_e lane_class [2];
    lsu_descriptor_t descriptor [2];
    logic mdu_req_valid, mdu_req_ready, mdu_cancel;
    muldiv_req_t mdu_request;
    retire_id_t mdu_id_q;
    retire_gpr_forward_t lsu_early_forward [2];
    retire_gpr_forward_t lsu_load_return [2], lsu_store_forward_hint [2];
    retire_gpr_forward_t lsu_store_slot_hint [LOAD_QUEUE_ENTRIES];
    logic [1:0] lsu_issue_ready, lsu_offer_valid, lsu_issue_fire, lsu_response_reject;
    logic [LSU_COMPLETIONS-1:0] lsu_complete_valid, lsu_complete_ready;
    retire_completion_t lsu_completion [LSU_COMPLETIONS];
    logic lsu_busy, lsu_draining, lsu_owner_valid;
    retire_id_t lsu_owner_id;
    // 仿真只读观察；Store 外部请求仍使用端口 0，返回可经任一标签口。
    retire_id_t store_request_id, store_response_id;
    logic store_response_fire, store_response_error;
    logic irq_pending, interrupt_take, trap_enter, mret_commit, normal_retire, execution_cancel;
    irq_cause_e irq_cause;
    xlen_t interrupt_pc, trap_pc, trap_cause, trap_tval, mtvec, mepc, csr_data;
    // 保留观察命名，测试对外部 Store 的授权、响应和退休逐项检查。
    logic queue_retire_fire;
    retire_id_t head_id;
    retire_alloc_t head_meta;
    retire_result_t head_result;
    assign queue_retire_fire = retire_fire[0];
    assign head_id = head_ids[0];
    assign head_meta = head_metadata[0];
    assign head_result = head_results[0];

    assign head_advance = {1'b0, retire_fire[0]} + {1'b0, retire_fire[1]};
    always_ff @(posedge clk) begin
        if (rst || wb_redirect.valid) begin
            lsu_head_slot <= '0;
            completion_head_slot <= '0;
        end else begin
            // 分支恢复可与更老退休同沿发生；head 只按实际退休数前进。
            lsu_head_slot <= lsu_head_slot + RETIRE_IDX_W'(head_advance);
            completion_head_slot <= completion_head_slot + RETIRE_IDX_W'(head_advance);
        end
    end

    assign fence_i_commit = commit_valid && !commit_exception && head_meta.sys_op == SYS_FENCE_I;
    predictor u_predictor (
        .clk, .rst(rst || fence_i_commit), .lookup_pc, .lookup_pc_1,
        .ras_top_valid, .ras_top_addr, .prediction(prediction[0]),
        .prediction_1(prediction[1]), .update(predictor_update)
    );
    predictor_update_queue u_training (
        .clk, .rst(rst || fence_i_commit), .incoming(training),
        .capacity(training_capacity), .update(predictor_update)
    );
    if (RAS_ENABLE) begin : g_ras
        predictor_types_pkg::ras_event_t replay [RETIRE_ENTRIES+2];
        logic [RETIRE_ENTRIES+1:0] replay_valid;
        // 恢复只重放仍在 ROB 的真实事件；本拍两条退休已进入 committed 基底。
        for (genvar age = 0; age < RETIRE_ENTRIES; age++) begin : g_replay
            logic [RETIRE_IDX_W-1:0] slot;
            assign slot = head_slot + RETIRE_IDX_W'(age);
            assign replay[age] = ras_entries[slot].event_info;
            assign replay_valid[age] = ras_entries[slot].valid && !ras_entries[slot].exception &&
                !wb_redirect.valid &&
                !(retire_fire[0] && ras_entries[slot].id == head_ids[0]) &&
                !(retire_fire[1] && ras_entries[slot].id == head_ids[1]) &&
                !(recovery.valid && younger_than(ras_entries[slot].id, recovery.id, head_slot));
        end
        // D1 的重定向发生时，decode_q 尚未进入已寄存 ROB；按程序顺序补入 RAS 视图。
        for (genvar lane = 0; lane < 2; lane++) begin : g_decode_replay
            assign replay[RETIRE_ENTRIES+lane] = '{op:alloc_meta[lane].ras_op, addr:decode_q[lane].seq_pc};
            assign replay_valid[RETIRE_ENTRIES+lane] = decode_jump_q.valid && !selected_redirect.valid &&
                decode_q[lane].valid && !decode_q[lane].exc.valid;
        end
        ras #(.DEPTH(RAS_DEPTH), .REPLAY_SLOTS(RETIRE_ENTRIES+2)) u_ras (
            .clk, .rst, .clear(fence_i_commit), .fetch_fire, .fetch_second,
            .fetch_event('{op:prediction[0].ras_op, addr:lookup_pc+xlen_t'(4)}),
            .fetch_event_1('{op:prediction[1].ras_op, addr:lookup_pc_1+xlen_t'(4)}),
            .commit_valid(retire_fire[0] && !head_results[0].exc.valid),
            .commit_event('{op:head_metadata[0].ras_op, addr:head_metadata[0].seq_pc}),
            .commit_valid_1(retire_fire[1]),
            .commit_event_1('{op:head_metadata[1].ras_op, addr:head_metadata[1].seq_pc}),
            .recover(frontend_redirect.valid), .replay_valid, .replay,
            .top_valid(ras_top_valid), .top_addr(ras_top_addr)
        );
    end else begin : g_no_ras
        assign ras_top_valid = 0;
        assign ras_top_addr = '0;
    end
    fetch_pair_stage u_fetch (
        .clk, .rst, .fetch_request_enable(!irq_pending), .flush(1'b0),
        .redirect(frontend_redirect), .prediction(prediction[0]), .prediction_1(prediction[1]),
        .lookup_pc, .lookup_pc_1, .fetch_fire, .fetch_second,
        .out_packet(fetched[0]), .out_packet_1(fetched[1]), .pop_count(fetch_pop_count),
        .imem_req_valid, .imem_req_addr, .imem_req_ready, .imem_rsp_valid,
        .imem_rsp_data, .imem_rsp_error, .imem_rsp_error_1, .imem_rsp_ready, .busy(fetch_busy)
    );
    for (genvar lane = 0; lane < 2; lane++) begin : g_decode
        // 类型容量只读静态译码字段，不能经 RAT 的当拍分配旁路返回 alloc_ready。
        assign iq_push_memory[lane] = !decode_q[lane].exc.valid && !decode_q[lane].uop.csr_valid &&
            decode_q[lane].uop.sys_op == SYS_NONE && decode_q[lane].uop.branch_op == BR_NONE &&
            decode_q[lane].uop.fu != FU_MULDIV && (decode_q[lane].uop.mem_read || decode_q[lane].uop.mem_write);
        d1_stage #(.PC_REL_TARGET_IN_IMM(1'b1)) u_decode (.in_packet(fetched[lane]), .out_packet(decoded[lane]),
                           .redirect(d1_redirect[lane]), .serialize_req());
        d2_stage u_rename_packet (
            .in_packet(decode_q[lane]), .rs1_data(rf_rs1[lane]), .rs2_data(rf_rs2[lane]),
            .alloc_id(alloc_id[lane]), .alloc_meta(alloc_meta[lane]),
            .rs1_dependency(rename_source[lane][0]), .rs2_dependency(rename_source[lane][1]),
            .out_packet(renamed[lane])
        );
    end
    assign dispatch_count = {1'b0, alloc_fire[0]} + {1'b0, alloc_fire[1]};
    assign alloc_fire[0] = alloc_ready[0] && decode_q[0].valid && iq_capacity != 0 &&
                          checkpoint_ready && !selected_redirect.valid;
    assign alloc_fire[1] = alloc_fire[0] && alloc_ready[1] && decode_q[1].valid && iq_capacity == 2;
    // 弹性译码组只消费年龄前缀；不能把第二条在等待资源时覆盖。
    always_comb begin
        fetch_pop_count = 0;
        if (!selected_redirect.valid && (!decode_q[0].valid ||
            (alloc_fire[0] && (!decode_q[1].valid || alloc_fire[1]))))
            fetch_pop_count = fetched[0].valid ? (fetched[1].valid && !d1_redirect[0].valid ? 2'd2 : 2'd1) : 2'd0;
        for (int lane = 0; lane < 2; lane++) begin
            decode_intake[lane] = decoded[lane];
            // 保留0/1/2条前缀有效位，避免窄计数转为有符号int后被综合误折叠。
            decode_intake[lane].valid = (lane == 0) ?
                (fetch_pop_count != 2'd0) : (fetch_pop_count == 2'd2);
            // 训练上下文保持取指快照；执行控制已知道此 JAL 的实际方向，不再次恢复。
            if (d1_redirect[lane].valid) begin
                decode_intake[lane].pred.taken = 1'b1;
                decode_intake[lane].pred.target = d1_redirect[lane].pc;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (rst || selected_redirect.valid) begin
            decode_q[0].valid <= 0; decode_q[1].valid <= 0;
        end else if (!decode_q[0].valid ||
                     (alloc_fire[0] && (!decode_q[1].valid || alloc_fire[1]))) begin
            decode_q[0] <= decode_intake[0]; decode_q[1] <= decode_intake[1];
        end else if (alloc_fire[0]) begin
            decode_q[0] <= decode_q[1]; decode_q[1].valid <= 0;
        end
    end
    // 已接纳的最早 JAL 形成一次寄存事件；避免取指 FIFO 有效位经 flush 返回自身。
    // 只清前端年轻取指；ROB/IQ 中更老指令继续执行，异常和已分配分支恢复优先。
    always_ff @(posedge clk) begin
        if (rst || selected_redirect.valid) decode_jump_q <= '0;
        else begin
            decode_jump_q <= '0;
            if (fetch_pop_count != 0 && d1_redirect[0].valid)
                decode_jump_q <= d1_redirect[0];
            else if (fetch_pop_count == 2 && d1_redirect[1].valid)
                decode_jump_q <= d1_redirect[1];
        end
    end
    always_comb begin
        frontend_redirect = selected_redirect;
        if (!selected_redirect.valid) frontend_redirect = decode_jump_q;
    end

    regfile u_regfile (
        .clk, .rs1_addr(decode_q[0].rs1), .rs2_addr(decode_q[0].rs2),
        .rs1_data(rf_rs1[0]), .rs2_data(rf_rs2[0]),
        .write_enable(gpr_write[0].valid), .write_addr(gpr_write[0].addr), .write_data(gpr_write[0].data),
        .rs1_addr_1(decode_q[1].rs1), .rs2_addr_1(decode_q[1].rs2),
        .rs1_data_1(rf_rs1[1]), .rs2_data_1(rf_rs2[1]),
        .write_enable_1(gpr_write[1].valid), .write_addr_1(gpr_write[1].addr), .write_data_1(gpr_write[1].data)
    );
    rename_table u_rename (
        .clk, .rst, .flush(wb_redirect.valid), .alloc_fire, .alloc_meta, .alloc_id,
        .decode(decode_q), .retire(commit_trace), .source(rename_source),
        .checkpoint_ready, .branch_resolved, .resolved_id, .recovery, .head_slot
    );
    if (SPLIT_ISSUE_QUEUE) begin : g_split_iq
        split_scoreboard_queue #(.BROADCAST_PORTS(BROADCAST_SOURCES)) u_scoreboard (
            .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot, .mdu_available(iq_mdu_available),
            .push_memory(iq_push_memory),
            .push_count(dispatch_count), .push_packet(renamed), .push_capacity(iq_capacity),
            .producers, .broadcast, .issue_packet(queued), .operands_ready(iq_ready),
            .pop_count(issue_enqueue_count), .occupancy(iq_occupancy)
        );
    end else begin : g_unified_iq
        scoreboard_queue #(.BROADCAST_PORTS(BROADCAST_SOURCES), .ISSUE_BYPASS(1)) u_scoreboard (
            .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot,
            .push_count(dispatch_count), .push_packet(renamed), .push_capacity(iq_capacity),
            .producers, .broadcast, .issue_packet(queued), .operands_ready(iq_ready),
            .pop_count(issue_enqueue_count), .occupancy(iq_occupancy)
        );
    end

    // 忙 MDU 留在整数 IQ；ISS 中已有 MDU 时不再接纳另一条，独立 ALU 仍可越过。
    assign iq_mdu_available = mdu_req_ready &&
        !(scheduled[0].valid && schedule_class(scheduled[0]) == SCHED_MDU) &&
        !(scheduled[1].valid && schedule_class(scheduled[1]) == SCHED_MDU);
    // IQ→ISS 接纳所选就绪前缀；执行反压由两项寄存包保持完整数据和 ID。
    always_comb begin
        issue_enqueue_count = 0;
        if (iq_ready[0] && issue_capacity != 0) begin
            issue_enqueue_count = 1;
            // ISS 共享一个分支判定器，同拍最多接纳一条分支。
            if (iq_ready[1] && issue_capacity == 2 &&
                !(schedule_class(queued[0]) == SCHED_BRANCH && schedule_class(queued[1]) == SCHED_BRANCH))
                issue_enqueue_count = 2;
        end
    end
    issue_queue #(.STATIC_SELECT(1'b1)) u_issue (
        .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot,
        .push_count(issue_enqueue_count), .push_packet(queued), .push_branch(queued_branch), .push_capacity(issue_capacity),
        .pop_count(issue_count), .issue_packet(scheduled), .raw_packet(raw_scheduled),
        .issue_branch(scheduled_branch), .mark_reported(mark_reported),
        .present(issue_present), .occupancy(issue_occupancy), .busy(issue_busy)
    );

    // 分支判定使用已寄存的 ISS 包；接纳拍只做年龄选择和宽包搬运。
    // 两个 ISS 槽各有一个判定器，避免已上报分支占住共享判定资源。
    for (genvar lane = 0; lane < 2; lane++) begin : g_issue_branch
        branch_unit #(.PC_REL_TARGET_IN_IMM(1'b1)) u_branch (
            .branch_op(raw_scheduled[lane].uop.branch_op), .pc(raw_scheduled[lane].pc),
            .seq_pc(raw_scheduled[lane].seq_pc),
            .operand_a(raw_scheduled[lane].rs1_data), .operand_b(raw_scheduled[lane].rs2_data),
            .imm(raw_scheduled[lane].imm), .taken(branch_taken[lane]), .target(branch_target[lane])
        );
        // ISS 不再保存分支结果；判定和恢复在同一寄存拍内完成。
        assign queued_branch[lane] = '0;
    end
    for (genvar lane = 0; lane < 2; lane++) begin : g_execute
        scoreboard_execute u_execute (
            .packet(scheduled[lane]), .branch_taken(branch_taken[lane]),
            .branch_target(branch_target[lane]), .csr_old_data(csr_data),
            .completion(computed[lane]), .descriptor(descriptor[lane])
        );
        assign integer_ready[lane] = completion_input_ready[lane];
        // 早期异常走普通完成槽，不向 MDU/LSU 发送无效事务。
        assign lane_class[lane] = computed[lane].result.exc.valid ? SCHED_SERIAL : schedule_class(scheduled[lane]);
        always_comb begin
            lane_ready[lane] = 0;
            unique case (lane_class[lane])
                SCHED_MDU: lane_ready[lane] = mdu_req_ready;
                SCHED_MEMORY: lane_ready[lane] = lsu_issue_ready[lane];
                SCHED_SERIAL: lane_ready[lane] = integer_ready[lane] && head_valid[0] &&
                    head_ids[0] == scheduled[lane].retire_id && !lsu_busy;
                default: lane_ready[lane] = integer_ready[lane];
            endcase
        end
        // ALU 的原结果寄存器作为 CMP 首项，满时由第二项吸收仲裁冲突。
        assign completion_input_valid[lane] = issue_fire[lane] &&
            !(lane_class[lane] inside {SCHED_MEMORY, SCHED_MDU});
        assign completion_input[lane] = computed[lane];
    end

    // ISS 只执行已寄存的年龄前缀；双访存是否配对由两类队列的实际空槽决定。
    always_comb begin
        issue_fire = 0;
        if (!rst && !selected_redirect.valid && scheduled[0].valid && lane_ready[0]) begin
            issue_fire[0] = 1;
            issue_fire[1] = scheduled[1].valid && lane_ready[1] && resources_pair(lane_class[0], lane_class[1]);
        end
        issue_count = {1'b0, issue_fire[0]} + {1'b0, issue_fire[1]};
    end
    // 宽操作数直接按 ISS 中的 FU 类型路由，避免 CSR/分支/异常分类进入 DSP 输入。
    // 异常和串行指令仍由 lane_class 与 issue_fire 授权；串行 lane0 不允许 lane1 发射。
    assign mdu_lane = scheduled[0].uop.fu != FU_MULDIV;
    assign mdu_req_valid = issue_fire[mdu_lane] && lane_class[mdu_lane] == SCHED_MDU;
    assign mdu_request = '{operation:scheduled[mdu_lane].uop.muldiv_op,
        op_width:scheduled[mdu_lane].uop.op_width,
        operand_a:scheduled[mdu_lane].rs1_data, operand_b:scheduled[mdu_lane].rs2_data};
    assign mdu_cancel = execution_cancel ||
        (recovery.valid && younger_than(mdu_id_q, recovery.id, head_slot));
    always_ff @(posedge clk) if (mdu_req_valid && mdu_req_ready) mdu_id_q <= scheduled[mdu_lane].retire_id;
    mdu_completion_adapter u_mdu (
        .clk, .rst, .cancel(mdu_cancel), .req_valid(mdu_req_valid), .req_ready(mdu_req_ready),
        .request(mdu_request), .request_id(scheduled[mdu_lane].retire_id),
        .completion_valid(completion_input_valid[2]), .completion_ready(completion_input_ready[2]),
        .completion(completion_input[2])
    );
    for (genvar lane = 0; lane < 2; lane++) begin : g_memory_issue
        assign lsu_offer_valid[lane] = scheduled[lane].valid && lane_class[lane] == SCHED_MEMORY;
        assign lsu_issue_fire[lane] = issue_fire[lane] && lsu_offer_valid[lane];
    end
    // 内部完成候选与两个外部访存口分开；全局每拍仍只接纳最老两项。
    for (genvar slot = 0; slot < LSU_COMPLETIONS; slot++) begin : g_memory_completion
        assign completion_input_valid[3+slot] = lsu_complete_valid[slot];
        assign lsu_complete_ready[slot] = completion_input_ready[3+slot];
        assign completion_input[3+slot] = lsu_completion[slot];
    end
    load_store_queue #(.COMPLETION_PORTS(LSU_COMPLETIONS)) u_lsu (
        .clk, .rst, .flush(execution_cancel), .recovery, .head_slot(lsu_head_slot),
        .head_valid(head_valid[0]), .head_id(head_ids[0]),
        .offer_valid(lsu_offer_valid), .issue_fire(lsu_issue_fire), .descriptor, .issue_ready(lsu_issue_ready),
        .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready, .mem_response,
        .response_reject(lsu_response_reject), .complete_valid(lsu_complete_valid),
        .complete_ready(lsu_complete_ready), .completion(lsu_completion),
        .early_forward(lsu_early_forward), .load_return(lsu_load_return), .store_forward_hint(lsu_store_forward_hint),
        .store_slot_hint(lsu_store_slot_hint),
        .busy(lsu_busy), .draining(lsu_draining), .store_owner_valid(lsu_owner_valid), .store_owner_id(lsu_owner_id)
    );
    assign store_request_id = mem_request[0].id;
    always_comb begin
        store_response_fire = 0; store_response_error = 0; store_response_id = '0;
        for (int portno = 0; portno < 2; portno++) begin
            if (mem_rsp_valid[portno] && mem_rsp_ready[portno] && lsu_owner_valid &&
                mem_response[portno].id == lsu_owner_id) begin
                store_response_fire = 1;
                store_response_error = mem_response[portno].error;
                store_response_id = mem_response[portno].id;
            end
        end
    end

    // 分支在 ISS 弹出前用寄存包判定；包内 branch_reported 保证每条分支只上报一次。
    // 未对齐跳转不进恢复，仍由 EX 形成精确异常。
    always_comb begin
        logic candidate_valid;
        logic candidate_lane;
        d2_ex_t candidate_packet;
        branch_result_t candidate_result;
        candidate_valid = 0;
        candidate_lane = 0;
        candidate_packet = '0;
        candidate_result = '0;
        for (int lane = 0; lane < 2; lane++) begin
            if (!candidate_valid && issue_present[lane] &&
                schedule_class(raw_scheduled[lane]) == SCHED_BRANCH &&
                !raw_scheduled[lane].branch_reported) begin
                candidate_valid = 1;
                candidate_lane = 1'(lane);
                candidate_packet = raw_scheduled[lane];
                candidate_result = '{taken:branch_taken[lane], target:branch_target[lane]};
            end
        end
        // 判定过的分支在包里置位；未对齐跳转也置位，避免占住另一槽的候选。
        mark_reported = '0;
        if (candidate_valid) mark_reported[candidate_lane] = 1'b1;
        branch_resolved = candidate_valid && (!candidate_result.taken || candidate_result.target[1:0] == 0);
        // ID 只由已寄存候选决定，不等待 taken/目标对齐判定；消费端以有效位授权。
        // 未对齐跳转仍走精确异常，无效载荷不能释放 checkpoint 或触发恢复。
        resolved_id = candidate_packet.retire_id;
        // 先算误预测位，避免在同一组合块内回读 recovery.valid 形成伪环。
        branch_wrong = branch_resolved &&
            (candidate_packet.pred.taken != candidate_result.taken ||
             (candidate_result.taken && candidate_packet.pred.target != candidate_result.target));
        branch_recovery.valid = branch_wrong;
        branch_recovery.id = candidate_packet.retire_id;
        branch_recovery.pc = candidate_result.taken ? candidate_result.target : candidate_packet.seq_pc;
    end
    assign recovery = branch_recovery;
    // 重定向选择单独成块，避免 wb_redirect 与恢复经同一组合节点互连。
    always_comb begin
        selected_redirect = wb_redirect;
        if (!wb_redirect.valid && branch_recovery.valid)
            selected_redirect = '{valid:1'b1, pc:branch_recovery.pc, reason:REDIR_EX_BRANCH};
    end
    // branch_reported 在 issue_queue 内随包压缩/弹出，不依赖 retire_id 复用。
    // 预检 ID 直接来自各完成队列的寄存头，与年龄仲裁并行。
    for (genvar src = 0; src < COMPLETION_SOURCES; src++) begin : g_accept_probe
        assign accept_probe_id[src] = sources[src].id;
    end
    // LSU 的本地年龄选择到中央选择之间增加寄存边界；五源分别保存两项。
    for (genvar src = 0; src < COMPLETION_SOURCES; src++) begin : g_completion_queue
        completion_queue u_queue (
            .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot(completion_head_slot),
            .input_valid(completion_input_valid[src]), .input_ready(completion_input_ready[src]),
            .input_completion(completion_input[src]), .output_valid(source_valid[src]), .output_preview_valid(source_preview_valid[src]),
            .output_ready(source_ready[src]), .output_completion(sources[src]), .busy(completion_busy[src])
        );
    end
    completion_select #(.SOURCES(COMPLETION_SOURCES)) u_completion_select (
        .rst, .head_slot(completion_head_slot), .source_valid(source_preview_valid),
        .source_accept, .source_live, .source_ready, .source_completion(sources),
        .complete_valid(selected_completion_valid), .complete_accept(completion_accept),
        .complete_live(completion_live), .completion(completed)
    );
    // 接受位已由各源寄存 ID 预检；全局清空仍关闭握手。
    // 同一完整 ID 的第二口不写 ROB、不广播，第一口优先。
    assign completion_valid[0] = selected_completion_valid[0] & completion_accept[0] && !wb_redirect.valid;
    assign completion_valid[1] = selected_completion_valid[1] & completion_accept[1] && !wb_redirect.valid &&
        !(completed[1].id == completed[0].id && completion_valid[0]);
    // ROB 写入保持完整接受许可；预览仅捕获操作数，不提交任何架构副作用。
    // 恢复拍 IQ 禁止发射并删除年轻项。存活 consumer 的依赖总比自身老，
    // 因而不会保留来自被取消年轻 producer 的值；全 flush 仍关闭全部预览。
    assign operand_completion_valid[0] = COMPLETION_WAKEUP_ENABLE ?
        selected_completion_valid[0] && completion_live[0] && !wb_redirect.valid : completion_valid[0];
    assign operand_completion_valid[1] = COMPLETION_WAKEUP_ENABLE ?
        selected_completion_valid[1] && completion_live[1] && !wb_redirect.valid &&
        !(completed[1].id == completed[0].id && operand_completion_valid[0]) : completion_valid[1];
    for (genvar portno = 0; portno < 2; portno++) begin : g_broadcast
        assign broadcast[portno] = '{valid:operand_completion_valid[portno] &&
            !completed[portno].result.exc.valid, id:completed[portno].id, data:completed[portno].result.gpr_data};
    end
    // 执行源入 CMP 时持有完整结果；提前捕获操作数不提前更新 ROB/架构状态。
    // 仅接纳握手、无异常且完整 ID 仍存活时广播，恢复/提交重定向关闭此旁路。
    for (genvar src = 0; src < 3; src++) begin : g_early_broadcast
        retire_gpr_entry_t producer;
        assign producer = producers[completion_input[src].id.slot];
        assign broadcast[2+src] = '{valid:completion_input_valid[src] && completion_input_ready[src] &&
            !selected_redirect.valid && !completion_input[src].result.exc.valid &&
            producer.valid && producer.gpr_write && producer.id == completion_input[src].id,
            id:completion_input[src].id, data:completion_input[src].result.gpr_data};
    end
    // 合法返回保留两口及 ROB 校验；Store 提示按固定 LQ 槽广播，保留原同口返回优先。
    for (genvar portno = 0; portno < 2; portno++) begin : g_load_broadcast
        retire_gpr_entry_t return_producer;
        assign return_producer = producers[lsu_load_return[portno].id.slot];
        assign broadcast[LSU_RETURN_FIRST+portno] = '{valid:lsu_load_return[portno].valid &&
            !selected_redirect.valid && return_producer.valid && return_producer.gpr_write &&
            return_producer.id == lsu_load_return[portno].id,
            id:lsu_load_return[portno].id, data:lsu_load_return[portno].data};
    end
    // 提示来自未完成的 LQ 槽，槽内已处理存活、取消与完整 ID；此时 ROB 不能退休该 Load。
    // 固定槽标签与数据和端口仲裁并行到达 IQ；恢复仍同拍关闭捕获，不增加执行周期。
    for (genvar slot = 0; slot < (STORE_HINT_ENABLE ? LOAD_QUEUE_ENTRIES : 0); slot++) begin : g_store_slot_broadcast
        assign broadcast[LSU_HINT_FIRST+slot] = '{valid:lsu_store_slot_hint[slot].valid &&
            !selected_redirect.valid,
            id:lsu_store_slot_hint[slot].id, data:lsu_store_slot_hint[slot].data};
    end
    // 分支取消后仍等待外部事务排空，保证有限代次不能在迟到响应之前被回卷重用。
    assign drain_complete = !decode_jump_q.valid && !issue_busy && !lsu_busy && mdu_req_ready && !(|completion_busy);
    retire_queue #(.RENAMED(1), .REGISTER_RETIRE(1)) u_retire_queue (
        .clk, .rst, .flush_all(wb_redirect.valid), .drain_complete, .branch_recovery(recovery),
        .producer_entries(producers), .ras_entries, .ras_head_slot(head_slot),
        .alloc_valid(decode_q[0].valid && iq_capacity != 0 && checkpoint_ready && !selected_redirect.valid),
        .alloc_ready(alloc_ready[0]), .alloc_meta(alloc_meta[0]), .alloc_id(alloc_id[0]),
        .alloc_valid_1(decode_q[1].valid && iq_capacity == 2),
        .alloc_ready_1(alloc_ready[1]), .alloc_meta_1(alloc_meta[1]), .alloc_id_1(alloc_id[1]),
        .probe_id(accept_probe_id), .probe_accept(source_accept), .probe_live(source_live),
        .complete_valid(completion_valid[0]), .complete_ready(complete_ready[0]),
        .completion(completed[0]), .complete_reject(completion_reject[0]),
        .complete_valid_1(completion_valid[1]), .complete_ready_1(complete_ready[1]),
        .completion_1(completed[1]), .complete_reject_1(completion_reject[1]),
        .query('0), .query_result(), .query_1('0), .query_result_1(),
        .head_valid(head_valid[0]), .head_complete(head_complete[0]), .head_id(head_ids[0]),
        .head_meta(head_metadata[0]), .head_result(head_results[0]),
        .head_valid_1(head_valid[1]), .head_complete_1(head_complete[1]), .head_id_1(head_ids[1]),
        .head_meta_1(head_metadata[1]), .head_result_1(head_results[1]),
        .retire_ready(retire_ready[0]), .retire_fire(retire_fire[0]),
        .retire_ready_1(retire_ready[1]), .retire_fire_1(retire_fire[1]),
        .occupancy(rob_occupancy), .recovering(rob_recovering)
    );
    assign retire_ready[0] = !rst &&
        (head_metadata[0].kind != RET_BRANCH || training_capacity != 0);
    assign retire_ready[1] = !rst && !head_results[0].exc.valid && !head_results[1].exc.valid &&
        !(head_metadata[0].kind inside {RET_CSR, RET_SERIAL}) &&
        !(head_metadata[1].kind inside {RET_CSR, RET_SERIAL}) &&
        (training_capacity >= 2'(2'(head_metadata[0].kind == RET_BRANCH) +
                          2'(head_metadata[1].kind == RET_BRANCH)));
    for (genvar lane = 0; lane < 2; lane++) begin : g_retire
        commit_control u_commit (
            .retire_fire(retire_fire[lane]), .head_meta(head_metadata[lane]), .head_result(head_results[lane]),
            .gpr_write(gpr_write[lane]), .csr_write(csr_write[lane]),
            .commit_valid(commit_trace[lane].valid), .commit_pc(commit_trace[lane].pc),
            .commit_inst(commit_trace[lane].inst), .commit_rd(commit_trace[lane].rd),
            .commit_rd_we(commit_trace[lane].rd_we), .commit_rd_data(commit_trace[lane].rd_data),
            .commit_exception(commit_trace[lane].exception)
        );
        assign commit_trace[lane].id = head_ids[lane];
        // trace 报告实际架构后继；异常与 MRET 的目标由提交时 CSR 状态决定。
        assign commit_trace[lane].next_pc = head_results[lane].exc.valid ? mtvec :
            (head_metadata[lane].sys_op == SYS_MRET ? mepc : head_results[lane].next_pc);
        predictor_commit_update u_update (
            .retire_fire(retire_fire[lane]), .head_meta(head_metadata[lane]),
            .head_result(head_results[lane]), .update(training[lane])
        );
    end
    assign commit_valid = commit_trace[0].valid;
    assign commit_pc = commit_trace[0].pc;
    assign commit_inst = commit_trace[0].inst;
    assign commit_rd = commit_trace[0].rd;
    assign commit_rd_we = commit_trace[0].rd_we;
    assign commit_rd_data = commit_trace[0].rd_data;
    assign commit_exception = commit_trace[0].exception;
    csr_file u_csr_file (
        .clk, .rst, .irq_software, .irq_timer, .irq_external, .irq_pending, .irq_cause,
        .read_addr(scheduled[0].csr_addr), .read_data(csr_data),
        .write_valid(csr_write[0].valid), .write_addr(csr_write[0].addr),
        .write_legal_data(csr_write[0].data), .retire_valid(normal_retire),
        .retire_extra(retire_fire[1]), .trap_enter, .trap_pc, .trap_cause, .trap_tval,
        .mret_commit, .mtvec, .mepc
    );
    interrupt_entry u_interrupt (
        .clk, .rst, .irq_pending,
        .pipeline_busy(fetch_busy || decode_jump_q.valid || decode_q[0].valid || iq_occupancy != 0 || issue_busy ||
                       rob_occupancy != 0 || rob_recovering || lsu_busy || !mdu_req_ready || |completion_busy),
        .retire_valid(normal_retire),
        .commit_next_pc(retire_fire[1] ? head_results[1].next_pc : head_results[0].next_pc),
        .wb_redirect, .interrupt_take, .interrupt_pc
    );
    trap_controller u_trap (
        .head_meta(head_metadata[0]), .head_result(head_results[0]), .commit_valid,
        .interrupt_take, .interrupt_pc, .interrupt_cause(irq_cause), .mtvec, .mepc,
        .trap_enter, .mret_commit, .trap_pc, .trap_cause, .trap_tval,
        .retire_valid(normal_retire), .execution_cancel, .redirect(wb_redirect)
    );
`ifndef SYNTHESIS
    initial begin
        assert (ISSUE_WIDTH == 2) else $fatal(1, "scoreboard backend requires ISSUE_WIDTH=2");
        assert (!LIMITED_INTEGER_OOO || SPLIT_ISSUE_QUEUE) else $fatal(1, "limited issue requires split IQ");
        assert (COMPLETION_SOURCES == LSU_RETURN_FIRST && LSU_HINT_FIRST == LSU_RETURN_FIRST+2 &&
                BROADCAST_SOURCES == LSU_HINT_FIRST+(STORE_HINT_ENABLE ? LOAD_QUEUE_ENTRIES : 0))
            else $fatal(1, "LSU broadcast mapping");
        assert (SCHEDULER_FORWARD_MODE inside {IQ_FORWARD_ALL, IQ_FORWARD_BRANCH_COMPLETION,
                IQ_FORWARD_LSU_CAPTURE, IQ_FORWARD_STORE_CAPTURE})
            else $fatal(1, "scheduler forward mode");
    end
    always_ff @(posedge clk) if (!rst) begin
        assert (!issue_fire[1] || issue_fire[0]) else $fatal(1, "non-prefix issue");
        assert (&complete_ready) else $fatal(1, "completion selector requires ready ROB");
        // 预检接受与 ROB complete_match 必须同拍一致；否则广播会越过动态校验。
        assert (!(completion_valid[0] && completion_reject[0]) &&
                !(completion_valid[1] && completion_reject[1]))
            else $fatal(1, "broadcast of completion rejected by ROB");
        assert (!recovery.valid || (issue_enqueue_count == 0 && issue_count == 0 &&
                                    dispatch_count == 0 && issue_fire == 0))
            else $fatal(1, "operand preview executed during recovery");
        assert (!broadcast[1].valid || !broadcast[0].valid || broadcast[1].id != broadcast[0].id)
            else $fatal(1, "duplicate completion operand preview");
        for (int lane = 0; lane < 2; lane++) if (alloc_fire[lane]) begin
            // 改名绑定只允许读取更老生产者；恢复时被取消的年轻结果不能喂给存活老项。
            if (renamed[lane].rs1_dependency.pending)
                assert (younger_than(renamed[lane].retire_id, renamed[lane].rs1_dependency.id,
                                    head_slot + RETIRE_IDX_W'(head_advance)))
                    else $fatal(1, "rs1 producer is not older than consumer");
            if (renamed[lane].rs2_dependency.pending)
                assert (younger_than(renamed[lane].retire_id, renamed[lane].rs2_dependency.id,
                                    head_slot + RETIRE_IDX_W'(head_advance)))
                    else $fatal(1, "rs2 producer is not older than consumer");
        end
        // 持续核对被移除的重复硬件资格检查，覆盖 x0 Load、ROB 回卷与分支取消。
        for (int portno = 0; portno < 2; portno++) begin
            if (lsu_store_forward_hint[portno].valid && !selected_redirect.valid)
                assert (producers[lsu_store_forward_hint[portno].id.slot].valid &&
                        producers[lsu_store_forward_hint[portno].id.slot].gpr_write &&
                        producers[lsu_store_forward_hint[portno].id.slot].id == lsu_store_forward_hint[portno].id)
                    else $fatal(1, "Store hint lost live ROB Load owner");
        end
        assert (lsu_head_slot == head_slot && completion_head_slot == head_slot)
            else $fatal(1, "local ROB head view drifted across retirement or recovery");
    end
`endif
endmodule
