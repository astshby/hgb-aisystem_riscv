// Module: tb_mm3_layer_soc
// Description: Real CPU, cache, existing DDR fabric and all-operator MMIO driver; one-token program.
module tb_mm3_layer_soc #(parameter bit ACCEL_ENABLE=1);
    timeunit 1ns;timeprecision 1ps;
    tb_mm3_soc #(.OP_PROGRAM(1),.MM3_ACCEL_ENABLE(ACCEL_ENABLE),.DDR_BYTES(mm3_config_pkg::MM3_DDR_BYTES),.DMA_WIDE_ENABLE(1),.DMA_BLOCK_ENABLE(1),.CACHE_BLOCK_ENABLE(1),.MM3_MAC_LANES(mm3_config_pkg::MM3_GEMV_LANES)) u_test();
endmodule
