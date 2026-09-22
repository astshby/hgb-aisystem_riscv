// Module: tb_core_config
// Description: Checks the build-time RV32/RV64 configuration contract.
// tb必须在某个块中运行，常用initial块与$finish搭配
// 用于检查常规core设置
module tb_core_config;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;

    initial begin
        assert ((XLEN == 32) || (XLEN == 64)) else $fatal(1, "invalid XLEN");
        assert (DBUS_BYTES == (XLEN / 8)) else $fatal(1, "invalid data bus width");
        $display("PASS tb_core_config RV%0d", XLEN);
        $finish;
    end
endmodule
