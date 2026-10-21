// Module: tb_btb
// Description: Checks read-first BTB allocation, target updates, tag replacement, and reset.
module tb_btb;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import predictor_types_pkg::*;
    ras_op_e lookup_ras_op, update_ras_op = RAS_NONE;

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
    btb dut (.lookup_pc_1('0), .lookup_hit_1(), .lookup_target_1(),
             .lookup_kind_1(), .lookup_ras_op_1(), .lookup_idx_1(), .*);

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

        // 分配在时钟沿后才可见，查询不得组合依赖当前训练端口。
        update_valid = 1'b1;
        update_pc = lookup_pc;
        update_target = xlen_t'(32'h180);
        update_kind = BR_JAL;
        update_ras_op = RAS_PUSH;
        #1;
        assert (!lookup_hit && lookup_target == '0 && lookup_kind == BR_NONE)
            else $fatal(1, "BTB allocation leaked before clock");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h180) && lookup_ras_op == RAS_PUSH)
            else $fatal(1, "BTB stored entry");

        // 命中项改目标/类型时，沿前仍读旧项，沿后必须一次性看到完整新项。
        update_valid = 1'b1;
        update_target = xlen_t'(32'h184);
        update_kind = BR_JALR;
        update_ras_op = RAS_POP;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h180) && lookup_kind == BR_JAL && lookup_ras_op == RAS_PUSH)
            else $fatal(1, "BTB replacement payload leaked before clock");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h184) && lookup_kind == BR_JALR && lookup_ras_op == RAS_POP)
            else $fatal(1, "BTB target/type update was not stored");

        // 相差 BTB_ENTRIES 个指令的 PC 索引相同，完整标签必须阻止别名误命中。
        update_valid = 1'b1;
        update_pc = alias_pc;
        update_target = xlen_t'(32'h1c0);
        update_kind = BR_EQ;
        update_ras_op = RAS_NONE;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h184) && lookup_kind == BR_JALR)
            else $fatal(1, "BTB old tag disappeared before replacement clock");
        lookup_pc = alias_pc;
        #1;
        assert (!lookup_hit && lookup_target == '0 && lookup_kind == BR_NONE)
            else $fatal(1, "BTB alias allocated before clock");
        @(posedge clk);
        @(negedge clk);
        update_valid = 1'b0;
        lookup_pc = alias_pc;
        #1;
        assert (lookup_hit && lookup_target == xlen_t'(32'h1c0) && lookup_kind == BR_EQ && lookup_ras_op == RAS_NONE)
            else $fatal(1, "BTB replacement entry");
        lookup_pc = xlen_t'(32'h100);
        #1;
        assert (!lookup_hit) else $fatal(1, "BTB old tag survived replacement");

        // reset/FENCE.I 优先于同拍训练，清 valid 后不能从训练旁路复活旧项。
        @(negedge clk);
        rst = 1'b1;
        update_valid = 1'b1;
        lookup_pc = alias_pc;
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (!lookup_hit && lookup_target == '0 && lookup_kind == BR_NONE)
            else $fatal(1, "BTB reset lost priority over training");

        $display("PASS tb_btb RV%0d", XLEN);
        $finish;
    end
endmodule
