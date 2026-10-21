// Module: retire_queue
// Description: Owns ordered retirement state with one or two allocation, completion and retirement ports.
// Core 在 D2 分配，WB/LSU/独立 MDU 仲裁完成，第二 ALU 使用独立完成口。
// 取消/复位后须确认旧生产者排空，才能恢复分配。
// 有限代次不能识别任意长时间后的旧响应；drain_complete 是外部所有者提供的协议保证。
module retire_queue #(
    parameter bit RENAMED = 1'b0,
    parameter bit REGISTER_RETIRE = 1'b0
) (
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  flush_all,
    input  logic                                  drain_complete,
    input  logic                                  alloc_valid,
    output logic                                  alloc_ready,
    input  pipeline_pkg::retire_alloc_t            alloc_meta,
    output pipeline_pkg::retire_id_t               alloc_id,
    input  logic                                  complete_valid,
    output logic                                  complete_ready,
    input  pipeline_pkg::retire_completion_t       completion,
    output logic                                  complete_reject,
    input  pipeline_pkg::retire_query_t            query,
    output pipeline_pkg::retire_query_result_t     query_result,
    output pipeline_pkg::retire_ras_entry_t        ras_entries [core_config_pkg::RETIRE_ENTRIES],
    output logic [core_config_pkg::RETIRE_IDX_W-1:0] ras_head_slot,
    output logic                                  head_valid,
    output logic                                  head_complete,
    output pipeline_pkg::retire_id_t               head_id,
    output pipeline_pkg::retire_alloc_t            head_meta,
    output pipeline_pkg::retire_result_t           head_result,
    input  logic                                  retire_ready,
    output logic                                  retire_fire,
    output logic [core_config_pkg::RETIRE_COUNT_W-1:0] occupancy,
    output logic                                  recovering,
    input  logic                                  alloc_valid_1,
    output logic                                  alloc_ready_1,
    input  pipeline_pkg::retire_alloc_t            alloc_meta_1,
    output pipeline_pkg::retire_id_t               alloc_id_1,
    input  logic                                  complete_valid_1,
    output logic                                  complete_ready_1,
    input  pipeline_pkg::retire_completion_t       completion_1,
    output logic                                  complete_reject_1,
    input  pipeline_pkg::retire_query_t            query_1,
    output pipeline_pkg::retire_query_result_t     query_result_1,
    output logic                                  head_valid_1,
    output logic                                  head_complete_1,
    output pipeline_pkg::retire_id_t               head_id_1,
    output pipeline_pkg::retire_alloc_t            head_meta_1,
    output pipeline_pkg::retire_result_t           head_result_1,
    input  logic                                  retire_ready_1,
    output logic                                  retire_fire_1,
    input  scoreboard_pkg::branch_recovery_t       branch_recovery,
    output pipeline_pkg::retire_gpr_entry_t        producer_entries [core_config_pkg::RETIRE_ENTRIES]
);
    import core_config_pkg::*;
    import pipeline_pkg::*;

    // 队列独占 valid/done、年龄顺序和结果；LSU 事务状态与源操作数不保存在这里。
    logic [RETIRE_ENTRIES-1:0] valid_q, done_q;
    logic [RETIRE_IDX_W-1:0] head_q, tail_q;
    logic [RETIRE_COUNT_W-1:0] count_q;
    logic [RETIRE_GEN_W-1:0] generation_q [RETIRE_ENTRIES];
    retire_alloc_t meta_q [RETIRE_ENTRIES];
    retire_result_t result_q [RETIRE_ENTRIES];
    logic recovering_q;

    logic alloc_fire, complete_fire, complete_match;
    logic alloc_fire_1, complete_fire_1, complete_match_1;
    logic [RETIRE_IDX_W-1:0] second_head, second_tail;
    logic [1:0] head_bypass, second_head_bypass;
    logic [1:0] alloc_count, retire_count;
    logic [RETIRE_COUNT_W:0] available_slots;
    retire_result_t completed_result, completed_result_1;
    retire_gpr_entry_t query_entries [RETIRE_ENTRIES];
    retire_query_result_t second_query_result;
    logic recover_branch;
    logic [RETIRE_IDX_W-1:0] recovery_distance;
    logic [RETIRE_COUNT_W-1:0] recovery_count;
    logic [RETIRE_ENTRIES-1:0] killed;

    assign recover_branch = RENAMED && branch_recovery.valid;
    assign recovery_distance = branch_recovery.id.slot - head_q;
    assign recovery_count = RETIRE_COUNT_W'(recovery_distance) + RETIRE_COUNT_W'(1);
    for (genvar slot = 0; slot < RETIRE_ENTRIES; slot++) begin : g_recovery
        assign killed[slot] = recover_branch && valid_q[slot] &&
            scoreboard_pkg::younger_than(
                '{slot:RETIRE_IDX_W'(slot), generation:generation_q[slot]}, branch_recovery.id, head_q);
        assign producer_entries[slot] = query_entries[slot];
    end

    assign second_head = head_q + RETIRE_IDX_W'(1);
    assign second_tail = tail_q + RETIRE_IDX_W'(1);

    // RAS恢复读取现有静态包与done异常，不能复制第二个年龄队列。
    assign ras_head_slot = head_q;
    for (genvar slot = 0; slot < RETIRE_ENTRIES; slot++) begin : g_ras_entry
        always_comb begin
            ras_entries[slot] = '0;
            ras_entries[slot].valid = !rst && valid_q[slot];
            if (valid_q[slot]) begin
                ras_entries[slot].id = '{slot:RETIRE_IDX_W'(slot), generation:generation_q[slot]};
                ras_entries[slot].event_info = '{op:meta_q[slot].ras_op, addr:meta_q[slot].seq_pc};
                ras_entries[slot].exception = done_q[slot] && result_q[slot].exc.valid;
            end
        end
    end

    // 查询只连接现有槽状态；没有独立的 busy/done/结果副本，也不读取未完成槽的旧数据。
    for (genvar slot = 0; slot < RETIRE_ENTRIES; slot++) begin : g_query_entry
        always_comb begin
            query_entries[slot] = '0;
            query_entries[slot].valid = !rst && valid_q[slot];
            query_entries[slot].id = '{slot:RETIRE_IDX_W'(slot), generation:generation_q[slot]};
            if (valid_q[slot]) begin
                query_entries[slot].gpr_write = meta_q[slot].gpr_write;
                query_entries[slot].rd = meta_q[slot].rd;
                query_entries[slot].kind = meta_q[slot].kind;
                query_entries[slot].ready = done_q[slot] && !result_q[slot].exc.valid;
                if (done_q[slot]) query_entries[slot].data = result_q[slot].gpr_data;
            end
        end
    end
    retire_gpr_query u_gpr_query (
        .entries(query_entries), .head_slot(head_q),
        .normal_retire(retire_fire && !head_result.exc.valid), .retiring_id(head_id),
        .normal_retire_1(retire_fire_1 && !head_result_1.exc.valid), .retiring_id_1(head_id_1),
        .query, .query_result
    );
    retire_gpr_query u_gpr_query_1 (
        .entries(query_entries), .head_slot(head_q),
        .normal_retire(retire_fire && !head_result.exc.valid), .retiring_id(head_id),
        .normal_retire_1(retire_fire_1 && !head_result_1.exc.valid), .retiring_id_1(head_id_1),
        .query(query_1), .query_result(second_query_result)
    );
    assign query_result_1 = (ISSUE_WIDTH == 2) ? second_query_result : '0;

`ifndef SYNTHESIS
    // 自然回卷依赖二次幂容量；独立实例化也必须拒绝不受支持的构建参数。
    initial begin
        assert (RETIRE_ENTRIES inside {2, 4, 8, 16})
            else $fatal(1, "CORE_RETIRE_ENTRIES must be 2, 4, 8, or 16");
        assert ((ISSUE_WIDTH == 1) || (ISSUE_WIDTH == 2))
            else $fatal(1, "CORE_ISSUE_WIDTH must be 1 or 2");
    end
`endif

    // 非法、重复、已取消的完成也接收并丢弃，避免旧生产者永久占住完成通道。
    // 完成不接受本拍才分配的 ID；生产者只能在取得 ID 后开始执行。
    assign complete_ready = !rst;
    assign complete_ready_1 = !rst && (ISSUE_WIDTH == 2);
    assign complete_fire = complete_valid && complete_ready;
    assign complete_fire_1 = complete_valid_1 && complete_ready_1;
    assign complete_match = valid_q[completion.id.slot] &&
                            (generation_q[completion.id.slot] == completion.id.generation) &&
                            !done_q[completion.id.slot] && !killed[completion.id.slot];
    // 同一完整 ID 不得完成两次；重复输入由端口0接纳，第二口显式拒绝而不覆盖结果。
    assign complete_match_1 = valid_q[completion_1.id.slot] &&
                             (generation_q[completion_1.id.slot] == completion_1.id.generation) &&
                             !done_q[completion_1.id.slot] && !killed[completion_1.id.slot] &&
                             !(complete_fire && complete_match && completion.id == completion_1.id);
    assign head_bypass[0] = complete_fire && complete_match && (completion.id.slot == head_q);
    assign head_bypass[1] = complete_fire_1 && complete_match_1 && (completion_1.id.slot == head_q);
    assign second_head_bypass[0] = complete_fire && complete_match && (completion.id.slot == second_head);
    assign second_head_bypass[1] = complete_fire_1 && complete_match_1 && (completion_1.id.slot == second_head);

    // 非分支后继来自静态包，MDU 不必为了退休重复保存 PC；分支传入真实后继。
    always_comb begin
        completed_result = completion.result;
        if (meta_q[completion.id.slot].kind != RET_BRANCH)
            completed_result.next_pc = meta_q[completion.id.slot].seq_pc;
        completed_result_1 = completion_1.result;
        if (meta_q[completion_1.id.slot].kind != RET_BRANCH)
            completed_result_1.next_pc = meta_q[completion_1.id.slot].seq_pc;
    end

    // head 不受 flush_all 组合屏蔽：队头异常/MRET/FENCE 本身就可能产生 flush。
    // 独立外部取消须由提交端关闭 retire_ready；队头产生的事件可与清队列同拍。
    // 旁路只允许匹配两个最老槽的完成；源来自已寄存的 WB、LSU 响应、MDU RESULT或第二ALU结果。
    // scoreboard 使用已存储的结果退休，隔开完成仲裁与全局异常/取指反馈；每拍仍可退休两条。
    always_comb begin
        head_valid = !rst && valid_q[head_q];
        head_complete = head_valid && (done_q[head_q] || (!REGISTER_RETIRE && (|head_bypass)));
        head_id = '0;
        head_meta = '0;
        head_result = '0;
        if (head_valid) begin
            head_id = '{slot: head_q, generation: generation_q[head_q]};
            head_meta = meta_q[head_q];
            if (!REGISTER_RETIRE && head_bypass[0])
                head_result = completed_result;
            else if (!REGISTER_RETIRE && head_bypass[1])
                head_result = completed_result_1;
            else if (done_q[head_q])
                head_result = result_q[head_q];
        end
    end
    // 提交许可与head载荷组包分块，避免ready经整块敏感性被误看作metadata反馈。
    assign retire_fire = head_complete && retire_ready;

    // 第二头永远是 head+1，不允许跳过未完成的第一头。异常/CSR等架构配对限制由提交端给出。
    // 两个完成源都能旁路到任一队头；flush不参与有效性计算，避免自身Trap组合反馈。
    always_comb begin
        head_valid_1 = !rst && (ISSUE_WIDTH == 2) && (count_q > RETIRE_COUNT_W'(1)) &&
                       valid_q[second_head] && !killed[second_head];
        head_complete_1 = head_valid_1 && (done_q[second_head] ||
                          (!REGISTER_RETIRE && (|second_head_bypass)));
        head_id_1 = '0;
        head_meta_1 = '0;
        head_result_1 = '0;
        if (head_valid_1) begin
            head_id_1 = '{slot:second_head, generation:generation_q[second_head]};
            head_meta_1 = meta_q[second_head];
            if (!REGISTER_RETIRE && second_head_bypass[0])
                head_result_1 = completed_result;
            else if (!REGISTER_RETIRE && second_head_bypass[1])
                head_result_1 = completed_result_1;
            else if (done_q[second_head])
                head_result_1 = result_q[second_head];
        end
    end
    assign retire_fire_1 = retire_fire && head_complete_1 && retire_ready_1;

    assign retire_count = {1'b0, retire_fire} + {1'b0, retire_fire_1};
    assign alloc_count = {1'b0, alloc_fire} + {1'b0, alloc_fire_1};
    assign available_slots = (RETIRE_COUNT_W+1)'(RETIRE_ENTRIES) -
                             {1'b0, count_q} + (RETIRE_COUNT_W+1)'(retire_count);

    // 满队列允许最老槽弹出与尾槽分配同拍，分配的新代次不能被旧完成覆盖。
    // flush 的状态写入优先；恢复确认沿后才重新开放分配，防止旧 ID 过早复用。
    always_comb begin
        alloc_ready = !rst && !flush_all && !recover_branch && !recovering_q &&
                      (available_slots != '0);
        alloc_id = '{slot: tail_q, generation: generation_q[tail_q] + RETIRE_GEN_W'(1)};
        alloc_fire = alloc_valid && alloc_ready;
        // 分配只接受有效年龄前缀；第二口不能单独绕过第一条或消耗仅剩的一个空槽。
        alloc_ready_1 = (ISSUE_WIDTH == 2) && alloc_fire && available_slots >= (RETIRE_COUNT_W+1)'(2);
        alloc_id_1 = '{slot:second_tail, generation:generation_q[second_tail] + RETIRE_GEN_W'(1)};
        alloc_fire_1 = alloc_valid_1 && alloc_ready_1;
        complete_reject = complete_fire &&
                          (!complete_match || (flush_all &&
                           !((head_bypass[0] && retire_fire) || (second_head_bypass[0] && retire_fire_1))));
        complete_reject_1 = complete_fire_1 &&
                            (!complete_match_1 || (flush_all &&
                             !((head_bypass[1] && retire_fire) || (second_head_bypass[1] && retire_fire_1))));
        occupancy = count_q;
        recovering = recovering_q;
    end

    // 指针和占用数只追踪接纳/弹出，完成顺序不影响程序年龄。
    always_ff @(posedge clk) begin
        if (rst || flush_all) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
        end else if (recover_branch) begin
            tail_q <= branch_recovery.id.slot + RETIRE_IDX_W'(1);
            head_q <= head_q + RETIRE_IDX_W'(retire_count);
            count_q <= recovery_count - RETIRE_COUNT_W'(retire_count);
        end else begin
            tail_q <= tail_q + RETIRE_IDX_W'(alloc_count);
            head_q <= head_q + RETIRE_IDX_W'(retire_count);
            count_q <= count_q + RETIRE_COUNT_W'(alloc_count) - RETIRE_COUNT_W'(retire_count);
        end
    end

    // 同槽更新按完成、退休、重新分配排序；满队列复用时新 valid/done 最后生效。
    always_ff @(posedge clk) begin
        if (rst || flush_all) begin
            valid_q <= '0;
            done_q <= '0;
        end else begin
            if (complete_fire && complete_match)
                done_q[completion.id.slot] <= 1'b1;
            if (complete_fire_1 && complete_match_1)
                done_q[completion_1.id.slot] <= 1'b1;
            if (retire_fire) begin
                valid_q[head_q] <= 1'b0;
                done_q[head_q] <= 1'b0;
            end
            if (retire_fire_1) begin
                valid_q[second_head] <= 1'b0;
                done_q[second_head] <= 1'b0;
            end
            if (alloc_fire) begin
                valid_q[tail_q] <= 1'b1;
                done_q[tail_q] <= 1'b0;
            end
            if (alloc_fire_1) begin
                valid_q[second_tail] <= 1'b1;
                done_q[second_tail] <= 1'b0;
            end
            for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
                if (killed[slot]) begin
                    valid_q[slot] <= 1'b0;
                    done_q[slot] <= 1'b0;
                end
            end
        end
    end

    // flush 保留各物理槽的代次；复位要求外部生产者一并复位或排空。
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int slot = 0; slot < RETIRE_ENTRIES; slot++)
                generation_q[slot] <= '0;
        end else begin
            if (alloc_fire)
                generation_q[tail_q] <= alloc_id.generation;
            if (alloc_fire_1)
                generation_q[second_tail] <= alloc_id_1.generation;
        end
    end

    // 无效载荷不复位；valid/done 才能授权使用，避免全表数据复位增加扇出。
    always_ff @(posedge clk) begin
        if (alloc_fire)
            meta_q[tail_q] <= alloc_meta;
        if (alloc_fire_1)
            meta_q[second_tail] <= alloc_meta_1;
    end

    // 每个物理槽在本地核对完整 ID 与写许可，避免动态索引匹配驱动整张结果表。
    // 静态 seq_pc 同样取本槽，分支保留执行结果；重复 ID 仍由端口 0 优先。
    for (genvar slot = 0; slot < RETIRE_ENTRIES; slot++) begin : g_result_write
        logic write_first, write_second;
        retire_result_t local_first, local_second;
        assign write_first = complete_fire && !flush_all && valid_q[slot] && !done_q[slot] &&
            !killed[slot] && completion.id.slot == RETIRE_IDX_W'(slot) &&
            completion.id.generation == generation_q[slot];
        assign write_second = complete_fire_1 && !flush_all && valid_q[slot] && !done_q[slot] &&
            !killed[slot] && completion_1.id.slot == RETIRE_IDX_W'(slot) &&
            completion_1.id.generation == generation_q[slot] && !write_first;
        always_comb begin
            local_first = completion.result;
            local_second = completion_1.result;
            if (meta_q[slot].kind != RET_BRANCH) begin
                local_first.next_pc = meta_q[slot].seq_pc;
                local_second.next_pc = meta_q[slot].seq_pc;
            end
        end
        always_ff @(posedge clk) begin
            if (write_first)
                result_q[slot] <= local_first;
            else if (write_second)
                result_q[slot] <= local_second;
        end
    end

    // 恢复期仍排空完成口，但不接纳新指令；一位 epoch 甚至更多位都不能替代此边界。
    always_ff @(posedge clk) begin
        if (rst || flush_all || recover_branch)
            recovering_q <= 1'b1;
        else if (drain_complete)
            recovering_q <= 1'b0;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && recover_branch && !flush_all) begin
        assert (valid_q[branch_recovery.id.slot] &&
                generation_q[branch_recovery.id.slot] == branch_recovery.id.generation &&
                meta_q[branch_recovery.id.slot].kind == RET_BRANCH)
            else $fatal(1, "ROB recovery does not name a live branch");
    end
`endif
endmodule
