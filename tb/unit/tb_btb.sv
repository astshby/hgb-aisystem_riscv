// Module: tb_btb
// Description: Checks BTB allocation, update bypass, and same-index tag replacement.
module tb_btb;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    xlen_t lookup_pc;
    logic lookup_hit;
    xlen_t lookup_target;
    branch_op_e lookup_kind;
    logic [BTB_IDX_W-1:0] lookup_idx;
    logic update_valid;
    xlen_t update_pc;
    xlen_t update_target;
    branch_op_e update_kind;
    xlen_t alias_pc;

    always #5 clk = ~clk;
    btb dut (.*);

    initial begin
        lookup_pc = xlen_t'(32'h100);
        update_valid = 1'b0;
        update_pc = '0;
        update_target = '0;
        update_kind = BR_NONE;
        alias_pc = xlen_t'(32'h100 + (BTB_ENTRIES * 4));

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;
        assert (!lookup_hit && lookup_target == '0 && lookup_kind == BR_NONE)
            else $fatal(1, "BTB reset miss");

        // 写入旁路应在时钟沿前可见，随后保存为正式表项。
        update_valid = 1'b1;
        update_pc = lookup_pc;
        update_target = xlen_t'(32'h180);
        update_kind = BR_JAL;
        #1;
        assert (lookup_hit && lookup_target == update_target && lookup_kind == BR_JAL)
            else $fatal(1, "BTB update bypass");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h180))
            else $fatal(1, "BTB stored entry");

        // 相差 BTB_ENTRIES 个指令的 PC 索引相同，完整标签必须阻止别名误命中。
        update_valid = 1'b1;
        update_pc = alias_pc;
        update_target = xlen_t'(32'h1c0);
        update_kind = BR_EQ;
        #1;
        assert (!lookup_hit && lookup_target == '0)
            else $fatal(1, "BTB same-index alias bypass");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        lookup_pc = alias_pc;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h1c0) && lookup_kind == BR_EQ)
            else $fatal(1, "BTB replacement entry");
        lookup_pc = xlen_t'(32'h100);
        #1;
        assert (!lookup_hit) else $fatal(1, "BTB old tag survived replacement");

        $display("PASS tb_btb RV%0d", XLEN);
        $finish;
    end
endmodule
