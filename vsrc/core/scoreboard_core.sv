// Module: scoreboard_core
// Description: In-order dual-issue backend with ROB-tag renaming, independent completion and precise retirement.
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
    branch_result_t queued_branch [2], scheduled_branch [2];
    logic input_branch_lane, input_branch_taken;
    xlen_t input_branch_target;
    d2_ex_t input_branch_packet;
    pred_info_t prediction [2];
    pred_update_t training [2], predictor_update;
    xlen_t lookup_pc, lookup_pc_1;
    logic ras_top_valid;
    xlen_t ras_top_addr;
    logic fetch_fire, fetch_second, fetch_busy;
    logic [1:0] fetch_pop_count, dispatch_count, issue_count, iq_capacity, iq_ready;
    logic [1:0] alloc_fire, alloc_ready, retire_fire, head_valid, head_complete;
    logic [1:0] completion_valid, completion_reject, complete_ready, training_capacity;
    logic [1:0] retire_ready, lane_ready, integer_ready;
    logic [1:0] branch_event_valid_q, branch_wrong_q;
    retire_id_t branch_id_q [2];
    xlen_t branch_next_pc_q [2];
    // LSQ 每个物理槽仍保存自己的结果；中央只接收本地选出的两项完成。
    // 中央完成源由 11 降为 5，减少跨模块连线、扇出和放置拥塞。
    // LSQ 本地选择仍按年龄选最老两项，取消/错误/逐槽结果语义不变。
    localparam int LSU_COMPLETIONS = 2;
    localparam int COMPLETION_SOURCES = 3 + LSU_COMPLETIONS;
    logic [COMPLETION_SOURCES-1:0] source_valid, source_preview_valid, source_ready, completion_busy;
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
    retire_gpr_forward_t broadcast [COMPLETION_SOURCES+2];
    gpr_forward_t gpr_write [2];
    csr_forward_t csr_write [2];
    xlen_t rf_rs1 [2], rf_rs2 [2];
    logic [RETIRE_COUNT_W-1:0] rob_occupancy;
    logic [$clog2(ISSUE_QUEUE_ENTRIES+1)-1:0] iq_occupancy;
    logic [RETIRE_IDX_W-1:0] head_slot;
    // 两个局部视图与 ROB 使用同一退休增量；不是延迟一拍的 head。
    // ADS UG990102 8.2.17：保留等价寄存器，避免综合重新合并跨模块年龄网络。
    logic [RETIRE_IDX_W-1:0] lsu_head_slot /* synthesis syn_preserve=1 */;
    logic [RETIRE_IDX_W-1:0] completion_head_slot /* synthesis syn_preserve=1 */;
    logic [1:0] head_advance;
    logic rob_recovering, drain_complete, checkpoint_ready, branch_resolved;
    retire_id_t resolved_id;
    branch_recovery_t recovery;
    redirect_t wb_redirect, selected_redirect;
    redirect_t d1_redirect [2], decode_jump_q, frontend_redirect;
    logic branch_lane, mdu_lane;
    logic branch_taken;
    xlen_t branch_target;
    schedule_class_e lane_class [2];
    lsu_descriptor_t descriptor [2];
    logic mdu_req_valid, mdu_req_ready, mdu_cancel;
    muldiv_req_t mdu_request;
    retire_id_t mdu_id_q;
    retire_gpr_forward_t lsu_early_forward [2];
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
        d1_stage u_decode (.in_packet(fetched[lane]), .out_packet(decoded[lane]),
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
            decode_intake[lane].valid = int'(fetch_pop_count) > lane;
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
    scoreboard_queue #(.BROADCAST_PORTS(COMPLETION_SOURCES+2), .ISSUE_BYPASS(1)) u_scoreboard (
        .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot,
        .push_count(dispatch_count), .push_packet(renamed), .push_capacity(iq_capacity),
        .producers, .broadcast, .issue_packet(queued), .operands_ready(iq_ready),
        .pop_count(issue_enqueue_count), .occupancy(iq_occupancy)
    );

    // IQ→ISS 只接纳已就绪年龄前缀；执行反压由两项寄存包保持完整数据和 ID。
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
    issue_queue u_issue (
        .clk, .rst, .flush(wb_redirect.valid), .recovery, .head_slot,
        .push_count(issue_enqueue_count), .push_packet(queued), .push_branch(queued_branch), .push_capacity(issue_capacity),
        .pop_count(issue_count), .issue_packet(scheduled), .issue_branch(scheduled_branch),
        .occupancy(issue_occupancy), .busy(issue_busy)
    );

    // 分支和 MDU 共享资源，可从任一年龄槽取得操作数；两个 ALU 和 AGU 各自计算。
    assign branch_lane = scheduled[0].uop.branch_op == BR_NONE;
    assign branch_taken = scheduled_branch[branch_lane].taken;
    assign branch_target = scheduled_branch[branch_lane].target;
    // 分支只在 IQ→ISS 接纳时判定一次，结果随 ISS 包保持，EX 不重复发恢复事件。
    assign input_branch_lane = schedule_class(queued[0]) != SCHED_BRANCH;
    assign input_branch_packet = queued[input_branch_lane];
    branch_unit u_branch (
        .branch_op(input_branch_packet.uop.branch_op), .pc(input_branch_packet.pc), .seq_pc(input_branch_packet.seq_pc),
        .operand_a(input_branch_packet.rs1_data), .operand_b(input_branch_packet.rs2_data),
        .imm(input_branch_packet.imm), .taken(input_branch_taken), .target(input_branch_target)
    );
    for (genvar lane = 0; lane < 2; lane++) begin : g_issue_branch
        assign queued_branch[lane] = schedule_class(queued[lane]) == SCHED_BRANCH ?
            branch_result_t'{taken:input_branch_taken, target:input_branch_target} : '0;
    end
    for (genvar lane = 0; lane < 2; lane++) begin : g_execute
        scoreboard_execute u_execute (
            .packet(scheduled[lane]), .branch_taken, .branch_target, .csr_old_data(csr_data),
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
        // 完整操作数已被 ISS 接纳；未对齐跳转仍由 EX 形成精确异常，不提前恢复。
        always_ff @(posedge clk) begin
            if (rst || wb_redirect.valid)
                branch_event_valid_q[lane] <= 0;
            else begin
                branch_event_valid_q[lane] <= int'(issue_enqueue_count) > lane &&
                    schedule_class(queued[lane]) == SCHED_BRANCH &&
                    (!input_branch_taken || input_branch_target[1:0] == 0);
                if (int'(issue_enqueue_count) > lane && schedule_class(queued[lane]) == SCHED_BRANCH) begin
                    branch_id_q[lane] <= queued[lane].retire_id;
                    branch_next_pc_q[lane] <= input_branch_taken ? input_branch_target : queued[lane].seq_pc;
                    branch_wrong_q[lane] <= queued[lane].pred.taken != input_branch_taken ||
                        (input_branch_taken && queued[lane].pred.target != input_branch_target);
                end
            end
        end
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
    // 宽操作数只按已寄存的指令类别路由；晚异常/取消仍关闭 issue_fire，
    // 不经 lane_class 的异常选择再进入 DSP 数据多路器。
    assign mdu_lane = schedule_class(scheduled[0]) != SCHED_MDU;
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
        .early_forward(lsu_early_forward), .busy(lsu_busy), .draining(lsu_draining), .store_owner_valid(lsu_owner_valid), .store_owner_id(lsu_owner_id)
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

    // 分支结果先寄存再触发恢复，独立于 ROB 完成仲裁；只上报一次。
    always_comb begin
        branch_resolved = 0; resolved_id = '0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) begin
            if (branch_event_valid_q[lane]) begin
                branch_resolved = 1;
                resolved_id = branch_id_q[lane];
                recovery = '{valid:branch_wrong_q[lane],
                    id:branch_id_q[lane], pc:branch_next_pc_q[lane]};
            end
        end
        selected_redirect = wb_redirect;
        if (!wb_redirect.valid && recovery.valid)
            selected_redirect = '{valid:1'b1, pc:recovery.pc, reason:REDIR_EX_BRANCH};
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
        .rst, .head_slot(completion_head_slot), .source_valid(source_preview_valid), .source_ready, .source_completion(sources),
        .complete_valid(selected_completion_valid), .completion(completed)
    );
    // 全局清空只关闭接纳，不改变已选结果的数据路径；FIFO 清空优先于弹出。
    // ROB 写入、广播及 IQ/ISS 接纳仍受原有效/清空规则约束，不增加或减少等待拍。
    assign completion_valid = selected_completion_valid & {2{!wb_redirect.valid}};
    for (genvar portno = 0; portno < 2; portno++) begin : g_broadcast
        assign broadcast[portno] = '{valid:completion_valid[portno] && !completion_reject[portno] &&
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
    // LSU 提前广播替代原入 CMP 广播，端口总数仍为七路；故障/旧 ID/取消不能唤醒。
    for (genvar portno = 0; portno < 2; portno++) begin : g_load_broadcast
        retire_gpr_entry_t producer;
        assign producer = producers[lsu_early_forward[portno].id.slot];
        assign broadcast[5+portno] = '{valid:lsu_early_forward[portno].valid &&
            !selected_redirect.valid && producer.valid && producer.gpr_write &&
            producer.id == lsu_early_forward[portno].id,
            id:lsu_early_forward[portno].id, data:lsu_early_forward[portno].data};
    end
    // 分支取消后仍等待外部事务排空，保证有限代次不能在迟到响应之前被回卷重用。
    assign drain_complete = !decode_jump_q.valid && !issue_busy && !lsu_busy && mdu_req_ready && !(|completion_busy) && !(|branch_event_valid_q);
    retire_queue #(.RENAMED(1), .REGISTER_RETIRE(1)) u_retire_queue (
        .clk, .rst, .flush_all(wb_redirect.valid), .drain_complete, .branch_recovery(recovery),
        .producer_entries(producers), .ras_entries, .ras_head_slot(head_slot),
        .alloc_valid(decode_q[0].valid && iq_capacity != 0 && checkpoint_ready && !selected_redirect.valid),
        .alloc_ready(alloc_ready[0]), .alloc_meta(alloc_meta[0]), .alloc_id(alloc_id[0]),
        .alloc_valid_1(decode_q[1].valid && iq_capacity == 2),
        .alloc_ready_1(alloc_ready[1]), .alloc_meta_1(alloc_meta[1]), .alloc_id_1(alloc_id[1]),
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
        (int'(training_capacity) >= int'(head_metadata[0].kind == RET_BRANCH) +
                                   int'(head_metadata[1].kind == RET_BRANCH));
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
                       rob_occupancy != 0 || rob_recovering || lsu_busy || !mdu_req_ready || |completion_busy || |branch_event_valid_q),
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
    end
    always_ff @(posedge clk) if (!rst) begin
        assert (!issue_fire[1] || issue_fire[0]) else $fatal(1, "non-prefix issue");
        assert (&complete_ready) else $fatal(1, "completion selector requires ready ROB");
        assert (lsu_head_slot == head_slot && completion_head_slot == head_slot)
            else $fatal(1, "local ROB head view drifted across retirement or recovery");
    end
`endif
endmodule
