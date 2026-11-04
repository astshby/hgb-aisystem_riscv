// Module: tb_core_ras
// Description: Models speculative/retired return stacks and full-ID replay against real Core events.
module tb_core_ras;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import predictor_types_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write, dmem_rsp_valid, dmem_rsp_ready;
    logic dmem_rsp_error, commit_valid, commit_rd_we, commit_exception, fence_i_commit;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata, commit_pc, commit_rd_data;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic irq_timer = 0, bus_pending;
    logic [31:0] code [128];
    int cycle, bus_delay, scenario, finish_pc;
    int checks, returns, blocked, recoveries, pairs, early_div, traps, irq_takes, mrets, clears;
    int total_returns = 0, total_blocked = 0, total_pairs = 0, total_early_div = 0;
    int total_traps = 0, total_irqs = 0, total_mrets = 0, total_clears = 0;
    int completed_replays, total_completed_replays = 0;
    int launches, completions, m_retired, young_calls, young_trains, irq_phase, irq_cycle;
    bit done;
    typedef struct packed {
        retire_id_t id;
        xlen_t pc;
        ras_event_t event_info;
        bit exception, complete;
    } age_t;
    age_t age[$];
    xlen_t committed[$], speculative[$];
    bit btb_valid [BTB_ENTRIES];
    xlen_t btb_pc [BTB_ENTRIES];
    ras_op_e btb_op [BTB_ENTRIES];
    always #5 clk = ~clk;
    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .irq_software(1'b0), .irq_external(1'b0), .imem_rsp_error(1'b0), .*);

    // 指令口和数据口均使用 NBA 更新所有权；周期性反压不能重复应用预测 hint。
    assign imem_req_ready = (!imem_rsp_valid || imem_rsp_ready) &&
                            (scenario == 1 || cycle % 5 != 2);
    assign dmem_req_ready = !bus_pending && !dmem_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle <= 0; imem_rsp_valid <= 0; imem_rsp_data <= 0;
            bus_pending <= 0; bus_delay <= 0; dmem_rsp_valid <= 0;
            dmem_rsp_error <= 0; dmem_rsp_rdata <= 0;
        end else begin
            cycle <= cycle + 1;
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1;
                imem_rsp_data <= code[int'(imem_req_addr >> 2) & 127];
            end
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
            if (bus_pending) begin
                if (bus_delay == 0) begin
                    bus_pending <= 0; dmem_rsp_valid <= 1; dmem_rsp_error <= 1;
                end else bus_delay <= bus_delay - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (scenario == 2 && !dmem_req_write && dmem_req_addr == 256)
                    else $fatal(1, "wrong-path RAS program made a data-side effect");
                bus_pending <= 1; bus_delay <= 24;
            end
        end
    end

    // 参考 hint 由软件指令编码独立求得，不调用 DUT decoder 或读取 meta.ras_op 建答案。
    function automatic ras_op_e hint(input logic [31:0] inst);
        bit rd_link, rs1_link;
        rd_link = inst[11:7] inside {5'd1, 5'd5};
        rs1_link = inst[19:15] inside {5'd1, 5'd5};
        if (inst[6:0] == 7'h6f && rd_link) return RAS_PUSH;
        if (inst[6:0] != 7'h67 || inst[14:12] != 0) return RAS_NONE;
        if (rd_link && rs1_link && inst[11:7] != inst[19:15]) return RAS_POP_PUSH;
        if (rd_link) return RAS_PUSH;
        return rs1_link ? RAS_POP : RAS_NONE;
    endfunction
    task automatic apply_event(ref xlen_t stack[$], input ras_event_t event_info);
        xlen_t discarded;
        if (event_info.op inside {RAS_POP, RAS_POP_PUSH})
            if (stack.size() != 0) discarded = stack.pop_back();
        if (event_info.op inside {RAS_PUSH, RAS_POP_PUSH}) begin
            stack.push_back(event_info.addr);
            if (stack.size() > RAS_DEPTH) discarded = stack.pop_front();
        end
    endtask

    // 参考年龄来自实际分配/完成/退休握手；重放由软件列表生成，不读取 queue 的 RAS view。
    always @(posedge clk) begin
        if (rst) begin
            age.delete(); committed.delete(); speculative.delete();
            foreach (btb_valid[i]) btb_valid[i] = 0;
            checks = 0; returns = 0; blocked = 0; recoveries = 0; pairs = 0; early_div = 0;
            traps = 0; irq_takes = 0; mrets = 0; clears = 0; done = 0;
            launches = 0; completions = 0; m_retired = 0; young_calls = 0; young_trains = 0;
            completed_replays = 0;
        end else if (RAS_ENABLE) begin
            int index;
            ras_op_e query_op, actual_op;
            ras_event_t event_info;
            age_t discarded;
            bit recover;
            assert (dut.ras_top_valid == (speculative.size() != 0))
                else $fatal(1, "RAS top validity scenario=%0d cycle=%0d", scenario, cycle);
            if (speculative.size() != 0)
                assert (dut.ras_top_addr == speculative[speculative.size()-1])
                    else $fatal(1, "RAS top data scenario=%0d cycle=%0d actual=%h expected=%h", scenario,
                        cycle, dut.ras_top_addr, speculative[speculative.size()-1]);
            checks++;
            index = int'(imem_req_addr >> 2) & (BTB_ENTRIES-1);
            query_op = btb_valid[index] && btb_pc[index] == imem_req_addr ? btb_op[index] : RAS_NONE;
            assert (dut.prediction.ras_op == query_op) else $fatal(1, "BTB RAS hint ownership");
            if (query_op inside {RAS_POP, RAS_POP_PUSH} && speculative.size() != 0) begin
                assert (dut.prediction.target == speculative[speculative.size()-1])
                    else $fatal(1, "return did not select registered RAS target");
                if (imem_req_valid && imem_req_ready) returns++;
            end
            if (imem_req_valid && !imem_req_ready && query_op != RAS_NONE) blocked++;
            if (dut.complete_valid && dut.complete_ready && !dut.complete_reject)
                for (int i = 0; i < age.size(); i++)
                    if (age[i].id == dut.completion.id) begin
                        age[i].exception = dut.completion.result.exc.valid;
                        age[i].complete = 1;
                    end
            if (dut.mdu_req_valid && dut.mdu_req_ready) launches++;
            if (dut.mdu_complete_valid && dut.mdu_complete_ready) completions++;
            if (scenario == 1 && dut.dispatch_valid && dut.dispatch_ready && dut.alloc_meta.pc == 8 &&
                dut.d1_packet.valid && dut.d1_packet.pc == 12) begin
                assert (dut.selected_redirect.reason == REDIR_D1_JAL &&
                        dut.pipeline_actions.d1_d2 == PIPE_ADVANCE)
                    else $fatal(1, "cold D1 call did not survive same-edge older D2 M allocation");
                pairs++;
            end
            if (scenario == 1 && dut.selected_redirect.valid && dut.selected_redirect.reason == REDIR_EX_BRANCH &&
                launches > m_retired) begin
                assert (!dut.execution_cancel) else $fatal(1, "young branch cancelled old DIV");
                early_div++;
            end
            if (scenario == 2 && dut.pipeline_actions.d1_d2 == PIPE_ADVANCE &&
                dut.d1_packet.valid && dut.d1_packet.pc == 12) young_calls++;
            if (scenario == 2 && dut.predictor_update.valid && dut.predictor_update.pc == 12) young_trains++;

            // 正常退休先作用于 committed；同沿恢复时这一项不得再从队列重复重放。
            if (commit_valid) begin
                assert (age.size() != 0 && age[0].id == dut.head_id && age[0].pc == commit_pc &&
                        commit_inst == code[int'(commit_pc >> 2) & 127])
                    else $fatal(1, "RAS program lost full-ID retirement order");
                if (commit_exception) traps++;
                else begin
                    actual_op = hint(commit_inst);
                    apply_event(committed, '{op:actual_op, addr:commit_pc+xlen_t'(4)});
                    if (dut.head_meta.kind == RET_BRANCH) begin
                        index = int'(commit_pc >> 2) & (BTB_ENTRIES-1);
                        btb_valid[index] = 1; btb_pc[index] = commit_pc; btb_op[index] = actual_op;
                    end
                    if (dut.head_meta.kind == RET_MDU) m_retired++;
                    if (commit_inst == enc_mret()) mrets++;
                    if (commit_pc == xlen_t'(finish_pc)) done = 1;
                    if (scenario == 0 && commit_pc == 24)
                        assert (commit_rd_data == 8) else $fatal(1, "nested-call software result");
                end
                discarded = age.pop_front();
            end
            if (dut.interrupt_take) irq_takes++;
            if (dut.wb_redirect.valid) age.delete();
            else if (dut.dispatch_valid && dut.dispatch_ready) begin
                actual_op = dut.d1_d2_q.exc.valid ? RAS_NONE : hint(code[int'(dut.alloc_meta.pc >> 2) & 127]);
                assert (dut.alloc_meta.ras_op == actual_op) else $fatal(1, "D2 hint/exception qualification");
                age.push_back('{id:dut.alloc_id, pc:dut.alloc_meta.pc,
                    event_info:'{op:actual_op, addr:dut.alloc_meta.pc+xlen_t'(4)}, exception:1'b0, complete:1'b0});
            end
            recover = dut.selected_redirect.valid || dut.frontend_flush;
            if (fence_i_commit) begin
                committed.delete(); speculative.delete(); clears++;
                foreach (btb_valid[i]) btb_valid[i] = 0;
            end else if (recover) begin
                recoveries++;
                speculative = committed;
                for (int i = 0; i < age.size(); i++) begin
                    if (!age[i].exception && !(dut.ex_serialize_req && dut.ex_packet.exc.valid &&
                        age[i].id == dut.d2_ex_q.retire_id)) begin
                        apply_event(speculative, age[i].event_info);
                        if (age[i].complete && age[i].event_info.op != RAS_NONE) completed_replays++;
                    end
                end
                if (!dut.wb_redirect.valid && dut.pipeline_actions.d1_d2 == PIPE_ADVANCE &&
                    dut.d1_packet.valid && !dut.d1_packet.exc.valid)
                    apply_event(speculative, '{op:hint(dut.d1_packet.inst), addr:dut.d1_packet.seq_pc});
            end else if (imem_req_valid && imem_req_ready)
                apply_event(speculative, '{op:query_op, addr:imem_req_addr+xlen_t'(4)});
        end
    end

    task automatic put(input int pc, input logic [31:0] inst);
        code[pc/4] = inst;
    endtask
    initial begin
        if (!RAS_ENABLE) begin
            $display("SKIP tb_core_ras RAS disabled"); $finish;
        end else begin
            for (scenario = 0; scenario < 6; scenario++) begin
                @(negedge clk); rst = 1; irq_timer = 0; irq_phase = 0; irq_cycle = 0;
                foreach (code[i]) code[i] = nop();
                finish_pc = 28;
                unique case (scenario)
                    0: begin
                        put(0, enc_addi(10, 0, 0)); put(4, enc_addi(2, 0, 4));
                        put(8, enc_jal(1, 56)); put(12, enc_jal(1, 52));
                        put(16, enc_addi(2, 2, -1)); put(20, enc_bne(2, 0, -12));
                        put(24, enc_addi(11, 10, 0));
                        put(64, enc_jal(5, 32)); put(68, enc_jalr(0, 1, 0));
                        put(96, enc_addi(10, 10, 1)); put(100, enc_jalr(0, 5, 0));
                    end
                    1: begin
                        put(0, enc_addi(2, 0, 3)); put(4, enc_addi(14, 0, -1));
                        put(8, enc_divu(3, 14, 2)); put(12, enc_jal(1, 52));
                        put(16, enc_sw(0, 0, 0)); finish_pc = 20;
                        put(64, enc_addi(5, 0, 7)); put(68, enc_jalr(0, 1, 4));
                    end
                    2: begin
                        put(0, enc_addi(10, 0, 128)); put(4, enc_csrrw(0, CSR_MTVEC, 10));
                        put(8, enc_lw(3, 0, 256)); put(12, enc_jal(1, 52)); finish_pc = 128;
                    end
                    3, 4: begin
                        put(0, enc_addi(10, 0, 128)); put(4, enc_csrrw(0, CSR_MTVEC, 10));
                        put(8, enc_jal(1, 24)); put(32, enc_addi(2, 0, 3));
                        put(36, scenario == 3 ? enc_jalr(5, 2, 0) : enc_jal(5, 2));
                        put(128, enc_addi(10, 0, 64)); put(132, enc_csrrw(0, CSR_MEPC, 10));
                        put(136, enc_mret());
                        if (scenario == 3) begin put(64, 32'h0000100f); finish_pc = 68; end
                        else finish_pc = 64;
                    end
                    5: begin
                        put(0, enc_addi(10, 0, 128)); put(4, enc_csrrw(0, CSR_MTVEC, 10));
                        put(8, enc_addi(2, 0, 128)); put(12, enc_csrrw(0, CSR_MIE, 2));
                        put(16, enc_addi(2, 0, 8)); put(20, enc_csrrs(0, CSR_MSTATUS, 2));
                        put(24, enc_jal(1, 40)); put(100, enc_jalr(0, 1, 0));
                        put(128, enc_mret()); finish_pc = 28;
                    end
                    default: ;
                endcase
                put(finish_pc, enc_addi(31, 0, 1));
                repeat (4) @(posedge clk);
                @(negedge clk); rst = 0;
                for (int timeout = 0; timeout < 2000 && !done; timeout++) begin
                    @(negedge clk);
                    if (scenario == 5) begin
                        if (irq_phase == 0 && committed.size() == 1) begin
                            irq_timer = 1; irq_phase = 1; irq_cycle = cycle;
                        end else if (irq_phase == 1) begin
                            irq_timer = 0; irq_phase = 2;
                        end else if (irq_phase == 2 && cycle >= irq_cycle + 5) begin
                            assert (irq_takes == 0) else $fatal(1, "withdrawn IRQ entered trap");
                            irq_timer = 1; irq_phase = 3;
                        end else if (irq_phase == 3 && irq_takes != 0) begin
                            irq_timer = 0; irq_phase = 4;
                        end
                    end
                end
                assert (done) else $fatal(1, "RAS core scenario timeout %0d", scenario);
                if (scenario == 0) assert (returns >= 4 && blocked > 0)
                    else $fatal(1, "missing real RAS return/backpressure coverage");
                // 两槽只能同时容纳旧DIV和call，返回指令无法在旧DIV退休前取得第三个ID。
                if (scenario == 1) assert (pairs == 1 && (RETIRE_ENTRIES == 2 || early_div > 0) &&
                    launches == 1 && completions == 1 && m_retired == 1)
                    else $fatal(1, "old DIV/D1/EX overlap pairs=%0d early=%0d m=%0d/%0d/%0d", pairs, early_div, launches, completions, m_retired);
                if (scenario == 2) assert (young_calls == 1 && young_trains == 0 && traps == 1 && committed.size() == 0)
                    else $fatal(1, "old fault did not cancel resolved young call");
                if (scenario inside {3,4}) assert (traps == 1 && mrets == 1 && committed.size() == (scenario == 3 ? 0 : 1))
                    else $fatal(1, "fault/MRET/FENCE.I lost committed RAS boundary");
                if (scenario == 5) assert (irq_takes == 1 && mrets == 1 && irq_phase == 4)
                    else $fatal(1, "IRQ pulse/entry/return coverage");
                $display("COVER core-ras scenario=%0d checks=%0d returns=%0d blocked=%0d recover=%0d pairs=%0d early_div=%0d trap=%0d irq=%0d mret=%0d clear=%0d",
                    scenario, checks, returns, blocked, recoveries, pairs, early_div, traps, irq_takes, mrets, clears);
                total_returns += returns; total_blocked += blocked; total_pairs += pairs; total_early_div += early_div;
                total_traps += traps; total_irqs += irq_takes; total_mrets += mrets; total_clears += clears;
                total_completed_replays += completed_replays;
            end
            if (RETIRE_ENTRIES >= 4) assert (total_completed_replays > 0)
                else $fatal(1, "no completed-unretired call survived a real recovery");
            $display("PASS tb_core_ras RV%0d entries=%0d scenarios=6 returns=%0d blocked=%0d pair=%0d early_div=%0d traps=%0d irqs=%0d mrets=%0d clears=%0d completed_replay=%0d",
                XLEN, RETIRE_ENTRIES, total_returns, total_blocked, total_pairs, total_early_div, total_traps, total_irqs, total_mrets, total_clears, total_completed_replays);
            $finish;
        end
    end
endmodule
