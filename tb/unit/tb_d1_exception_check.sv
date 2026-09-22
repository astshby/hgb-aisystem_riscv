// Module: tb_d1_exception_check
// Description: Checks D1 exception priority and early instruction/JAL validation.
module tb_d1_exception_check;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    if_d1_t in_packet;
    uop_t uop;
    xlen_t jal_target;
    exception_t exception;

    d1_exception_check dut (.*);

    initial begin
        in_packet = '0;
        uop = '0;
        jal_target = '0;
        #1;
        assert (!exception.valid) else $fatal(1, "invalid packet exception");

        // 指令地址未对齐具有最高优先级。
        in_packet.valid = 1'b1;
        in_packet.pc = xlen_t'(32'h102);
        in_packet.inst = 32'hffff_ffff;
        uop.illegal = 1'b1;
        #1;
        assert (exception.valid && exception.cause == EXC_INST_ADDR_MISALIGNED &&
                exception.tval == in_packet.pc)
            else $fatal(1, "instruction address exception priority");

        // 非法指令携带原始指令编码作为 tval。
        in_packet.pc = xlen_t'(32'h100);
        #1;
        assert (exception.valid && exception.cause == EXC_ILLEGAL_INST &&
                exception.tval == xlen_t'(in_packet.inst))
            else $fatal(1, "illegal instruction exception");

        // ECALL 与 EBREAK 在 D1 已能确定异常原因。
        uop = '0;
        uop.sys_op = SYS_ECALL;
        #1;
        assert (exception.valid && exception.cause == EXC_ECALL_M)
            else $fatal(1, "ECALL exception");

        uop.sys_op = SYS_EBREAK;
        #1;
        assert (exception.valid && exception.cause == EXC_BREAKPOINT)
            else $fatal(1, "EBREAK exception");

        // JAL 目标在 D1 计算，因此无需推迟到 EX 检查。
        uop = '0;
        uop.branch_op = BR_JAL;
        jal_target = xlen_t'(32'h202);
        #1;
        assert (exception.valid && exception.cause == EXC_INST_ADDR_MISALIGNED &&
                exception.tval == jal_target)
            else $fatal(1, "misaligned JAL target");

        jal_target = xlen_t'(32'h204);
        #1;
        assert (!exception.valid) else $fatal(1, "aligned JAL target");

        $display("PASS tb_d1_exception_check RV%0d", core_config_pkg::XLEN);
        $finish;
    end
endmodule
