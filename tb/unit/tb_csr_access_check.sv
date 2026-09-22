// Module: tb_csr_access_check
// Description: Checks implemented CSR addresses and read-only write rejection.
module tb_csr_access_check;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    csr_addr_t address;
    logic write_intent;
    logic implemented;
    logic read_only;
    logic illegal;

    csr_access_check dut (.*);

    initial begin
        address = CSR_MSCRATCH;
        write_intent = 1'b1; #1;
        assert (implemented && !read_only && !illegal) else $fatal(1, "MSCRATCH access");
        address = CSR_MISA; #1;
        assert (implemented && read_only && illegal) else $fatal(1, "MISA write");
        write_intent = 1'b0; #1;
        assert (!illegal) else $fatal(1, "MISA read");
        address = CSR_MHARTID; #1;
        assert (implemented && read_only && !illegal) else $fatal(1, "MHARTID read");
        address = CSR_MVENDORID; #1;
        assert (implemented && read_only && !illegal) else $fatal(1, "MVENDORID read");
        address = CSR_MIE; #1;
        assert (!implemented && illegal) else $fatal(1, "MIE is reserved for interrupt stage");
        address = CSR_MIP; #1;
        assert (!implemented && illegal) else $fatal(1, "MIP is reserved for interrupt stage");
        address = CSR_MCYCLEH;
        write_intent = 1'b1; #1;
        if (XLEN == 32)
            assert (implemented && !read_only && !illegal)
                else $fatal(1, "RV32 MCYCLEH access");
        else
            assert (!implemented && illegal)
                else $fatal(1, "RV64 must not implement MCYCLEH");
        address = CSR_MINSTRETH; #1;
        if (XLEN == 32)
            assert (implemented && !read_only && !illegal)
                else $fatal(1, "RV32 MINSTRETH access");
        else
            assert (!implemented && illegal)
                else $fatal(1, "RV64 must not implement MINSTRETH");
        address = 12'h7c0; #1;
        assert (!implemented && illegal) else $fatal(1, "unimplemented CSR");
        $display("PASS tb_csr_access_check");
        $finish;
    end
endmodule
