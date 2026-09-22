// Module: tb_gshare
// Description: Checks saved-index training, saturating counters, and GHR updates.
module tb_gshare;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    xlen_t lookup_pc;
    logic lookup_taken;
    logic [PHT_IDX_W-1:0] lookup_idx;
    logic update_valid;
    logic [PHT_IDX_W-1:0] update_idx;
    logic update_taken;
    logic [PHT_IDX_W-1:0] saved_idx;

    always #5 clk = ~clk;
    gshare dut (.*);

    initial begin
        lookup_pc = xlen_t'(32'h100);
        update_valid = 1'b0;
        update_idx = '0;
        update_taken = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;
        saved_idx = lookup_idx;
        assert (!lookup_taken && dut.ghr_q == '0)
            else $fatal(1, "GShare reset state");

        // 新项从 01 开始，一次 taken 训练到 10，并更新非推测 GHR。
        update_valid = 1'b1;
        update_idx = saved_idx;
        update_taken = 1'b1;
        #1;
        assert (lookup_taken) else $fatal(1, "GShare same-cycle bypass");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        #1;
        assert (dut.pht_q[saved_idx] == 2'b10 && dut.ghr_q == GHR_W'(1))
            else $fatal(1, "GShare first taken update");

        // 即使 GHR 改变了查询索引，训练仍必须写回取指时保存的索引。
        update_valid = 1'b1;
        update_idx = saved_idx;
        update_taken = 1'b1;
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (dut.pht_q[saved_idx] == 2'b11)
            else $fatal(1, "GShare saved-index training");
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (dut.pht_q[saved_idx] == 2'b11)
            else $fatal(1, "GShare taken saturation");

        update_taken = 1'b0;
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        #1;
        assert (dut.pht_q[saved_idx] == 2'b10 && dut.ghr_q[0] == 1'b0)
            else $fatal(1, "GShare not-taken update");

        $display("PASS tb_gshare RV%0d", XLEN);
        $finish;
    end
endmodule
