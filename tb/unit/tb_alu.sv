// Module: tb_alu
// Description: Checks arithmetic, comparisons, logic, and XLEN shift behavior.
module tb_alu;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    xlen_t operand_a;
    xlen_t operand_b;
    alu_op_e operation;
    op_width_e op_width;
    xlen_t result;

    alu dut (.*);

    task automatic check(input alu_op_e op, input xlen_t a, input xlen_t b, input xlen_t expected);
        operation = op;
        operand_a = a;
        operand_b = b;
        #1;
        assert (result == expected) else $fatal(1, "ALU op %0d got %h expected %h", op, result, expected);
    endtask

    initial begin
        op_width = OP_WIDTH_XLEN;
        check(ALU_ADD, xlen_t'(9), xlen_t'(7), xlen_t'(16));
        check(ALU_SUB, xlen_t'(9), xlen_t'(12), xlen_t'(-3));
        check(ALU_SLT, xlen_t'(-1), xlen_t'(1), xlen_t'(1));
        check(ALU_SLTU, xlen_t'(-1), xlen_t'(1), '0);
        check(ALU_SLL, xlen_t'(1), xlen_t'(XLEN-1), xlen_t'(1) << (XLEN-1));
        check(ALU_SRA, xlen_t'(-8), xlen_t'(2), xlen_t'(-2));
        check(ALU_XOR, xlen_t'(16'h55aa), xlen_t'(16'h0ff0), xlen_t'(16'h5a5a));
        if (XLEN == 64) begin
            op_width = OP_WIDTH_WORD;
            check(ALU_ADD, xlen_t'(64'hffff_ffff_7fff_ffff), xlen_t'(1),
                  xlen_t'(64'hffff_ffff_8000_0000));
            check(ALU_SRL, xlen_t'(64'hffff_ffff_8000_0000), xlen_t'(31),
                  xlen_t'(1));
            check(ALU_SRA, xlen_t'(64'h0000_0000_8000_0000), xlen_t'(31),
                  xlen_t'(64'hffff_ffff_ffff_ffff));
        end
        $display("PASS tb_alu RV%0d", XLEN);
        $finish;
    end
endmodule
