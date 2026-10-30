// Module: branch_unit
// Description: Resolves conditional branch directions and JAL/JALR targets.
// 根据操作数计算实际方向与目标；外部流水级控制接纳、结果寄存和恢复。
module branch_unit #(
    parameter bit PC_REL_TARGET_IN_IMM = 1'b0
) (
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
    xlen_t pc_relative_target;

    // 仅配对开启的 D1 将 B/JAL 的 imm 改为绝对目标；JALR 始终使用原始位移。
    assign pc_relative_target = PC_REL_TARGET_IN_IMM ? imm : pc + imm;

    always_comb begin
        taken = 1'b0;
        target = seq_pc;  // 默认情况下，跳转不发生，目标地址为顺序PC
        unique case (branch_op)
            // 等值判断用并行 XNOR/OR 归约，避免综合成 32 位减法进位链。
            BR_EQ:   begin taken = &(operand_a ~^ operand_b); target = pc_relative_target; end
            BR_NE:   begin taken = |(operand_a ^ operand_b); target = pc_relative_target; end
            BR_LT:   begin taken = ($signed(operand_a) < $signed(operand_b)); target = pc_relative_target; end
            BR_GE:   begin taken = ($signed(operand_a) >= $signed(operand_b)); target = pc_relative_target; end
            BR_LTU:  begin taken = (operand_a < operand_b); target = pc_relative_target; end
            BR_GEU:  begin taken = (operand_a >= operand_b); target = pc_relative_target; end
            BR_JAL:  begin taken = 1'b1; target = pc_relative_target; end
            BR_JALR: begin taken = 1'b1; target = (operand_a + imm) & ~xlen_t'(1); end
            default: ;
        endcase
    end
endmodule
