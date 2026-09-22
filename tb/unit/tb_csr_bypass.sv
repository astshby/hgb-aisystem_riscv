// Module: tb_csr_bypass
// Description: Checks CSR forwarding matches and newest-producer priority.
module tb_csr_bypass;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    csr_addr_t read_addr;
    xlen_t committed_data;
    csr_forward_t mem_forward;
    csr_forward_t wb_forward;
    xlen_t bypass_data;

    csr_bypass dut (.*);

    initial begin
        read_addr = CSR_MSTATUS;
        committed_data = xlen_t'(32'h10);
        mem_forward = '0;
        mem_forward.addr = CSR_MSTATUS;
        mem_forward.data = xlen_t'(32'h30);
        wb_forward = '0;
        wb_forward.addr = CSR_MSTATUS;
        wb_forward.data = xlen_t'(32'h20);
        #1;
        assert (bypass_data == committed_data)
            else $fatal(1, "committed CSR value");

        wb_forward.valid = 1'b1;
        #1;
        assert (bypass_data == wb_forward.data)
            else $fatal(1, "WB CSR bypass");

        mem_forward.valid = 1'b1;
        #1;
        assert (bypass_data == mem_forward.data)
            else $fatal(1, "newest MEM CSR bypass priority");

        mem_forward.addr = CSR_MTVEC;
        #1;
        assert (bypass_data == wb_forward.data)
            else $fatal(1, "MEM address mismatch");

        wb_forward.addr = CSR_MEPC;
        #1;
        assert (bypass_data == committed_data)
            else $fatal(1, "all bypass addresses mismatch");

        $display("PASS tb_csr_bypass RV%0d", core_config_pkg::XLEN);
        $finish;
    end
endmodule
