// Module: trap_controller
// Description: Converts synchronous traps, drained interrupts, MRET, and fences into WB redirects.
// WB阶段的异常或MRET提交会触发trap_controller模块，评定并进入相应的处理流程。(与csr_file模块配合有输入输出)
module trap_controller (
    input  pipeline_pkg::mem_wb_t      commit_packet,
    input  logic                       commit_valid,
    input  logic                       interrupt_take,
    input  core_types_pkg::xlen_t      interrupt_pc,
    input  riscv_priv_pkg::irq_cause_e interrupt_cause,
    input  core_types_pkg::xlen_t      mtvec,
    input  core_types_pkg::xlen_t      mepc,
    output logic                       trap_enter,
    output core_types_pkg::xlen_t      trap_pc,
    output core_types_pkg::xlen_t      trap_cause,
    output core_types_pkg::xlen_t      trap_tval,
    output logic                       mret_commit,
    output logic                       retire_valid,
    output pipeline_pkg::redirect_t    redirect
);
    import pipeline_pkg::*;
    import core_types_pkg::*;

    // 只有 WB 及其存储器响应都完整时才允许退休、进入 trap 或执行 MRET。
    always_comb begin
        // trap:指令有效且异常序列化处理有效，mret：指令有效并且异常序列化处理无效且指令为MRET
        trap_enter = (commit_valid && commit_packet.exc.valid) || interrupt_take;
        trap_pc = commit_packet.pc;
        trap_cause = xlen_t'(commit_packet.exc.cause);
        trap_tval = commit_packet.exc.tval;
        retire_valid = commit_valid && !commit_packet.exc.valid;
        mret_commit = retire_valid && (commit_packet.uop.sys_op == SYS_MRET);

        // 中断只在流水排空时进入，没有一条“中断指令”需要计入 MINSTRET。
        if (interrupt_take && !commit_valid) begin
            trap_pc = interrupt_pc;
            trap_cause = (xlen_t'(1) << (core_config_pkg::XLEN-1)) | xlen_t'(interrupt_cause);
            trap_tval = '0;
        end
        redirect = '0;
        if (trap_enter) begin
            redirect.valid = 1'b1;
            redirect.pc = mtvec;
            redirect.reason = REDIR_TRAP;
        end else if (mret_commit) begin
            redirect.valid = 1'b1;
            redirect.pc = mepc;
            redirect.reason = REDIR_MRET;
        end else if (retire_valid && ((commit_packet.uop.sys_op == SYS_FENCE) ||
                                     (commit_packet.uop.sys_op == SYS_FENCE_I))) begin
            // 单条在途数据访问已排空；重新取下一条指令，并丢弃 IF 中的旧响应。
            redirect.valid = 1'b1;
            redirect.pc = commit_packet.seq_pc;
            redirect.reason = REDIR_FENCE;
        end
    end
endmodule
