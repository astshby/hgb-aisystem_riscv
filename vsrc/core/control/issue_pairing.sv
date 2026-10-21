// Module: issue_pairing
// Description: Qualifies an in-order general lane followed by one independent integer ALU lane.
module issue_pairing (
    input pipeline_pkg::d1_d2_t first_packet, second_packet,
    input logic second_waw_block, second_operands_ready,
    output logic pair_eligible
);
    import core_types_pkg::*;
    logic first_class, second_class, same_group_raw, same_group_waw;

    // 控制流/序列化独占组，保持EX纠错时没有已分配年轻执行者的恢复证明。
    always_comb begin
        first_class = !first_packet.exc.valid && first_packet.uop.branch_op == BR_NONE &&
            !first_packet.uop.csr_valid && first_packet.uop.sys_op == SYS_NONE &&
            (first_packet.uop.fu inside {FU_ALU, FU_LSU, FU_MULDIV});
        second_class = !second_packet.exc.valid && second_packet.uop.fu == FU_ALU &&
            second_packet.uop.branch_op == BR_NONE && !second_packet.uop.csr_valid &&
            !second_packet.uop.mem_read && !second_packet.uop.mem_write &&
            second_packet.uop.sys_op == SYS_NONE;
        same_group_raw = first_packet.uop.gpr_write && first_packet.rd != '0 &&
            ((second_packet.uop.rs1_used && second_packet.rs1 == first_packet.rd) ||
             (second_packet.uop.rs2_used && second_packet.rs2 == first_packet.rd));
        same_group_waw = first_packet.uop.gpr_write && second_packet.uop.gpr_write &&
            first_packet.rd != '0 && first_packet.rd == second_packet.rd;
        pair_eligible = first_packet.valid && second_packet.valid &&
            second_packet.pc == first_packet.seq_pc && first_class && second_class &&
            !same_group_raw && !same_group_waw && !second_waw_block && second_operands_ready;
    end
endmodule
