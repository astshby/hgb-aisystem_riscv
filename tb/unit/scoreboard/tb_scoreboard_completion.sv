// Module: tb_scoreboard_completion
// Description: Verifies collision arbitration and lossless dual-retire predictor training.
module tb_scoreboard_completion #(
    parameter int unsigned SOURCES = 5
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    logic clk = 0, rst = 1;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic [SOURCES-1:0] source_valid, source_accept, source_ready;
    retire_completion_t source_completion [SOURCES], completion [2];
    logic [1:0] complete_valid, complete_accept, capacity;
    pred_update_t incoming [2], update;
    xlen_t expected[$], discarded;
    int serial, checked, full_cycles, pair_pushes, arbitration_checks;
    int accepted_sources = 0, rejected_sources = 0;
    int unsigned random_state = 32'hc01234ab;
    always #5 clk = ~clk;
    completion_select #(.SOURCES(SOURCES)) u_select (.*);
    predictor_update_queue u_training (.*);
    // 预检拒绝仍须排空真实来源；source_accept 不参与年龄仲裁，只决定选中项是否广播。
    // 独立逐项参考算法覆盖年龄回卷、空洞、同龄来源和全部 valid 组合。
    task automatic check_arbitration;
        logic [SOURCES-1:0] remaining, expected_ready;
        int selected, age, best_age;
        remaining = source_valid;
        expected_ready = '0;
        for (int portno = 0; portno < 2; portno++) begin
            selected = -1; best_age = RETIRE_ENTRIES;
            for (int src = 0; src < SOURCES; src++) begin
                age = (int'(source_completion[src].id.slot) + RETIRE_ENTRIES - int'(head_slot)) % RETIRE_ENTRIES;
                if (remaining[src] && age < best_age) begin
                    selected = src; best_age = age;
                end
            end
            assert (complete_valid[portno] == (selected >= 0)) else $fatal(1, "completion rank valid");
            if (selected >= 0) begin
                assert (complete_accept[portno] == source_accept[selected])
                    else $fatal(1, "completion accept not paired with selected ID");
                if (source_accept[selected]) accepted_sources++;
                else rejected_sources++;
                assert (completion[portno] == source_completion[selected]) else $fatal(1, "completion rank/data");
                expected_ready[selected] = 1; remaining[selected] = 0;
            end else assert (!complete_accept[portno]) else $fatal(1, "empty completion accepted");
        end
        assert (source_ready == expected_ready) else $fatal(1, "completion source ownership");
        arbitration_checks++;
    endtask
    initial begin
        head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES - 4); source_valid = 0; source_accept = '1;
        for (int src = 0; src < SOURCES; src++) begin
            source_completion[src] = '0;
            source_completion[src].id.slot = RETIRE_IDX_W'(RETIRE_ENTRIES - 4 + (4-src));
            source_completion[src].result.gpr_data = xlen_t'(src + 100);
        end
        incoming[0] = '0; incoming[1] = '0; serial = 1; checked = 0; full_cycles = 0; pair_pushes = 0;
        arbitration_checks = 0;
        repeat (2) @(negedge clk); rst = 0; source_valid = SOURCES'(31); #1;
        assert (source_ready == SOURCES'(24) && complete_valid == 3 &&
                completion[0].result.gpr_data == 104 && completion[1].result.gpr_data == 103)
            else $fatal(1, "old completion starved across ROB wrap");
        @(negedge clk); source_valid &= ~source_ready; #1;
        assert (source_ready == SOURCES'(6) && completion[0].result.gpr_data == 102 &&
                completion[1].result.gpr_data == 101) else $fatal(1, "held result replaced");
        @(negedge clk); source_valid &= ~source_ready; #1;
        assert (source_ready == 1 && complete_valid == 1 && completion[0].result.gpr_data == 100)
            else $fatal(1, "final completion lost");
        for (int head = 0; head < RETIRE_ENTRIES; head++)
            for (int mask = 0; mask < (1 << SOURCES); mask++)
                for (int sample_no = 0; sample_no < (SOURCES == 5 ? 16 : 4); sample_no++) begin
                    @(negedge clk); head_slot = RETIRE_IDX_W'(head); source_valid = SOURCES'(mask);
                    for (int src = 0; src < SOURCES; src++) begin
                        random_state = random_state * 32'd1664525 + 32'd1013904223;
                        source_completion[src].id.slot = RETIRE_IDX_W'(random_state >> 16);
                        source_completion[src].result.gpr_data = xlen_t'(random_state);
                        source_accept[src] = random_state[23];
                    end
                    #1; check_arbitration();
                end
        @(negedge clk); source_valid = 0;
        // 80 拍注入结束后按实际训练队列深度排空，ROB32 不能沿用固定 20 拍窗口。
        for (int cycle = 0; cycle < 80 + RETIRE_ENTRIES + 2; cycle++) begin
            incoming[0] = '0; incoming[1] = '0;
            if (cycle < 80) begin
                incoming[0].valid = 1; incoming[0].pc = xlen_t'(serial * 4); serial++;
                if (capacity == 2) begin
                    incoming[1].valid = 1; incoming[1].pc = xlen_t'(serial * 4); serial++;
                    pair_pushes++;
                end else full_cycles++;
            end
            @(posedge clk);
            if (expected.size() != 0) begin
                assert (update.valid && update.pc == expected[0]) else $fatal(1, "training order/data loss");
                discarded = expected.pop_front(); checked++;
            end else assert (!update.valid) else $fatal(1, "duplicate training event");
            for (int lane = 0; lane < 2; lane++)
                if (incoming[lane].valid) expected.push_back(incoming[lane].pc);
            @(negedge clk);
        end
        assert (expected.size() == 0 && checked == serial - 1 && pair_pushes > 0 && full_cycles > 0 &&
                accepted_sources > 0 && rejected_sources > 0)
            else $fatal(1, "training coverage/drain remaining=%0d checked=%0d offered=%0d pair=%0d full=%0d",
                        expected.size(), checked, serial-1, pair_pushes, full_cycles);
        $display("PASS tb_scoreboard_completion XLEN=%0d collision_sources=%0d arbitration=%0d training=%0d full_cycles=%0d accepted=%0d rejected=%0d",
                 XLEN, SOURCES, arbitration_checks, checked, full_cycles, accepted_sources, rejected_sources);
        $finish;
    end
endmodule
