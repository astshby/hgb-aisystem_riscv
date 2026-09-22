// Module: tb_trap_controller
// Description: Checks exception priority, MRET redirect, and retirement qualification.
module tb_trap_controller;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    mem_wb_t commit_packet;
    logic commit_valid;
    xlen_t mtvec;
    xlen_t mepc;
    logic trap_enter;
    logic mret_commit;
    xlen_t trap_pc;
    exc_cause_e trap_cause;
    xlen_t trap_tval;
    logic retire_valid;
    redirect_t redirect;

    trap_controller dut (.*);

    initial begin
        commit_packet = '0;
        commit_valid = 1'b0;
        mtvec = xlen_t'(32'h100);
        mepc = xlen_t'(32'h204);
        #1;
        assert (!redirect.valid && !retire_valid) else $fatal(1, "idle state");

        commit_packet.valid = 1'b1;
        commit_packet.pc = xlen_t'(32'h80);
        commit_packet.exc.valid = 1'b1;
        commit_packet.exc.cause = EXC_BREAKPOINT;
        commit_packet.exc.tval = xlen_t'(32'h80);
        commit_packet.uop.sys_op = SYS_MRET;
        #1;
        assert (!trap_enter && !redirect.valid && !retire_valid)
            else $fatal(1, "incomplete WB packet must not retire");

        commit_valid = 1'b1;
        #1;
        assert (trap_enter && !mret_commit && !retire_valid) else $fatal(1, "trap qualification");
        assert (redirect.valid && redirect.pc == mtvec && redirect.reason == REDIR_TRAP)
            else $fatal(1, "trap redirect");

        commit_packet.exc = '0;
        #1;
        assert (!trap_enter && mret_commit && retire_valid) else $fatal(1, "MRET qualification");
        assert (redirect.valid && redirect.pc == mepc && redirect.reason == REDIR_MRET)
            else $fatal(1, "MRET redirect");

        commit_packet.uop.sys_op = SYS_NONE;
        #1;
        assert (!redirect.valid && retire_valid) else $fatal(1, "normal retirement");
        $display("PASS tb_trap_controller");
        $finish;
    end
endmodule
