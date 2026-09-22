// Module: tb_csr_warl
// Description: Checks that forwarded CSR values obey the implemented WARL rules.
module tb_csr_warl;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    csr_addr_t address;
    xlen_t proposed_value;
    xlen_t legal_value;

    csr_warl dut (.*);

    initial begin
        address = CSR_MSTATUS;
        proposed_value = '0; #1;
        assert (legal_value == xlen_t'(32'h1800)) else $fatal(1, "MSTATUS MPP");
        proposed_value = xlen_t'(32'h88); #1;
        assert (legal_value == xlen_t'(32'h1888)) else $fatal(1, "MSTATUS writable fields");
        address = CSR_MTVEC;
        proposed_value = xlen_t'(32'h107); #1;
        assert (legal_value == xlen_t'(32'h104)) else $fatal(1, "MTVEC direct alignment");
        address = CSR_MEPC;
        proposed_value = xlen_t'(32'h203); #1;
        assert (legal_value == xlen_t'(32'h200)) else $fatal(1, "MEPC alignment");
        address = CSR_MSCRATCH; #1;
        assert (legal_value == proposed_value) else $fatal(1, "unrestricted CSR");
        $display("PASS tb_csr_warl");
        $finish;
    end
endmodule
