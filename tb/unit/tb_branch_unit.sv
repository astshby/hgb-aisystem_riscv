// Module: tb_branch_unit
// Description: Checks signed/unsigned conditions and JALR bit-zero clearing.
module tb_branch_unit;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;

    branch_op_e branch_op;
    xlen_t pc;
    xlen_t seq_pc;
    xlen_t operand_a;
    xlen_t operand_b;
    xlen_t imm;
    logic taken;
    xlen_t target;

    branch_unit dut (.*);

    initial begin
        pc = xlen_t'(100);
        seq_pc = xlen_t'(104);
        imm = xlen_t'(-16);
        operand_a = xlen_t'(-1);
        operand_b = xlen_t'(1);
        branch_op = BR_LT; #1;
        assert (taken && target == xlen_t'(84)) else $fatal(1, "BLT");
        branch_op = BR_LTU; #1;
        assert (!taken) else $fatal(1, "BLTU");
        branch_op = BR_JALR;
        operand_a = xlen_t'(40);
        imm = xlen_t'(3); #1;
        assert (taken && target == xlen_t'(42)) else $fatal(1, "JALR");
        $display("PASS tb_branch_unit");
        $finish;
    end
endmodule
