// Module: tb_muldiv_backends
// Description: Cross-checks all six multiply/divide configurations including ISA and protocol semantics.
module tb_muldiv_backends;
    timeunit 1ns;
    timeprecision 1ps;
    wire [5:0] finished;
    for (genvar m = 0; m < 3; m++) begin : g_mul
        for (genvar d = 0; d < 2; d++) begin : g_div
            muldiv_checker #(.MUL_IMPL(m), .DIV_IMPL(d), .FINISH_ON_DONE(1'b0),
                .TEST_NAME($sformatf("mdu_backend_m%0dd%0d", m, d))) checker_instance (
                .finished(finished[2*m+d])
            );
        end
    end
    initial begin
        wait (&finished);
        $display("PASS tb_muldiv_backends RV%0d configurations=6", core_config_pkg::XLEN);
        $finish;
    end
endmodule
