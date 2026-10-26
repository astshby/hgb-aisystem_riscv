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
        assert (PREDICTOR_MODE <= 1) else $fatal(1, "invalid predictor mode");
        assert ((`CORE_RAS_ENABLE == 0) || (`CORE_RAS_ENABLE == 1))
            else $fatal(1, "invalid RAS selection");
        // 与 core_build_config.sh 的已支持深度一致，包含当前 P1 的 ROB32。
        assert ((RETIRE_ENTRIES == 2) || (RETIRE_ENTRIES == 4) || (RETIRE_ENTRIES == 8) ||
                (RETIRE_ENTRIES == 16) || (RETIRE_ENTRIES == 32))
            else $fatal(1, "CORE_RETIRE_ENTRIES must be 2, 4, 8, 16, or 32");
        $display("PASS tb_core_config RV%0d", XLEN);
        $finish;
    end
endmodule
