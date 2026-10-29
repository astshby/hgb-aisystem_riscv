// Module: tb_yolo_system
// Description: Checks actual MAC work overlapping an independent DDR DMA transfer.
module tb_yolo_system #(
    parameter int ICACHE_BYTES=16384,
    parameter int DCACHE_BYTES=8192,
    parameter int CLOCK_PROFILE=1
);
    timeunit 1ns;
    timeprecision 1ps;
    tb_soc_system #(.NPU_ENABLE(1),.FLASH_BYTES(0),.CLOCK_PROFILE(CLOCK_PROFILE),
        .ICACHE_BYTES(ICACHE_BYTES),.DCACHE_BYTES(DCACHE_BYTES)) u_test();
    longint unsigned mac_steps=0, mac_dma_overlap=0;
    // 统计真正进入 MAC 的数据，避免把等待 CPU 取结果的 busy 时间算作计算。
    always @(posedge u_test.g_npu.clk_npu) if (!u_test.g_npu.rst_npu) begin
        if (u_test.g_npu.u_npu.u_device.u_npu.u_conv.read_valid_q) begin
            mac_steps++;
            if (u_test.dma_r_pending || u_test.dma_w_pending) mac_dma_overlap++;
        end
    end
    final if (u_test.test_pass) begin
        assert(mac_steps>0 && mac_dma_overlap>0) else $fatal(1,"missing real MAC/DMA overlap");
        $display("PASS YOLO_DMA_MAC RV%0d mac_steps=%0d overlap=%0d",core_config_pkg::XLEN,mac_steps,mac_dma_overlap);
    end
endmodule
