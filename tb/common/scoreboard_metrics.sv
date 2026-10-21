// Module: scoreboard_metrics
// Description: Passive whole-run issue, retirement and mutually exclusive no-issue accounting.
module scoreboard_metrics #(
    parameter bit EMIT_STATS = 1
) (
    input logic clk, rst,
    input logic [1:0] issue_fire, retire_fire,
    input logic redirect, iq_empty, head_operands_ready, head_unit_ready,
    input scoreboard_pkg::schedule_class_e head_class,
    input logic dispatch_pending, rob_full, iq_full, checkpoint_blocked,
    input logic [1:0] memory_request_fire, memory_response_fire, forward_fire,
    input int unsigned completion_sources
);
    timeunit 1ns;
    timeprecision 1ps;
    import scoreboard_pkg::*;
    longint unsigned cycles, issue_cycles [3], retire_cycles [3], no_issue [8];
    longint unsigned rob_wait, iq_wait, checkpoint_wait, completion_pressure;
    longint unsigned memory_requests, memory_responses, forwards;
    int unsigned reason;
    localparam string STATS_FORMAT = {
        "SCOREBOARD_STATS {\"window\":\"whole_run\",\"cycles\":%0d,",
        "\"issue_0\":%0d,\"issue_1\":%0d,\"issue_2\":%0d,",
        "\"retire_0\":%0d,\"retire_1\":%0d,\"retire_2\":%0d,",
        "\"no_issue_redirect\":%0d,\"no_issue_empty\":%0d,\"no_issue_raw\":%0d,",
        "\"no_issue_lsq\":%0d,\"no_issue_mdu\":%0d,\"no_issue_serial\":%0d,",
        "\"no_issue_result\":%0d,\"no_issue_other\":%0d,",
        "\"dispatch_rob_full\":%0d,\"dispatch_iq_full\":%0d,\"dispatch_checkpoint\":%0d,",
        "\"completion_pressure\":%0d,\"memory_requests\":%0d,\"memory_responses\":%0d,",
        "\"forwarded_loads\":%0d}"
    };

    // 只给未发射周期分配一个原因，重定向、空 IQ、RAW 的优先级高于执行资源。
    // dispatch 容量和完成冲突单独计数，可重叠，不能与 no_issue 相加。
    always_comb begin
        reason = 7;
        if (redirect) reason = 0;
        else if (iq_empty) reason = 1;
        else if (!head_operands_ready) reason = 2;
        else if (!head_unit_ready) begin
            unique case (head_class)
                SCHED_MEMORY: reason = 3;
                SCHED_MDU: reason = 4;
                SCHED_SERIAL: reason = 5;
                default: reason = 6;
            endcase
        end
    end

    // 窗口包括复位释放后的每个上升沿，直到仿真退出；不是 CoreMark ROI。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            for (int count = 0; count < 3; count++) begin
                issue_cycles[count] <= 0;
                retire_cycles[count] <= 0;
            end
            for (int category = 0; category < 8; category++) no_issue[category] <= 0;
            rob_wait <= 0; iq_wait <= 0; checkpoint_wait <= 0; completion_pressure <= 0;
            memory_requests <= 0; memory_responses <= 0; forwards <= 0;
        end else begin
            cycles <= cycles + 1;
            issue_cycles[int'(issue_fire[0]) + int'(issue_fire[1])] <=
                issue_cycles[int'(issue_fire[0]) + int'(issue_fire[1])] + 1;
            retire_cycles[int'(retire_fire[0]) + int'(retire_fire[1])] <=
                retire_cycles[int'(retire_fire[0]) + int'(retire_fire[1])] + 1;
            if (issue_fire == 0) no_issue[reason] <= no_issue[reason] + 1;
            if (dispatch_pending && rob_full) rob_wait <= rob_wait + 1;
            if (dispatch_pending && iq_full) iq_wait <= iq_wait + 1;
            if (dispatch_pending && checkpoint_blocked) checkpoint_wait <= checkpoint_wait + 1;
            if (completion_sources > 2) completion_pressure <= completion_pressure + 1;
            memory_requests <= memory_requests + 64'(memory_request_fire[0]) + 64'(memory_request_fire[1]);
            memory_responses <= memory_responses + 64'(memory_response_fire[0]) + 64'(memory_response_fire[1]);
            forwards <= forwards + 64'(forward_fire[0]) + 64'(forward_fire[1]);
        end
    end

    final begin
        if (EMIT_STATS) begin
            assert (cycles == issue_cycles[0] + issue_cycles[1] + issue_cycles[2] &&
                    cycles == retire_cycles[0] + retire_cycles[1] + retire_cycles[2] &&
                    issue_cycles[0] == no_issue[0] + no_issue[1] + no_issue[2] + no_issue[3] +
                                      no_issue[4] + no_issue[5] + no_issue[6] + no_issue[7])
                else $fatal(1, "scoreboard metrics accounting mismatch");
            $display("%s", $sformatf(STATS_FORMAT,
                     cycles, issue_cycles[0], issue_cycles[1], issue_cycles[2],
                     retire_cycles[0], retire_cycles[1], retire_cycles[2],
                     no_issue[0], no_issue[1], no_issue[2], no_issue[3],
                     no_issue[4], no_issue[5], no_issue[6], no_issue[7],
                     rob_wait, iq_wait, checkpoint_wait, completion_pressure,
                     memory_requests, memory_responses, forwards));
        end
    end
endmodule
