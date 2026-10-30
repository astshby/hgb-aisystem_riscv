// Module: soc_all_system
// Description: Simulation-only shared SoC with simultaneous YOLO, MiniMind and optional HDMI scanout.
module soc_all_system #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = "",
    parameter int DDR_BYTES = 128*1024*1024,
    parameter bit VIDEO_ENABLE = 1'b0,
    parameter int ICACHE_BYTES = 16384,
    parameter int DCACHE_BYTES = 8192,
    parameter logic [31:0] CORE_HZ = 90000000,
    parameter logic [31:0] SYS_HZ = 100000000,
    parameter logic [31:0] DDR_HZ = 125000000,
    parameter logic [31:0] PERIPH_HZ = 60000000,
    parameter int MM3_MAC_LANES = mm3_config_pkg::MM3_GEMV_LANES
) (
    input logic clk_core, clk_sys, clk_ddr, clk_periph,
    input logic clk_yolo, clk_minimind, clk_pixel, reset_async, ddr_ready,
    input logic [1:0] uart_rx,
    output logic [1:0] uart_tx,
    input logic [31:0] gpio_in [3],
    output logic [31:0] gpio_out [3], gpio_oe [3],
    output axi_types_pkg::axi_req_t ddr_req,
    input axi_types_pkg::axi_rsp_t ddr_rsp,
    input logic hdmi_sda_in,
    output logic hdmi_scl, hdmi_sda_drive_low, hdmi_reset_n,
    output logic video_hs, video_vs, video_de,
    output logic [23:0] video_rgb,
    output logic [1:0] accelerator_irq,
    output logic commit_valid,
    output logic [core_config_pkg::XLEN-1:0] commit_pc,
    output logic [31:0] commit_inst,
    output logic [4:0] commit_rd,
    output logic commit_rd_we,
    output logic [core_config_pkg::XLEN-1:0] commit_rd_data,
    output logic commit_exception
);
    import axi_types_pkg::*;
    axi_req_t yolo_req, minimind_req, external_req, external_masters [2];
    axi_rsp_t yolo_rsp, minimind_rsp, external_rsp, external_responses [2];
    axil_req_t video_req;
    axil_rsp_t video_rsp;
    logic rst_yolo, rst_minimind, rst_pixel, rst_sys, rst_periph;
    logic [1:0] native_irq;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *)
        logic [1:0] irq_sync1_q, irq_sync2_q;

    // 两核/显示共用复位事件，各自同步释放；不存在只清单侧 FIFO 的局部复位。
    soc_reset_controller u_yolo_reset (
        .reset_async, .clk_core(clk_yolo), .clk_sys, .clk_ddr, .clk_periph,
        .rst_core(rst_yolo), .rst_sys, .rst_ddr(), .rst_periph, .rst_sys_local());
    soc_reset_controller u_minimind_reset (
        .reset_async, .clk_core(clk_minimind), .clk_sys, .clk_ddr, .clk_periph,
        .rst_core(rst_minimind), .rst_sys(), .rst_ddr(), .rst_periph(), .rst_sys_local());
    always_ff @(posedge clk_periph) begin
        if (rst_periph) begin irq_sync1_q <= '0; irq_sync2_q <= '0; end
        else begin irq_sync1_q <= native_irq; irq_sync2_q <= irq_sync1_q; end
    end
    assign accelerator_irq = irq_sync2_q;
    npu_axi_target u_yolo (
        .clk_sys, .rst_sys, .clk_npu(clk_yolo), .rst_npu(rst_yolo),
        .axi_req(yolo_req), .axi_rsp(yolo_rsp), .irq(native_irq[0]));
    mm3_axi_subsystem #(.BASE(soc_addr_pkg::MM3_AXI_BASE), .DDR_BYTES(DDR_BYTES),
        .MAC_LANES(MM3_MAC_LANES)) u_minimind (
        .clk_sys, .rst_sys, .clk_npu(clk_minimind), .rst_npu(rst_minimind),
        .control_req(minimind_req), .control_rsp(minimind_rsp), .irq(native_irq[1]),
        .memory_req(external_masters[0]), .memory_rsp(external_responses[0]));
    if (VIDEO_ENABLE) begin : g_video
        soc_reset_controller u_reset (
            .reset_async, .clk_core(clk_pixel), .clk_sys, .clk_ddr, .clk_periph,
            .rst_core(rst_pixel), .rst_sys(), .rst_ddr(), .rst_periph(), .rst_sys_local());
        yolo_video u_video (
            .clk_sys, .rst_sys, .clk_periph, .rst_periph, .clk_pixel, .rst_pixel,
            .control_req(video_req), .control_rsp(video_rsp),
            .memory_req(external_masters[1]), .memory_rsp(external_responses[1]),
            .hdmi_sda_in, .hdmi_scl, .hdmi_sda_drive_low, .hdmi_reset_n,
            .video_hs, .video_vs, .video_de, .video_rgb);
    end else begin : g_no_video
        assign rst_pixel = 1'b1;
        assign external_masters[1] = '0;
        assign video_rsp = '0;
        assign hdmi_scl = 1'b1;
        assign hdmi_sda_drive_low = 1'b0;
        assign hdmi_reset_n = 1'b0;
        assign video_hs = 1'b0;
        assign video_vs = 1'b0;
        assign video_de = 1'b0;
        assign video_rgb = '0;
    end
    // MiniMind 与扫描口在短突发边界公平轮询，响应反压期间保留归属；
    // 原 fabric 限制每突发最多四拍，不为双核扩宽全局 AXI ID。
    axi_external_arbiter u_external (
        .clk(clk_sys), .rst(rst_sys), .s_req(external_masters), .s_rsp(external_responses),
        .m_req(external_req), .m_rsp(external_rsp));
    soc_system #(.ITCM_INIT_FILE(ITCM_INIT_FILE), .DTCM_INIT_FILE(DTCM_INIT_FILE),
        .DDR_BYTES(DDR_BYTES), .NPU_BYTES(65536), .MM3_BYTES(4096),
        .ACCEL_IRQ_ENABLE(1'b1), .VIDEO_ENABLE(VIDEO_ENABLE),
        .CLOCK_INFO_ENABLE(1'b1), .CORE_CLOCK_HZ(CORE_HZ), .SYS_CLOCK_HZ(SYS_HZ),
        .DDR_CLOCK_HZ(DDR_HZ), .PERIPH_CLOCK_HZ(PERIPH_HZ),
        .UART_DIVISOR((PERIPH_HZ+57600)/115200),
        .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES)) u_soc (
        .clk_core, .clk_sys, .clk_ddr, .clk_periph, .reset_async, .ddr_ready,
        .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .flash_cs_n(), .flash_sck(), .flash_mosi(), .flash_miso(1'b0),
        .ddr_req, .ddr_rsp, .external_req, .external_rsp,
        .npu_req(yolo_req), .npu_rsp(yolo_rsp), .mm3_req(minimind_req), .mm3_rsp(minimind_rsp),
        .accelerator_irq, .video_req, .video_rsp,
        .commit_valid, .commit_pc, .commit_inst, .commit_rd, .commit_rd_we,
        .commit_rd_data, .commit_exception, .commit_trace(),
        .dmem_store_fire(), .dmem_store_addr(), .dmem_store_data(), .dmem_store_strb());
endmodule
