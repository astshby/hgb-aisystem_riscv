// Module: d1_stage
// Description: Decodes instructions, creates early exceptions, and resolves operand-free JAL control flow.
// 主要包含：获取指令后的初级解码
module d1_stage (
    input  pipeline_pkg::if_d1_t     in_packet,
    output pipeline_pkg::d1_d2_t     out_packet,
    output pipeline_pkg::redirect_t  redirect,
    output pipeline_pkg::pred_update_t pred_update,
    output logic                       serialize_req
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    uop_t uop;
    gpr_addr_t rs1;
    gpr_addr_t rs2;
    gpr_addr_t rd;
    csr_addr_t csr_addr;
    xlen_t imm;
    xlen_t jal_target;
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

    // 无寄存器依赖的目标地址：唯一在 D1 提前处理的 J 指令是 JAL。
    always_comb begin
        jal_target = in_packet.pc + imm;
    end

    // D1 异常在控制流处理之前完成，异常指令不会产生预测更新或提前重定向。
    d1_exception_check u_d1_exception_check (
        .in_packet,
        .uop,
        .jal_target,
        .exception(decoded_exc)
    );

    // 译码异常和 MRET 都要先清除年轻指令，再等待 WB 完成 Trap/返回。
    always_comb begin
        serialize_req = in_packet.valid &&
                        (decoded_exc.valid || (uop.sys_op == SYS_MRET));
    end

    // JAL 控制：JAL 不进入 GHR，但需要写入 BTB；真正推进时由 core 放行更新。
    always_comb begin
        pred_update = '0;
        redirect = '0;
        if (in_packet.valid && !decoded_exc.valid && (uop.branch_op == BR_JAL)) begin
            pred_update.valid = 1'b1;
            pred_update.kind = BR_JAL;
            pred_update.pc = in_packet.pc;
            pred_update.taken = 1'b1;
            pred_update.target = jal_target;
            pred_update.pred = in_packet.pred;

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
        out_packet.csr_addr = csr_addr;
        out_packet.uop = uop;
        out_packet.pred = in_packet.pred;
        out_packet.exc = decoded_exc;
    end
endmodule
