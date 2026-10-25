// Module: tb_scoreboard_issue
// Description: Checks registered dual issue, partial consumption, held operands and selective recovery.
module tb_scoreboard_issue;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    always #5 clk = !clk;
    branch_recovery_t recovery = '0;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic [1:0] push_count = 0, pop_count = 0, push_capacity, occupancy, present, mark_reported = 0;
    logic busy;
    d2_ex_t push_packet [2], issue_packet [2], raw_packet [2], expected[$], discarded;
    branch_result_t push_branch [2], issue_branch [2], expected_branch[$], discarded_branch;
    int checked = 0, consumed = 0, cancelled = 0, next_id = 0, reported_checks = 0;
    issue_queue dut (
        .clk, .rst, .flush, .recovery, .head_slot,
        .push_count, .push_packet, .push_branch, .mark_reported, .push_capacity,
        .pop_count, .issue_packet, .raw_packet, .issue_branch, .present, .occupancy, .busy
    );
    function automatic d2_ex_t packet(input int number);
        d2_ex_t value;
        value = '0;
        value.valid = 1;
        value.retire_id = '{slot:RETIRE_IDX_W'(number), generation:RETIRE_GEN_W'(number / RETIRE_ENTRIES)};
        value.pc = xlen_t'(number * 4);
        value.inst = 32'h13 ^ 32'(number << 8);
        value.rs1_data = xlen_t'(64'h1234567887654321 ^ 64'(number));
        value.rs2_data = xlen_t'(64'hfedcba9876543210 + 64'(number));
        value.rs1_dependency.id = value.retire_id;
        value.rs2_dependency.id = value.retire_id;
        return value;
    endfunction
    task automatic offer(input int count);
        push_count = 2'(count);
        for (int lane = 0; lane < count; lane++) begin
            push_packet[lane] = packet(next_id);
            push_branch[lane] = '{taken:next_id[0], target:xlen_t'(next_id * 8)};
            next_id++;
        end
    endtask
    task automatic cycle;
        #1;
        if (!rst) begin
            assert (occupancy == expected.size() && busy == (expected.size() != 0)) else $fatal;
            assert (push_capacity == ((flush || recovery.valid) ? 0 : 2 - expected.size() + int'(pop_count)))
                else $fatal(1, "ISS capacity");
            for (int lane = 0; lane < 2; lane++) begin
                assert (present[lane] == (lane < expected.size()))
                    else $fatal(1, "ISS raw presence follows cancellation");
                if (present[lane]) begin
                    assert (raw_packet[lane] == expected[lane])
                        else $fatal(1, "ISS raw packet lost report mark or payload");
                    if (raw_packet[lane].branch_reported) reported_checks++;
                end
                assert (issue_packet[lane].valid == (lane < expected.size() && !flush && !recovery.valid))
                    else $fatal(1, "ISS fell through or exposed cancelled instruction");
                if (issue_packet[lane].valid)
                    assert (issue_packet[lane] == expected[lane] && issue_branch[lane] == expected_branch[lane]) else $fatal(1, "ISS lost held operand/ID");
            end
        end
        if (rst || flush) begin expected.delete(); expected_branch.delete(); end
        else begin
            for (int lane = 0; lane < expected.size(); lane++) begin
                if (mark_reported[lane]) begin
                    discarded = expected[lane];
                    discarded.branch_reported = 1;
                    expected[lane] = discarded;
                end
            end
            repeat (int'(pop_count)) begin discarded = expected.pop_front(); discarded_branch = expected_branch.pop_front(); consumed++; end
            for (int index = expected.size()-1; index >= 0; index--) begin
                if (recovery.valid && younger_than(expected[index].retire_id, recovery.id, head_slot)) begin
                    expected.delete(index); expected_branch.delete(index); cancelled++;
                end
            end
            for (int lane = 0; lane < int'(push_count); lane++) begin expected.push_back(push_packet[lane]); expected_branch.push_back(push_branch[lane]); end
        end
        @(posedge clk); @(negedge clk); checked++;
        push_count = 0; pop_count = 0; recovery = '0; flush = 0; mark_reported = 0;
    endtask
    initial begin
        for (int lane = 0; lane < 2; lane++) begin push_packet[lane] = '0; push_branch[lane] = '0; end
        @(negedge clk); cycle(); rst = 0;
        // 标记必须跟随完整 ID：停顿保持、第二槽移到第一槽、新包不能继承旧标记。
        offer(2);
        push_packet[0].uop.branch_op = BR_EQ;
        push_packet[1].uop.branch_op = BR_JALR;
        cycle();
        mark_reported = 2'b10; cycle(); repeat (4) cycle();
        pop_count = 1; offer(1); cycle();
        assert (expected[0].branch_reported && !expected[1].branch_reported)
            else $fatal(1, "report mark crossed instruction identity");
        mark_reported = 2'b10; pop_count = 1; cycle();
        cycle();
        assert (expected[0].branch_reported) else $fatal(1, "marked second slot lost on compaction");
        flush = 1; cycle();
        // 恢复与上报同拍：保留边界项的标记，清除年轻项；raw 视图仍显示沿前包。
        offer(2); cycle(); head_slot = expected[0].retire_id.slot;
        mark_reported = 2'b11;
        recovery = '{valid:1, id:expected[0].retire_id, pc:'0}; cycle();
        cycle();
        assert (expected.size() == 1 && expected[0].branch_reported)
            else $fatal(1, "recovery lost surviving report mark");
        flush = 1; mark_reported = 2'b01; cycle();
        offer(2); cycle(); cycle();
        assert (!expected[0].branch_reported && !expected[1].branch_reported)
            else $fatal(1, "flush leaked report mark into new packet");
        flush = 1; cycle();
        offer(2); cycle(); repeat (8) cycle();
        // 只消费最老一项，再补一项；原第二项及其操作数必须保持。
        pop_count = 1; offer(1); cycle();
        // 满两项同拍双出双入，不能退化成隔拍双发射。
        repeat (100) begin pop_count = 2; offer(2); cycle(); end
        head_slot = expected[0].retire_id.slot;
        recovery = '{valid:1, id:expected[0].retire_id, pc:'0}; cycle();
        assert (expected.size() == 1) else $fatal;
        flush = 1; cycle();
        for (int step = 0; step < 400; step++) begin
            head_slot = RETIRE_IDX_W'(next_id - 8);
            if (step % 23 == 0 && expected.size() != 0) begin
                recovery = '{valid:1, id:expected[0].retire_id, pc:'0};
            end else if (step % 41 == 0) flush = 1;
            else begin
                pop_count = 2'(step % (expected.size() + 1));
                offer((step * 7 + 1) % (3 - expected.size() + int'(pop_count)));
            end
            mark_reported = 2'(step);
            cycle();
        end
        pop_count = 2'(expected.size()); cycle();
        assert (!busy && consumed > 200 && cancelled > 0 && reported_checks > 20) else $fatal;
        $display("PASS tb_scoreboard_issue RV%0d cycles=%0d consumed=%0d cancelled=%0d reported=%0d dual_streak=100",
                 XLEN, checked, consumed, cancelled, reported_checks);
        $finish;
    end
endmodule
