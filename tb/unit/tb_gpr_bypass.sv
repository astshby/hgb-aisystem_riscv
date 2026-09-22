// Module: tb_gpr_bypass
// Description: Checks GPR forwarding qualification and newest-producer priority.
module tb_gpr_bypass;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;

    gpr_addr_t source_addr;
    logic source_used;
    xlen_t original_data;
    gpr_forward_t mem_forward;
    gpr_forward_t wb_forward;
    xlen_t forwarded_data;

    gpr_bypass dut (.*);

    initial begin
        source_addr = 5'd3;
        source_used = 1'b1;
        original_data = xlen_t'(32'h10);
        mem_forward = '0;
        mem_forward.addr = 5'd3;
        mem_forward.data = xlen_t'(32'h30);
        wb_forward = '0;
        wb_forward.addr = 5'd3;
        wb_forward.data = xlen_t'(32'h20);
        #1;
        assert (forwarded_data == original_data)
            else $fatal(1, "original operand");

        wb_forward.valid = 1'b1;
        #1;
        assert (forwarded_data == wb_forward.data)
            else $fatal(1, "WB operand forwarding");

        mem_forward.valid = 1'b1;
        #1;
        assert (forwarded_data == mem_forward.data)
            else $fatal(1, "newest MEM operand priority");

        source_used = 1'b0;
        #1;
        assert (forwarded_data == original_data)
            else $fatal(1, "unused source must not forward");

        source_used = 1'b1;
        source_addr = '0;
        mem_forward.addr = '0;
        wb_forward.addr = '0;
        #1;
        assert (forwarded_data == original_data)
            else $fatal(1, "x0 must not forward");

        $display("PASS tb_gpr_bypass RV%0d", core_config_pkg::XLEN);
        $finish;
    end
endmodule
