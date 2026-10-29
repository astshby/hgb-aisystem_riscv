// Module: d1_stage
// Description: Decodes instructions, creates early exceptions, and resolves operand-free JAL control flow.
// 主要包含：获取指令后的初级解码
module d1_stage #(
    parameter bit PC_REL_TARGET_IN_IMM = 1'b0
) (
    input  pipeline_pkg::if_d1_t     in_packet,
    output pipeline_pkg::d1_d2_t     out_packet,
    output pipeline_pkg::redirect_t  redirect,
    output logic                       serialize_req
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    uop_t uop;
    gpr_addr_t rs1;
    gpr_addr_t rs2;
    gpr_addr_t rd;
    csr_addr_t csr_addr;
    xlen_t imm;
    xlen_t jal_target, jal_imm;
    logic jal_opcode, jal_aligned;
    xlen_t branch_imm, branch_target;
    logic branch_opcode;
    exception_t decoded_exc;

    decoder u_decoder (
        .inst(in_packet.inst),
        .uop,
        .rs1,
        .rs2,
        .rd,
        .csr_addr
    );

    imm_gen u_imm_gen (
        .inst(in_packet.inst),
        .imm
    );

    // JAL 的 opcode 唯一确定合法性和 J 型位移；提前控制不等待通用 uOp/立即数选择。
    assign jal_opcode = in_packet.inst[6:0] == 7'b1101111;
    assign jal_imm = {{(XLEN-21){in_packet.inst[31]}}, in_packet.inst[31],
                     in_packet.inst[19:12], in_packet.inst[20], in_packet.inst[30:21], 1'b0};
    assign jal_target = in_packet.pc + jal_imm;
    // PC 已四字节对齐时，JAL 目标 bit1 直接等于 inst[21]，无需等待地址加法器。
    assign jal_aligned = in_packet.pc[1:0] == 2'b00 && !in_packet.inst[21];

    // scoreboard 可复用 imm 保存 B/JAL 绝对目标；其他指令仍传原始立即数。
    // B 位移从指令位直接展开，不把通用解码链接到现有 JAL 提前重定向通路。
    assign branch_opcode = in_packet.inst[6:0] == 7'b1100011 &&
        (in_packet.inst[14:12] inside {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111});
    assign branch_imm = {{(XLEN-13){in_packet.inst[31]}}, in_packet.inst[31],
                        in_packet.inst[7], in_packet.inst[30:25], in_packet.inst[11:8], 1'b0};
    assign branch_target = in_packet.pc + branch_imm;

    // D1 异常在控制流处理之前完成，异常指令不会产生提前重定向。
    d1_exception_check u_d1_exception_check (
        .in_packet,
        .uop,
        .jal_target,
        .exception(decoded_exc)
    );

    // 译码异常、MRET 和 FENCE 先清除年轻指令，再等待 WB 完成 Trap/返回/排序。
    always_comb begin
        serialize_req = in_packet.valid &&
                        (decoded_exc.valid || (uop.sys_op == SYS_MRET) ||
                         (uop.sys_op == SYS_FENCE) || (uop.sys_op == SYS_FENCE_I));
    end

    // JAL 控制仍在 D1 提前解析；BTB 等该指令正常退休才训练，JAL 不进入 GHR。
    always_comb begin
        redirect = '0;
        // JAL 不属于 SYSTEM/非法编码；IF 错误和 PC/目标未对齐仍禁止提前重定向。
        if (in_packet.valid && jal_opcode && !in_packet.exc.valid && jal_aligned) begin
            // 指令有效、未命中预测或目标错误时，重定向到实际 JAL 目标。
            if (!in_packet.pred.taken || (in_packet.pred.target != jal_target)) begin
                redirect.valid = 1'b1;
                redirect.pc = jal_target;
                redirect.reason = REDIR_D1_JAL;
            end
        end
    end

    // 输出打包：uOp 保存静态控制，exc 保存随流水线传播的动态异常。
    always_comb begin
        out_packet = '0;
        out_packet.valid = in_packet.valid;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
        out_packet.inst = in_packet.inst;
        out_packet.rs1 = rs1;
        out_packet.rs2 = rs2;
        out_packet.rd = rd;
        out_packet.imm = imm;
        if (PC_REL_TARGET_IN_IMM) begin
            if (jal_opcode) out_packet.imm = jal_target;
            else if (branch_opcode) out_packet.imm = branch_target;
        end
        out_packet.csr_addr = csr_addr;
        out_packet.uop = uop;
        out_packet.pred = in_packet.pred;
        out_packet.exc = decoded_exc;
    end
endmodule
