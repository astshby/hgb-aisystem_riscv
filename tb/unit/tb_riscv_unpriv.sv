// Module: tb_riscv_unpriv
// Description: Checks unprivileged instruction encodings.
// 用于检查非特权级指令编码
module tb_riscv_unpriv;
    timeunit 1ns;
    timeprecision 1ps;

    import riscv_unpriv_pkg::*;

    initial begin
        assert (OPCODE_LOAD == 7'b0000011 && OPCODE_OP == 7'b0110011 &&
                OPCODE_SYSTEM == 7'b1110011)
            else $fatal(1, "invalid unprivileged major opcode");
        assert (INST_ECALL == 32'h0000_0073 && INST_EBREAK == 32'h0010_0073)
            else $fatal(1, "invalid environment instruction encoding");
        $display("PASS tb_riscv_unpriv");
        $finish;
    end
endmodule
