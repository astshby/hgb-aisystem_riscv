// Module: tb_trap_controller
// Description: Checks exception priority, MRET redirect, and retirement qualification.
module tb_trap_controller;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    mem_wb_t commit_packet;
    retire_alloc_t head_meta;
    retire_result_t head_result;
    logic commit_valid;
    xlen_t mtvec;
    xlen_t mepc;
    logic trap_enter;
    logic mret_commit;
    xlen_t trap_pc;
    xlen_t trap_cause;
    logic interrupt_take = 0;
    xlen_t interrupt_pc = '0;
    irq_cause_e interrupt_cause = IRQ_M_TIMER;
    xlen_t trap_tval;
    logic retire_valid;
    logic execution_cancel;
    redirect_t redirect;

    trap_controller dut (.*);

    // 原场景仍使用流水包构造输入，显式转换为退休接口，保留所有异常优先级验证。
    always_comb begin
        head_meta = '0;
        head_meta.pc = commit_packet.pc;
        head_meta.seq_pc = commit_packet.seq_pc;
        head_meta.sys_op = commit_packet.uop.sys_op;
        head_result = '0;
        head_result.exc = commit_packet.exc;
    end

    initial begin
        commit_packet = '0;
        commit_valid = 1'b0;
        mtvec = xlen_t'(32'h100);
        mepc = xlen_t'(32'h204);
        #1;
        assert (!redirect.valid && !retire_valid && !execution_cancel) else $fatal(1, "idle state");

        commit_packet.valid = 1'b1;
        commit_packet.pc = xlen_t'(32'h80);
        commit_packet.exc.valid = 1'b1;
        commit_packet.exc.cause = EXC_BREAKPOINT;
        commit_packet.exc.tval = xlen_t'(32'h80);
        commit_packet.uop.sys_op = SYS_MRET;
        #1;
        assert (!trap_enter && !redirect.valid && !retire_valid && !execution_cancel)
            else $fatal(1, "incomplete WB packet must not retire");

        commit_valid = 1'b1;
        #1;
        assert (trap_enter && !mret_commit && !retire_valid && execution_cancel)
            else $fatal(1, "trap qualification");
        assert (redirect.valid && redirect.pc == mtvec && redirect.reason == REDIR_TRAP)
            else $fatal(1, "trap redirect");

        commit_packet.exc = '0;
        #1;
        assert (!trap_enter && mret_commit && retire_valid && execution_cancel)
            else $fatal(1, "MRET qualification");
        assert (redirect.valid && redirect.pc == mepc && redirect.reason == REDIR_MRET)
            else $fatal(1, "MRET redirect");

        commit_packet.uop.sys_op = SYS_NONE;
        #1;
        assert (!redirect.valid && retire_valid && !execution_cancel) else $fatal(1, "normal retirement");
        commit_packet.seq_pc = xlen_t'(32'h84);
        for (int instruction = 0; instruction < 2; instruction++) begin
            commit_packet.uop.sys_op = instruction == 0 ? SYS_FENCE : SYS_FENCE_I;
            #1;
            assert (execution_cancel && retire_valid && !trap_enter &&
                    redirect.valid && redirect.reason == REDIR_FENCE &&
                    redirect.pc == commit_packet.seq_pc)
                else $fatal(1, "fence must cancel younger execution");
        end
        commit_valid = 1'b0;
        interrupt_take = 1'b1;
        interrupt_pc = xlen_t'(32'h500);
        #1;
        assert (trap_enter && !retire_valid && !mret_commit && !execution_cancel &&
                redirect.valid && redirect.pc == mtvec &&
                trap_pc == interrupt_pc && trap_tval == 0 &&
                trap_cause == ((xlen_t'(1) << (core_config_pkg::XLEN-1)) | xlen_t'(7)))
            else $fatal(1, "drained interrupt entry");
        // IRQ 与同步异常同时送入时，保留同步异常与取消的优先级。
        commit_valid = 1'b1;
        commit_packet.exc.valid = 1'b1;
        commit_packet.exc.cause = EXC_BREAKPOINT;
        #1;
        assert (execution_cancel && trap_enter && trap_pc == commit_packet.pc &&
                trap_cause == xlen_t'(EXC_BREAKPOINT) && !retire_valid)
            else $fatal(1, "synchronous trap cancel lost under interrupt input");
        $display("PASS tb_trap_controller");
        $finish;
    end
endmodule
