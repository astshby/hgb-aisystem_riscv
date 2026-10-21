// Module: tb_scoreboard_metrics
// Description: Verifies overlapping stall priorities, counter partitions, dual handshakes and reset.
module tb_scoreboard_metrics;
    timeunit 1ns;
    timeprecision 1ps;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1;
    logic [1:0] issue_fire, retire_fire, memory_request_fire, memory_response_fire, forward_fire;
    logic redirect, iq_empty, head_operands_ready, head_unit_ready;
    logic dispatch_pending, rob_full, iq_full, checkpoint_blocked;
    schedule_class_e head_class;
    int unsigned completion_sources;
    always #5 clk = ~clk;
    scoreboard_metrics dut (.*);
    task automatic defaults;
        issue_fire = 0; retire_fire = 0;
        memory_request_fire = 0; memory_response_fire = 0; forward_fire = 0;
        redirect = 0; iq_empty = 0; head_operands_ready = 1; head_unit_ready = 0;
        dispatch_pending = 0; rob_full = 0; iq_full = 0; checkpoint_blocked = 0;
        head_class = SCHED_ALU; completion_sources = 0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); defaults();
    endtask
    initial begin
        defaults(); tick(); rst = 0;
        redirect = 1; iq_empty = 1; head_operands_ready = 0; tick();
        iq_empty = 1; head_operands_ready = 0; tick();
        head_operands_ready = 0; tick();
        head_class = SCHED_MEMORY; tick();
        head_class = SCHED_MDU; tick();
        head_class = SCHED_SERIAL; tick();
        tick();
        head_unit_ready = 1; tick();
        for (int reason = 0; reason < 8; reason++)
            assert (dut.no_issue[reason] == 1) else $fatal(1, "stall priority reason=%0d", reason);
        repeat (4) begin
            issue_fire = 1; retire_fire = 1;
            memory_request_fire = 1; memory_response_fire = 2; forward_fire = 1;
            dispatch_pending = 1; rob_full = 1; iq_full = 1; checkpoint_blocked = 1;
            completion_sources = 3;
            tick();
        end
        repeat (6) begin
            issue_fire = 3; retire_fire = 3;
            memory_request_fire = 3; memory_response_fire = 3; completion_sources = 2;
            tick();
        end
        assert (dut.cycles == 18 && dut.issue_cycles[0] == 8 && dut.issue_cycles[1] == 4 &&
                dut.issue_cycles[2] == 6 && dut.retire_cycles[0] == 8 &&
                dut.retire_cycles[1] == 4 && dut.retire_cycles[2] == 6 &&
                dut.rob_wait == 4 && dut.iq_wait == 4 && dut.checkpoint_wait == 4 &&
                dut.completion_pressure == 4 && dut.memory_requests == 16 &&
                dut.memory_responses == 16 && dut.forwards == 4)
            else $fatal(1, "metrics event counts");
        rst = 1; tick(); rst = 0; iq_empty = 1; tick();
        assert (dut.cycles == 1 && dut.issue_cycles[0] == 1 && dut.issue_cycles[1] == 0 &&
                dut.retire_cycles[2] == 0 && dut.no_issue[1] == 1 && dut.no_issue[0] == 0 &&
                dut.rob_wait == 0 && dut.memory_requests == 0) else $fatal(1, "metrics reset");
        $display("PASS tb_scoreboard_metrics XLEN=%0d categories=8 overlap dual_events reset",
                 core_config_pkg::XLEN);
        $finish;
    end
endmodule
