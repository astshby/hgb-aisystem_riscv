// Module: branch_unit
// Description: Resolves conditional branches and JALR targets in EX.
// 负责计算与给出跳转信息，不包含跳转判断
module branch_unit (
    input  core_types_pkg::branch_op_e branch_op,
    input  core_types_pkg::xlen_t      pc,
    input  core_types_pkg::xlen_t      seq_pc,
    input  core_types_pkg::xlen_t      operand_a,
    input  core_types_pkg::xlen_t      operand_b,
    input  core_types_pkg::xlen_t      imm,
    output logic                       taken,
    output core_types_pkg::xlen_t      target
);
    import core_types_pkg::*;

    always_comb begin
        taken = 1'b0;
        target = seq_pc;  // 默认情况下，跳转不发生，目标地址为顺序PC
        unique case (branch_op)
            BR_EQ:   begin taken = (operand_a == operand_b); target = pc + imm; end
            BR_NE:   begin taken = (operand_a != operand_b); target = pc + imm; end
            BR_LT:   begin taken = ($signed(operand_a) < $signed(operand_b)); target = pc + imm; end
            BR_GE:   begin taken = ($signed(operand_a) >= $signed(operand_b)); target = pc + imm; end
            BR_LTU:  begin taken = (operand_a < operand_b); target = pc + imm; end
            BR_GEU:  begin taken = (operand_a >= operand_b); target = pc + imm; end
            BR_JALR: begin taken = 1'b1; target = (operand_a + imm) & ~xlen_t'(1); end
            default: ;
        endcase
    end
endmodule
