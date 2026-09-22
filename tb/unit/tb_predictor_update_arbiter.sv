// Module: tb_predictor_update_arbiter
// Description: Checks EX priority and deferred delivery of a simultaneous D1 update.
module tb_predictor_update_arbiter;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic d1_flush;
    pred_update_t d1_update;
    pred_update_t ex_update;
    pred_update_t update;
    logic overflow;

    always #5 clk = ~clk;
    predictor_update_arbiter dut (.*);

    initial begin
        d1_update = '0;
        ex_update = '0;
        d1_flush = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        d1_update.valid = 1'b1;
        d1_update.kind = BR_JAL;
        d1_update.pc = core_types_pkg::xlen_t'(32'h20);
        ex_update.valid = 1'b1;
        ex_update.kind = BR_EQ;
        ex_update.pc = core_types_pkg::xlen_t'(32'h10);
        #1;
        assert (update.pc == ex_update.pc && !overflow) else $fatal(1, "EX priority");
        @(posedge clk);
        @(negedge clk);
        d1_update.valid = 1'b0;
        ex_update.valid = 1'b0;
        #1;
        assert (update.valid && update.pc == core_types_pkg::xlen_t'(32'h20))
            else $fatal(1, "pending D1 update");

        // pending 发出后必须清空，不能重复训练。
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (!update.valid) else $fatal(1, "pending update repeated");

        // 预测更新进入 pending 后，若更老的异常/重定向清除该路径，pending 也必须作废。
        d1_update.valid = 1'b1;
        d1_update.pc = core_types_pkg::xlen_t'(32'h2c);
        ex_update.valid = 1'b1;
        ex_update.pc = core_types_pkg::xlen_t'(32'h28);
        @(posedge clk);
        @(negedge clk);
        d1_update.valid = 1'b0;
        ex_update.valid = 1'b0;
        d1_flush = 1'b1;
        #1;
        assert (!update.valid && !overflow) else $fatal(1, "flushed pending update");
        @(posedge clk);
        @(negedge clk);
        d1_flush = 1'b0;
        #1;
        assert (!update.valid) else $fatal(1, "pending survived flush");

        // 连续第二拍仍同时到达两个更新时，单槽结构必须明确报告溢出。
        d1_update.valid = 1'b1;
        d1_update.pc = core_types_pkg::xlen_t'(32'h30);
        ex_update.valid = 1'b1;
        ex_update.pc = core_types_pkg::xlen_t'(32'h24);
        @(posedge clk);
        @(negedge clk);
        d1_update.pc = core_types_pkg::xlen_t'(32'h38);
        ex_update.pc = core_types_pkg::xlen_t'(32'h28);
        #1;
        assert (overflow && update.pc == ex_update.pc)
            else $fatal(1, "arbiter overflow reporting");
        $display("PASS tb_predictor_update_arbiter");
        $finish;
    end
endmodule
