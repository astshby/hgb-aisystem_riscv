// Module: tb_predictor
// Description: Checks BTB allocation, JAL prediction, and saved-index GShare training.
module tb_predictor;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import predictor_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    xlen_t lookup_pc;
    pred_info_t prediction;
    pred_info_t before_training;
    pred_update_t update;
    logic ras_top_valid = 1'b0;
    xlen_t ras_top_addr = '0;
    logic [PHT_IDX_W-1:0] saved_idx;
    logic [GHR_W-1:0] saved_ghr;

    always #5 clk = ~clk;
    predictor dut (.lookup_pc_1('0), .prediction_1(), .*);

    initial begin
        lookup_pc = xlen_t'(32'h100);
        update = '0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;
        assert (!prediction.hit) else $fatal(1, "unexpected BTB hit after reset");

        // JAL 只训练 BTB，不进入条件分支的 GHR。
        saved_ghr = dut.u_gshare.ghr_q;
        update.valid = 1'b1;
        update.kind = BR_JAL;
        update.pc = lookup_pc;
        update.taken = 1'b1;
        update.target = xlen_t'(32'h180);
        #1;
        assert (!prediction.hit && !prediction.taken && prediction.target == '0)
            else $fatal(1, "JAL training leaked into same-cycle prediction");
        @(posedge clk);
        @(negedge clk);
        update.valid = 1'b0;
        #1;
        assert (prediction.hit && prediction.taken && prediction.target == xlen_t'(32'h180))
            else $fatal(1, "JAL prediction");
        assert (dut.u_gshare.ghr_q == saved_ghr)
            else $fatal(1, "JAL must not update GHR");

        lookup_pc = xlen_t'(32'h104); #1;
        saved_idx = prediction.train.pht_idx;
        before_training = prediction;
        update.valid = 1'b1;
        update.kind = BR_EQ;
        update.pc = lookup_pc;
        update.target = xlen_t'(32'h120);
        update.taken = 1'b0;
        update.train.pht_idx = prediction.train.pht_idx;
        #1;
        assert (prediction == before_training)
            else $fatal(1, "conditional training bypassed read-first prediction");
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (dut.u_gshare.pht_q[saved_idx] == 2'b00) else $fatal(1, "not-taken training");
        update.taken = 1'b1;
        update.train.pht_idx = saved_idx;
        @(posedge clk);
        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        update.valid = 1'b0;
        #1;
        assert (dut.u_gshare.pht_q[saved_idx] == 2'b10) else $fatal(1, "saved-index training");
        // 空 RAS 回退 BTB；非空只选择已经寄存的栈顶，不增加查询拍或读取当前训练目标。
        update = '0; update.valid = 1; update.kind = BR_JALR;
        update.pc = xlen_t'(32'h200); update.target = xlen_t'(32'h240);
        update.taken = 1; update.ras_op = RAS_POP;
        @(posedge clk); @(negedge clk);
        update.valid = 0; lookup_pc = xlen_t'(32'h200); #1;
        assert (prediction.hit && prediction.taken && prediction.target == xlen_t'(32'h240))
            else $fatal(1, "empty RAS did not fall back to BTB");
        ras_top_valid = 1; ras_top_addr = xlen_t'(32'h280); #1;
        assert (prediction.target == xlen_t'(RAS_ENABLE ? 32'h280 : 32'h240))
            else $fatal(1, "RAS target selection/configuration");
        update.valid = 1; update.target = xlen_t'(32'h300); #1;
        assert (prediction.target == xlen_t'(RAS_ENABLE ? 32'h280 : 32'h240))
            else $fatal(1, "same-cycle BTB training bypassed registered prediction");
        $display("PASS tb_predictor");
        $finish;
    end
endmodule
