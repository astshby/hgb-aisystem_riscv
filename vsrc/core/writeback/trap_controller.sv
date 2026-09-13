// Module: trap_controller
// Description: Converts a faulting or MRET commit into the oldest redirect event.
// WB阶段的异常或MRET提交会触发trap_controller模块，评定并进入相应的处理流程。(与csr_file模块配合有输入输出)
module trap_controller (
    input  pipeline_pkg::mem_wb_t      commit_packet,
    input  logic                       commit_valid,
    input  core_types_pkg::xlen_t      mtvec,
    input  core_types_pkg::xlen_t      mepc,
    output logic                       trap_enter,
    output core_types_pkg::xlen_t      trap_pc,
    output riscv_priv_pkg::exc_cause_e trap_cause,
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
        trap_enter = commit_valid && commit_packet.exc.valid;
        trap_pc = commit_packet.pc;
        trap_cause = commit_packet.exc.cause;
        trap_tval = commit_packet.exc.tval;
        mret_commit = commit_valid && !commit_packet.exc.valid &&
                      (commit_packet.uop.sys_op == SYS_MRET);
        retire_valid = commit_valid && !commit_packet.exc.valid;

        redirect = '0;
        if (trap_enter) begin
            redirect.valid = 1'b1;
            redirect.pc = mtvec;
            redirect.reason = REDIR_TRAP;
        end else if (mret_commit) begin
            redirect.valid = 1'b1;
            redirect.pc = mepc;
            redirect.reason = REDIR_MRET;
        end
    end
endmodule
