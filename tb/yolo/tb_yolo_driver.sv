// Module: tb_yolo_driver
// Description: Executes the production C tiled driver on the five-clock RV32/RV64 SoC.
module tb_yolo_driver;
    timeunit 1ns;
    timeprecision 1ps;
    tb_soc_system #(
        .NPU_ENABLE(1),
        .FLASH_BYTES(0),
        .CLOCK_PROFILE(7),
        .ICACHE_BYTES(16384),
        .DCACHE_BYTES(8192)
    ) u_test();
endmodule
