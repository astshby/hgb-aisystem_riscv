// Module: tb_core_predictor_retire
// Description: Checks retirement-only predictor training with independent branch, table and ID models.
module tb_core_predictor_retire;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    logic imem_rsp_error = 0;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    logic commit_valid, commit_rd_we, commit_exception, fence_i_commit, irq_timer = 0;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic bus_pending;
    int bus_delay, request_delay, scenario, finish_pc, expected_pc, irq_resume;
    int trains, retires, requests, traps, interrupts, mrets, fences, fence_is;
    int held_branch, early_jal, early_ex, redirect_trains, query_checks;
    int total_trains = 0, total_queries = 0, total_redirect_trains = 0;
    int next_fetch, history_updates, stale_snapshot, stale_trains;
    int total_stale_snapshot = 0, total_stale_trains = 0;
    int local_trains, chooser_trains, candidate_stale;
    int total_local_trains = 0, total_chooser_trains = 0, total_candidate_stale = 0;
    int observation_cycle, old_div_retire_cycle, candidate_fetch_cycle;
    int early_conditional, candidate_trained;
    bit old_div_issued, old_div_retired, candidate_bound;
    retire_id_t candidate_id;
    bit done, irq_started;
    bit young_allocated;
    retire_id_t young_id;
    branch_op_e expected_kind [128];
    bit expected_taken [128], expected_fault [128];
    xlen_t expected_target [128];

    // 独立表模型只在正常分支退休时更新；查询在同沿更新之前检查 read-first。
    bit table_valid [BTB_ENTRIES];
    xlen_t table_tag [BTB_ENTRIES], table_target [BTB_ENTRIES];
    branch_op_e table_kind [BTB_ENTRIES];
    int patterns [PHT_ENTRIES], history;
    int local_histories [LOCAL_ENTRIES], local_patterns [1 << LOCAL_HISTORY_W];
    int choices [CHOOSER_ENTRIES];
    bit token_valid [RETIRE_ENTRIES];
    bit token_stale [RETIRE_ENTRIES];
    retire_id_t token_id [RETIRE_ENTRIES];
    pred_train_context_t token_train [RETIRE_ENTRIES];
    xlen_t token_pc [RETIRE_ENTRIES];
    // 动态取指编号区别同 PC 重取；索引只在外部请求握手时由独立历史模型计算。
    typedef struct packed {
        bit valid, killed;
        int serial, epoch, accepted_cycle;
        xlen_t pc;
        pred_train_context_t train;
    } fetch_model_t;
    fetch_model_t request_model, buffer_model, d1_model, d2_model;
    always #5 clk = ~clk;

    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .irq_software(1'b0), .irq_external(1'b0), .*);
    sim_imem #(.DEPTH_WORDS(128)) u_imem (
        .clk, .rst, .req_valid(imem_req_valid), .req_addr(imem_req_addr),
        .req_ready(imem_req_ready), .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready),
        .rsp_error(), .rsp_error_1()
    );

    // 单事务总线在请求阶段反压，接受后延迟响应；所有接口状态均在沿后改变。
    assign dmem_req_ready = !bus_pending && !dmem_rsp_valid && request_delay == 0;
    always @(posedge clk) begin
        if (rst) begin
            // 请求反压与响应延迟均保留；独立 LSU 不要求普通分支随它一起保持。
            bus_pending <= 0; bus_delay <= 0; request_delay <= 4;
            dmem_rsp_valid <= 0; dmem_rsp_error <= 0; dmem_rsp_rdata <= 0;
            requests = 0;
        end else begin
            if (dmem_req_valid && request_delay != 0) request_delay <= request_delay - 1;
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
            if (bus_pending) begin
                if (bus_delay == 0) begin
                    bus_pending <= 0; dmem_rsp_valid <= 1;
                    dmem_rsp_error <= scenario == 2 || scenario == 3;
                    dmem_rsp_rdata <= xlen_t'(5);
                end else bus_delay <= bus_delay - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (!dmem_req_write && dmem_req_addr == 256 && requests == 0)
                    else $fatal(1, "unexpected predictor-test bus request scenario=%0d", scenario);
                requests++; bus_pending <= 1; bus_delay <= 12;
            end
        end
    end

    // 软件路径与分支结果由程序构造时给出，不用 DUT 的 next_pc/taken 作为期望。
    // 分配/退休表按完整 ID 检查上下文归属；同沿退休先释放，随后才允许复用 slot。
    always @(posedge clk) begin
        if (rst) begin
            expected_pc = 0; done = 0; irq_resume = 0;
            trains = 0; retires = 0; traps = 0; interrupts = 0; mrets = 0;
            fences = 0; fence_is = 0; held_branch = 0; early_jal = 0; early_ex = 0;
            redirect_trains = 0; query_checks = 0; young_allocated = 0; young_id = '0;
            next_fetch = 0; history_updates = 0; stale_snapshot = 0; stale_trains = 0;
            local_trains = 0; chooser_trains = 0; candidate_stale = 0;
            observation_cycle = 0; old_div_retire_cycle = -1; candidate_fetch_cycle = -1;
            early_conditional = 0; candidate_trained = 0;
            old_div_issued = 0; old_div_retired = 0; candidate_bound = 0; candidate_id = '0;
            request_model = '0; buffer_model = '0; d1_model = '0; d2_model = '0;
            history = 0;
            foreach (table_valid[i]) table_valid[i] = 0;
            foreach (patterns[i]) patterns[i] = 1;
            foreach (local_histories[i]) local_histories[i] = 0;
            foreach (local_patterns[i]) local_patterns[i] = 1;
            foreach (choices[i]) choices[i] = 1;
            foreach (token_valid[i]) token_valid[i] = 0;
            foreach (token_stale[i]) token_stale[i] = 0;
        end else begin
            int b, p, l, c, word_idx, slot;
            bit hit, conditional, taken, kill_fetch, response_fire, usable_response;
            xlen_t target;
            pred_train_context_t query_train;
            int query_epoch, query_history;
            fetch_model_t response_model, fetch_model, next_d1, next_d2;
            observation_cycle++;
            b = int'(imem_req_addr >> 2) & (BTB_ENTRIES-1);
            p = (int'(imem_req_addr >> 2) ^ history) & (PHT_ENTRIES-1);
            query_train = '0;
            query_train.pht_idx = PHT_IDX_W'(p);
            query_train.global_taken = patterns[p] >= 2;
            if (PREDICTOR_MODE == 1) begin
                l = local_histories[int'(imem_req_addr >> 2) & (LOCAL_ENTRIES-1)];
                c = int'(imem_req_addr >> 2) & (CHOOSER_ENTRIES-1);
                query_train.local_idx = LOCAL_HISTORY_W'(l);
                query_train.chooser_idx = CHOOSER_IDX_W'(c);
                query_train.local_taken = local_patterns[l] >= 2;
                query_train.choose_local = choices[c] >= 2;
            end
            query_epoch = history_updates; query_history = history;
            hit = table_valid[b] && table_tag[b] == imem_req_addr;
            conditional = hit && table_kind[b] != BR_JAL && table_kind[b] != BR_JALR;
            taken = hit && (conditional ? (query_train.choose_local ? query_train.local_taken :
                                          query_train.global_taken) : 1'b1);
            target = hit ? table_target[b] : xlen_t'(0);
            assert (dut.prediction.hit == hit && dut.prediction.taken == taken &&
                    dut.prediction.target == target && dut.prediction.train == query_train)
                else $fatal(1, "read-first table mismatch scenario=%0d pc=%h", scenario, imem_req_addr);
            query_checks++;

            // 仅使用接口握手与流水边界动作转移参考 token，不读取 DUT 的 request/buffer 元数据。
            kill_fetch = dut.selected_redirect.valid || dut.frontend_flush;
            response_fire = imem_rsp_valid && imem_rsp_ready;
            if (response_fire) assert (request_model.valid) else $fatal(1, "fetch response without independent owner");
            usable_response = response_fire && !request_model.killed && !kill_fetch;
            response_model = request_model; response_model.valid = usable_response;
            fetch_model = buffer_model.valid ? buffer_model : response_model;
            if (kill_fetch) fetch_model.valid = 0;
            assert (dut.fetch_packet.valid == fetch_model.valid &&
                    (!fetch_model.valid || (dut.fetch_packet.pc == fetch_model.pc &&
                     dut.fetch_packet.pred.train == fetch_model.train)))
                else $fatal(1, "IF changed accepted dynamic fetch snapshot serial=%0d", fetch_model.serial);
            assert (dut.d1_d2_q.valid == d2_model.valid &&
                    (!d2_model.valid || (dut.d1_d2_q.pc == d2_model.pc &&
                     dut.d1_d2_q.pred.train == d2_model.train)))
                else $fatal(1, "D2 changed dynamic fetch snapshot serial=%0d", d2_model.serial);
            next_d1 = d1_model; next_d2 = d2_model;
            unique case (dut.pipeline_actions.if_d1)
                PIPE_ADVANCE: next_d1 = fetch_model;
                PIPE_CLEAR: next_d1.valid = 0;
                default: ;
            endcase
            unique case (dut.pipeline_actions.d1_d2)
                PIPE_ADVANCE: next_d2 = d1_model;
                PIPE_CLEAR: next_d2.valid = 0;
                default: ;
            endcase

            // C3c 允许分支在老 LSU 的 PREP/WAIT 任一阶段推进；后续老故障仍须取消它。
            // held 只作观测，不用旧全局等待制造保持覆盖；分支结果保持由独立单元验证。
            if (dut.u_ex_stage.u_branch_result_register.valid_q &&
                (dut.lsu_request_pending || dut.lsu_wait) && !dut.ex_stage_advance) held_branch++;
            if (dut.selected_redirect.valid && dut.selected_redirect.reason == REDIR_D1_JAL &&
                dut.d1_packet.pc == 16 && scenario == 2) early_jal++;
            if (scenario inside {1, 3} && dut.ex_stage_advance &&
                dut.d2_ex_q.pc == xlen_t'(scenario == 1 ? 12 : 16)) begin
                slot = int'(dut.d2_ex_q.retire_id.slot);
                assert (dut.u_ex_stage.branch_valid && token_valid[slot] &&
                        token_id[slot] == dut.d2_ex_q.retire_id &&
                        dut.lsu_owner_valid && !dmem_rsp_valid && traps == 0)
                    else $fatal(1, "EX coverage was not a real full-ID resolution before old response");
                early_ex++;
                if (scenario == 3) assert (young_allocated && young_id == dut.d2_ex_q.retire_id)
                    else $fatal(1, "cancelled branch resolution ID did not match its allocation");
            end
            if (dut.predictor_update.valid && dut.selected_redirect.valid) redirect_trains++;
            if (scenario == 7) begin
                if (dut.mdu_req_valid && dut.mdu_req_ready && dut.d2_ex_q.pc == 8) begin
                    assert (!old_div_issued) else $fatal(1, "stale candidate DIV issued twice");
                    old_div_issued = 1;
                end
                if (dut.ex_stage_advance && dut.d2_ex_q.pc == 12) begin
                    slot = int'(dut.d2_ex_q.retire_id.slot);
                    assert (old_div_issued && !old_div_retired && dut.u_ex_stage.branch_valid &&
                            token_valid[slot] && token_id[slot] == dut.d2_ex_q.retire_id)
                        else $fatal(1, "stale candidate branch did not resolve with full ID before old DIV retired");
                    early_conditional++;
                end
            end
            assert (dut.predictor_update.valid ==
                    (commit_valid && !commit_exception && expected_kind[int'(commit_pc >> 2)] != BR_NONE))
                else $fatal(1, "predictor trained without normal branch retirement scenario=%0d pc=%h", scenario, commit_pc);

            if (commit_valid) begin
                assert (commit_pc == xlen_t'(expected_pc) && commit_inst == u_imem.mem[expected_pc/4])
                    else $fatal(1, "retire path scenario=%0d pc=%h expected=%0d", scenario, commit_pc, expected_pc);
                word_idx = expected_pc/4;
                slot = int'(dut.head_id.slot);
                assert (token_valid[slot] && token_id[slot] == dut.head_id && token_pc[slot] == commit_pc)
                    else $fatal(1, "retirement lost full-ID allocation context");
                token_valid[slot] = 0;
                retires++;
                if (scenario == 7 && commit_pc == 8) begin
                    assert (old_div_issued && !old_div_retired)
                        else $fatal(1, "stale candidate DIV retirement ownership");
                    old_div_retired = 1; old_div_retire_cycle = observation_cycle;
                end
                assert (commit_exception == expected_fault[word_idx]) else $fatal(1, "unexpected exception qualification");
                if (commit_exception) begin
                    assert (!dut.predictor_update.valid && !commit_rd_we)
                        else $fatal(1, "faulting branch trained or wrote GPR");
                    traps++; expected_pc = 128;
                    if (scenario inside {2, 3})
                        assert (young_allocated && (scenario == 2 ? early_jal == 1 : early_ex == 1))
                            else $fatal(1, "old fault cancelled a branch that never really resolved");
                end else begin
                    if (expected_kind[word_idx] != BR_NONE) begin
                        assert (dut.predictor_update.pc == commit_pc &&
                                dut.predictor_update.kind == expected_kind[word_idx] &&
                                dut.predictor_update.taken == expected_taken[word_idx] &&
                                dut.predictor_update.target == expected_target[word_idx] &&
                                dut.predictor_update.train == token_train[slot])
                            else $fatal(1, "retired branch result/index mismatch pc=%h", commit_pc);
                        trains++;
                        b = (expected_pc >> 2) & (BTB_ENTRIES-1);
                        table_valid[b] = 1; table_tag[b] = commit_pc;
                        table_target[b] = expected_target[word_idx]; table_kind[b] = expected_kind[word_idx];
                        if (expected_kind[word_idx] != BR_JAL && expected_kind[word_idx] != BR_JALR) begin
                            if (token_stale[slot]) stale_trains++;
                            p = int'(token_train[slot].pht_idx);
                            if (expected_taken[word_idx] && patterns[p] < 3) patterns[p]++;
                            else if (!expected_taken[word_idx] && patterns[p] > 0) patterns[p]--;
                            if (PREDICTOR_MODE == 1) begin
                                // PHT/chooser 都使用被接受请求的旧快照，LHT 则在当前历史上追加。
                                l = int'(token_train[slot].local_idx);
                                c = int'(token_train[slot].chooser_idx);
                                if (scenario == 7 && commit_pc == 16) begin
                                    // B 的已接受取指先于旧 DIV 退休；A 后来训练共享 PHT[0]。
                                    // 当前候选已翻到 taken，但 B 的完整 ID 必须仍携带原来的弱 NT。
                                    assert (candidate_bound && dut.head_id == candidate_id &&
                                            candidate_fetch_cycle < old_div_retire_cycle &&
                                            l == 0 && !token_train[slot].local_taken &&
                                            local_patterns[0] >= 2 &&
                                            !dut.predictor_update.train.local_taken)
                                        else $fatal(1, "retired candidate was not stale or lost its accepted full-ID snapshot");
                                    candidate_trained++;
                                end
                                if (token_train[slot].local_taken != (local_patterns[l] >= 2))
                                    candidate_stale++;
                                if (expected_taken[word_idx] && local_patterns[l] < 3) local_patterns[l]++;
                                else if (!expected_taken[word_idx] && local_patterns[l] > 0) local_patterns[l]--;
                                b = (int'(commit_pc >> 2)) & (LOCAL_ENTRIES-1);
                                local_histories[b] = ((local_histories[b] << 1) |
                                    int'(expected_taken[word_idx])) & ((1 << LOCAL_HISTORY_W)-1);
                                local_trains++;
                                if (token_train[slot].local_taken != token_train[slot].global_taken) begin
                                    if (token_train[slot].local_taken == expected_taken[word_idx]) begin
                                        if (choices[c] < 3) choices[c]++;
                                    end else if (choices[c] > 0) choices[c]--;
                                    chooser_trains++;
                                end
                            end
                            history = ((history << 1) | int'(expected_taken[word_idx])) & ((1 << GHR_W)-1);
                            history_updates++;
                        end
                    end
                    done = expected_pc == finish_pc;
                    if (commit_inst == enc_mret()) begin
                        mrets++; expected_pc = irq_resume;
                    end else if (expected_kind[word_idx] != BR_NONE && expected_taken[word_idx])
                        expected_pc = int'(expected_target[word_idx]);
                    else expected_pc += 4;
                    if (commit_inst == 32'h0000000f) fences++;
                    if (fence_i_commit) begin
                        fence_is++; history = 0;
                        foreach (table_valid[i]) table_valid[i] = 0;
                        foreach (patterns[i]) patterns[i] = 1;
                        foreach (local_histories[i]) local_histories[i] = 0;
                        foreach (local_patterns[i]) local_patterns[i] = 1;
                        foreach (choices[i]) choices[i] = 1;
                    end
                end
            end
            if (dut.interrupt_take) begin
                assert (!commit_valid && scenario == 6 && interrupts == 0 && dut.interrupt_pc == xlen_t'(expected_pc))
                    else $fatal(1, "IRQ did not use precise retired successor");
                irq_resume = expected_pc; expected_pc = 128; interrupts++;
            end
            if (dut.wb_redirect.valid) foreach (token_valid[i]) token_valid[i] = 0;
            if (dut.dispatch_valid && dut.dispatch_ready) begin
                slot = int'(dut.alloc_id.slot);
                assert (!token_valid[slot] && dut.alloc_meta.pc == dut.d1_d2_q.pc &&
                        (dut.alloc_meta.kind != RET_BRANCH ||
                         dut.alloc_meta.pred_train == d2_model.train))
                    else $fatal(1, "allocation duplicated slot or changed prediction snapshot");
                token_valid[slot] = 1; token_id[slot] = dut.alloc_id;
                token_pc[slot] = d2_model.pc; token_train[slot] = d2_model.train;
                if (scenario == 7 && d2_model.pc == 16) begin
                    assert (!candidate_bound && d2_model.epoch == 0 &&
                            (!old_div_retired || d2_model.accepted_cycle < old_div_retire_cycle) &&
                            (PREDICTOR_MODE == 0 ||
                             (d2_model.train.local_idx == 0 && !d2_model.train.local_taken)))
                        else $fatal(1, "candidate B did not preserve its pre-training accepted fetch");
                    candidate_bound = 1; candidate_id = dut.alloc_id;
                    candidate_fetch_cycle = d2_model.accepted_cycle;
                end
                token_stale[slot] = expected_kind[int'(d2_model.pc >> 2)] inside
                    {BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU} && query_epoch != d2_model.epoch &&
                    d2_model.train.pht_idx != PHT_IDX_W'((int'(d2_model.pc >> 2) ^ query_history) & (PHT_ENTRIES-1));
                if (token_stale[slot])
                    stale_snapshot++;
                if (scenario inside {2, 3} && dut.alloc_meta.pc == 16) begin
                    assert (!young_allocated) else $fatal(1, "young branch allocated twice");
                    young_allocated = 1; young_id = dut.alloc_id;
                end
            end
            d1_model = next_d1; d2_model = next_d2;
            if (kill_fetch) begin
                buffer_model.valid = 0;
                if (request_model.valid && !response_fire) request_model.killed = 1;
                else request_model.valid = 0;
            end else begin
                if (buffer_model.valid && dut.fetch_ready) buffer_model = response_model;
                else if (!buffer_model.valid && !dut.fetch_ready && usable_response) buffer_model = response_model;
                if (response_fire) request_model.valid = 0;
                if (imem_req_valid && imem_req_ready) begin
                    assert (!request_model.valid) else $fatal(1, "more than one fetch response owner");
                    request_model = '{valid:1'b1, killed:1'b0, serial:next_fetch,
                                      epoch:query_epoch, accepted_cycle:observation_cycle,
                                      pc:imem_req_addr, train:query_train};
                    next_fetch++;
                end
            end
        end
    end

    task automatic put(input int pc, input logic [31:0] inst);
        u_imem.mem[pc/4] = inst;
    endtask
    task automatic branch(input int pc, input logic [31:0] inst,
                          input branch_op_e kind, input bit taken, input int target);
        put(pc, inst); expected_kind[pc/4] = kind;
        expected_taken[pc/4] = taken; expected_target[pc/4] = xlen_t'(target);
    endtask

    initial begin
        for (scenario = 0; scenario < 8; scenario++) begin
            @(negedge clk); rst = 1; irq_timer = 0; irq_started = 0;
            for (int i = 0; i < 128; i++) begin
                u_imem.mem[i] = nop(); expected_kind[i] = BR_NONE;
                expected_taken[i] = 0; expected_target[i] = 0; expected_fault[i] = 0;
            end
            finish_pc = 52;
            unique case (scenario)
                0: begin
                    put(0, enc_addi(1, 0, 1));
                    branch(4, enc_beq(1, 0, 16), BR_EQ, 0, 20);
                    branch(8, enc_beq(1, 1, 4), BR_EQ, 1, 12);
                    branch(12, enc_beq(1, 1, 4), BR_EQ, 1, 16);
                    put(16, enc_addi(3, 0, 40));
                    branch(20, enc_jalr(4, 3, 0), BR_JALR, 1, 40);
                    branch(24, enc_jal(1, 4), BR_JAL, 1, 28);
                    branch(40, enc_bne(1, 1, 8), BR_NE, 0, 48);
                    branch(44, enc_jal(0, 8), BR_JAL, 1, 52);
                end
                1: begin
                    put(0, enc_addi(1, 0, 1)); put(4, enc_addi(11, 0, 256)); put(8, enc_lw(5, 11, 0));
                    branch(12, enc_beq(1, 1, 8), BR_EQ, 1, 20);
                    finish_pc = 20;
                end
                2, 3, 4: begin
                    put(0, enc_addi(10, 0, 128)); put(4, enc_csrrw(0, CSR_MTVEC, 10));
                    put(8, enc_addi(11, 0, scenario == 4 ? 3 : 256));
                    if (scenario == 4) begin
                        branch(12, enc_jalr(1, 11, 0), BR_JALR, 1, 2);
                    end else begin
                        put(12, enc_lw(5, 11, 0));
                        if (scenario == 2) branch(16, enc_jal(1, 16), BR_JAL, 1, 32);
                        else branch(16, enc_beq(0, 0, 16), BR_EQ, 1, 32);
                    end
                    expected_fault[3] = 1; finish_pc = 128;
                end
                5: begin
                    branch(0, enc_jal(1, 4), BR_JAL, 1, 4);
                    put(4, 32'h0000000f);
                    branch(8, enc_beq(0, 0, 4), BR_EQ, 1, 12);
                    put(12, 32'h0000100f);
                    branch(16, enc_jal(1, 4), BR_JAL, 1, 20);
                    finish_pc = 20;
                end
                6: begin
                    put(0, enc_addi(10, 0, 128)); put(4, enc_csrrw(0, CSR_MTVEC, 10));
                    put(8, enc_addi(1, 0, 8)); put(12, enc_csrrs(0, CSR_MSTATUS, 1));
                    put(16, enc_addi(2, 0, 128)); put(20, enc_csrrw(0, CSR_MIE, 2));
                    branch(24, enc_jal(1, 4), BR_JAL, 1, 28);
                    branch(28, enc_jal(2, 4), BR_JAL, 1, 32);
                    branch(40, enc_beq(0, 0, 4), BR_EQ, 1, 44);
                    put(128, enc_addi(30, 0, 1)); put(132, enc_mret());
                    finish_pc = 80;
                end
                7: begin
                    // 不同 PC 共用 Local PHT[0]：旧 DIV 阻退休但不阻分支解析。
                    // 两槽时 B 可先停在无 ID 前端，四/八槽可先分配；均跟踪真实接受快照。
                    put(0, enc_addi(1, 0, -1)); put(4, enc_addi(2, 0, 3));
                    put(8, enc_divu(3, 1, 2));
                    branch(12, enc_beq(0, 0, 4), BR_EQ, 1, 16);
                    branch(16, enc_beq(0, 0, 4), BR_EQ, 1, 20);
                    finish_pc = 20;
                end
                default: ;
            endcase
            put(finish_pc, enc_addi(31, 0, 1));
            repeat (4) @(posedge clk);
            @(negedge clk); rst = 0;
            for (int cycle = 0; cycle < 1200 && !done; cycle++) begin
                @(negedge clk);
                if (scenario == 6 && trains > 0 && !irq_started) begin
                    irq_timer = 1; irq_started = 1;
                end
                if (interrupts != 0) irq_timer = 0;
            end
            assert (done) else $fatal(1, "predictor retirement timeout scenario=%0d", scenario);
            if (scenario == 0) assert (trains == 6 && traps == 0) else $fatal(1, "branch result coverage");
            if (scenario == 1) assert (trains == 1 && requests == 1 && early_ex == 1)
                else $fatal(1, "early branch training repeated or no old-LSU overlap");
            if (scenario inside {2, 3, 4}) assert (trains == 0 && traps == 1)
                else $fatal(1, "cancelled/faulting branch trained");
            if (scenario == 2) assert (early_jal == 1) else $fatal(1, "fault test did not resolve young D1 JAL");
            if (scenario == 3) assert (early_ex == 1)
                else $fatal(1, "fault test did not resolve young EX branch before old response");
            if (scenario == 5) assert (trains == 3 && fences == 1 && fence_is == 1)
                else $fatal(1, "FENCE/FENCE.I retirement coverage");
            if (scenario == 6) assert (trains == 3 && interrupts == 1 && mrets == 1)
                else $fatal(1, "IRQ/MRET training coverage");
            if (scenario == 7) begin
                assert (trains == 2 && early_conditional == 1 && candidate_bound && old_div_retired &&
                        candidate_fetch_cycle < old_div_retire_cycle &&
                        (PREDICTOR_MODE == 0 || (candidate_trained == 1 && candidate_stale > 0)))
                    else $fatal(1, "real stale candidate training coverage missing");
                $display("COVER stale-candidate mode=%0d id=%h fetch=%0d old_div_retire=%0d early_branch=%0d trained=%0d changed=%0d",
                    PREDICTOR_MODE, candidate_id, candidate_fetch_cycle, old_div_retire_cycle,
                    early_conditional, candidate_trained, candidate_stale);
            end
            $display("COVER predictor-retire scenario=%0d trains=%0d held=%0d early_d1=%0d early_ex=%0d redirect_train=%0d queries=%0d",
                     scenario, trains, held_branch, early_jal, early_ex, redirect_trains, query_checks);
            total_trains += trains; total_queries += query_checks; total_redirect_trains += redirect_trains;
            total_stale_snapshot += stale_snapshot;
            total_stale_trains += stale_trains;
            total_local_trains += local_trains;
            total_chooser_trains += chooser_trains;
            total_candidate_stale += candidate_stale;
        end
        assert (total_redirect_trains > 0)
            else $fatal(1, "no normal retirement training coincided with younger frontend redirect");
        assert (total_stale_snapshot > 0 && total_stale_trains > 0)
            else $fatal(1, "no conditional branch trained its saved query index after history changed before allocation");
        assert ((PREDICTOR_MODE == 1 && total_local_trains > 0 && total_chooser_trains > 0 && total_candidate_stale > 0) ||
                (PREDICTOR_MODE == 0 && total_local_trains == 0 && total_chooser_trains == 0))
            else $fatal(1, "local model mode qualification missing");
        $display("PASS tb_core_predictor_retire RV%0d entries=%0d mode=%0d scenarios=8 trains=%0d queries=%0d stale_snapshots=%0d stale_pht_trains=%0d local_trains=%0d chooser_trains=%0d stale_candidates=%0d",
                 XLEN, RETIRE_ENTRIES, PREDICTOR_MODE, total_trains, total_queries, total_stale_snapshot,
                 total_stale_trains, total_local_trains, total_chooser_trains, total_candidate_stale);
        $finish;
    end
endmodule
