// Module: tb_csr_exec
// Description: Checks all Zicsr atomic read-modify-write operations.
module tb_csr_exec;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;

    csr_cmd_e command;
    xlen_t old_value;
    xlen_t operand;
    xlen_t new_value;

    csr_exec dut (.*);

    initial begin
        old_value = xlen_t'(32'h55aa_0ff0);
        operand = xlen_t'(32'h0f0f_3333);
        command = CSR_RW; #1;
        assert (new_value == operand) else $fatal(1, "CSRRW result");
        command = CSR_RS; #1;
        assert (new_value == (old_value | operand)) else $fatal(1, "CSRRS result");
        command = CSR_RC; #1;
        assert (new_value == (old_value & ~operand)) else $fatal(1, "CSRRC result");
        $display("PASS tb_csr_exec");
        $finish;
    end
endmodule
