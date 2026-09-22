// Module: tb_core_types
// Description: Checks packed uOp defaults and mutually exclusive SYSTEM classification.
// 用于检查静态代码块
module tb_core_types;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;

    uop_t uop;

    initial begin
        uop = '0;
        assert (uop.sys_op == SYS_NONE) else $fatal(1, "zero uOp must be SYS_NONE");
        uop.sys_op = SYS_ECALL;
        assert (uop.sys_op != SYS_EBREAK && uop.sys_op != SYS_MRET)
            else $fatal(1, "SYSTEM operation must be exclusive");
        $display("PASS tb_core_types");
        $finish;
    end
endmodule
