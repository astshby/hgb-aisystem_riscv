// Module: pango_200hp_top
// Description: PG2L200H board wrapper for the portable SoC and Pango DDR3 controller.
module pango_200hp_top #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = "",
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter int unsigned BOARD_CLOCK_PROFILE = 0,
    parameter bit NPU_ENABLE = 0,
    parameter bit VIDEO_ENABLE = NPU_ENABLE,
    parameter bit MM3_ENABLE = 0,
    parameter int unsigned ICACHE_BYTES = 4096,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter bit DMA_WIDE_ENABLE = 1'b1,
    parameter bit DMA_BLOCK_ENABLE = 1'b1,
    parameter bit CACHE_BLOCK_ENABLE = 1'b1
) (
    input logic ref_clk_p, ref_clk_n,
    input logic board_reset_n,
    input logic video_ref_clk,
    input logic uart_rxd,
    output logic uart_txd,
    output logic ddr_ready_led,
    output logic hdmi_pixel_clk, hdmi_hs, hdmi_vs, hdmi_de,
    output logic [23:0] hdmi_rgb,
    output logic hdmi_reset_n, hdmi_scl,
    inout wire hdmi_sda,
    output logic mem_cs_n, mem_rst_n, mem_ck, mem_ck_n, mem_cke,
    output logic mem_ras_n, mem_cas_n, mem_we_n, mem_odt,
    output logic [14:0] mem_a,
    output logic [2:0] mem_ba,
    inout wire [3:0] mem_dqs, mem_dqs_n,
    inout wire [31:0] mem_dq,
    output logic [3:0] mem_dm
);
    import bus_types_pkg::*;

    logic ref_clk, core_clk, pll_lock, phy_pll_lock, ddr_init_done;
    logic [1:0] reset_sync_q;
    logic soc_rst;
    wire hot_clk, sys_clk, periph_clk, npu_clk;
    logic ddr_reset_n, ddr_bridge_rst;
    wire video_clk, video_pll_locked;
    // 频率发现和 UART 分频必须跟随 PLL。C8 的整数 Hz 元数据四舍五入，
    // 硬件实际 Core 为 900 MHz /11；约束使用精确分数，不以元数据代替 PLL。
    localparam int unsigned HOT_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 :
        (BOARD_CLOCK_PROFILE == 8 ? 81818182 :
        ((BOARD_CLOCK_PROFILE == 5 || BOARD_CLOCK_PROFILE == 7) ? 90000000 : 100000000));
    localparam int unsigned SYS_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 :
        (BOARD_CLOCK_PROFILE >= 4 ? 100000000 : 80000000);
    localparam int unsigned PERIPH_HZ = BOARD_CLOCK_PROFILE == 0 ? 125000000 :
        (BOARD_CLOCK_PROFILE >= 6 ? 60000000 : 25000000);
    logic [1:0] uart_rx, uart_tx;
    logic [31:0] gpio_in [3], gpio_out [3], gpio_oe [3];
    logic ddr_req_valid, ddr_req_ready, ddr_rsp_valid, ddr_rsp_ready;
    bus_req_t ddr_request;
    bus_rsp_t ddr_response;
    logic dma_wide_req_valid, dma_wide_req_ready, dma_wide_rsp_valid, dma_wide_rsp_ready;
    ddr_req_t dma_wide_request;
    ddr_rsp_t dma_wide_response;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready;
    logic [1:0] cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_types_pkg::block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_types_pkg::block_r_t cache_rd_data [2];
    block_types_pkg::block_w_t cache_wr_data [2];
    block_types_pkg::block_b_t cache_wr_rsp [2];
    logic dma_block_rd_cmd_valid, dma_block_rd_cmd_ready, dma_block_rd_valid, dma_block_rd_ready;
    logic dma_block_wr_cmd_valid, dma_block_wr_cmd_ready, dma_block_wr_valid, dma_block_wr_ready;
    logic dma_block_wr_rsp_valid, dma_block_wr_rsp_ready;
    block_types_pkg::block_cmd_t dma_block_rd_cmd, dma_block_wr_cmd;
    block_types_pkg::block_r_t dma_block_rd_data;
    block_types_pkg::block_w_t dma_block_wr_data;
    block_types_pkg::block_b_t dma_block_wr_rsp;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_types_pkg::block_cmd_t rd_cmd, wr_cmd;
    block_types_pkg::block_r_t rd_data;
    block_types_pkg::block_w_t wr_data;
    block_types_pkg::block_b_t wr_rsp;
    logic [27:0] axi_awaddr, axi_araddr;
    logic axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_awready;
    logic axi_wready, axi_arvalid, axi_arready, axi_rlast, axi_rvalid;
    logic [3:0] axi_awuser_id, axi_awlen, axi_aruser_id, axi_arlen, axi_rid;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;

    GTP_INBUFDS u_refclk_inbuf (.O(ref_clk), .I(ref_clk_p), .IB(ref_clk_n));

    if (VIDEO_ENABLE) begin : g_video_clock
        pango_video_pll u_video_pll (.ref_clk(video_ref_clk), .reset_n(board_reset_n),
            .clk_pixel(video_clk), .locked(video_pll_locked));
        assign hdmi_pixel_clk = video_clk;
    end else begin : g_no_video_clock
        assign video_clk = 1'b0;
        assign video_pll_locked = 1'b1;
        assign hdmi_pixel_clk = 1'b0;
    end

    // Profile 0 保留已记录的同钟平台；独立域档使用系统 GPLL，允许 DDR 校准前启动。
    // DDR IP 端口名 core_clk 仍表示 DDR 用户钟，勿与 Core 热域 hot_clk 混同。
    generate
        if (BOARD_CLOCK_PROFILE == 0) begin : g_common_clock
            assign hot_clk = core_clk;
            assign sys_clk = core_clk;
            assign periph_clk = core_clk;
            assign npu_clk = core_clk;
            always_ff @(posedge core_clk or negedge board_reset_n) begin
                if (!board_reset_n) reset_sync_q <= '0;
                else reset_sync_q <= {reset_sync_q[0], pll_lock && phy_pll_lock && ddr_init_done && video_pll_locked};
            end
            assign soc_rst = !reset_sync_q[1];
            assign ddr_reset_n = board_reset_n;
            assign ddr_bridge_rst = soc_rst;
        end else begin : g_domain_clocks
            wire soc_pll_locked;
            pango_soc_pll #(.CLOCK_PROFILE(BOARD_CLOCK_PROFILE),.NPU_ENABLE(NPU_ENABLE || MM3_ENABLE)) u_soc_pll (
                .ref_clk, .reset_n(board_reset_n), .clk_core(hot_clk), .clk_sys(sys_clk),
                .clk_periph(periph_clk), .clk_npu(npu_clk), .locked(soc_pll_locked));
            pango_soc_reset u_reset (
                .ref_clk, .clk_ddr(core_clk), .board_reset_n,
                .soc_pll_locked(soc_pll_locked && video_pll_locked),
                .ddr_pll_locked(pll_lock), .ddr_phy_locked(phy_pll_lock), .ddr_ready(ddr_init_done),
                .reset_async(soc_rst), .ddr_reset_n);
            // 与 soc_system 内部 DDR 端口同时异步置位、同域三拍释放，防止只清 FIFO 一侧。
            soc_reset_controller u_bridge_reset (
                .clk_core(hot_clk), .clk_sys(sys_clk), .clk_ddr(core_clk), .clk_periph(periph_clk),
                .reset_async(soc_rst), .rst_core(), .rst_sys(), .rst_ddr(ddr_bridge_rst), .rst_periph(), .rst_sys_local());
            assign reset_sync_q = '0;
        end
    endgenerate
    initial begin
        assert (!MM3_ENABLE) else $fatal(1,"MiniMind unavailable in the YOLO experiment");
        assert (BOARD_CLOCK_PROFILE == 0 || BOARD_CLOCK_PROFILE == 1 ||
                (BOARD_CLOCK_PROFILE >= 4 && BOARD_CLOCK_PROFILE <= 8))
            else $fatal(1, "unsupported board clock profile");
        assert (!(NPU_ENABLE || MM3_ENABLE) || BOARD_CLOCK_PROFILE != 0)
            else $fatal(1, "NPU requires its dedicated system GPLL output");
        assert (!VIDEO_ENABLE || BOARD_CLOCK_PROFILE != 0)
            else $fatal(1, "video requires the independent scoreboard SoC clocks");
`ifndef CORE_SCOREBOARD
        assert (BOARD_CLOCK_PROFILE == 0)
            else $fatal(1, "independent domains require soc_system");
        assert (!VIDEO_ENABLE) else $fatal(1, "video requires soc_system");
`endif
    end
    assign ddr_ready_led = ddr_init_done && !soc_rst;
    assign uart_rx = {1'b1, uart_rxd};
    assign uart_txd = uart_tx[0];
    assign gpio_in[0] = '0;
    assign gpio_in[1] = '0;
    assign gpio_in[2] = '0;

`ifdef CORE_SCOREBOARD
    axi_types_pkg::axi_req_t unified_ddr_req;
    axi_types_pkg::axi_rsp_t unified_ddr_rsp;
    axi_types_pkg::axi_req_t npu_req;
    axi_types_pkg::axi_rsp_t npu_rsp;
    axi_types_pkg::axi_req_t external_req;
    axi_types_pkg::axi_rsp_t external_rsp;
    axi_types_pkg::axil_req_t video_req;
    axi_types_pkg::axil_rsp_t video_rsp;
    if (VIDEO_ENABLE) begin : g_video
        logic rst_video, rst_video_sys, rst_video_periph;
        logic sda_drive_low;
        // PPLL 失锁走同一个 soc_rst，三个 FIFO 域一起异步置位、各自三拍释放。
        soc_reset_controller u_reset (.reset_async(soc_rst),.clk_core(video_clk),.clk_sys(sys_clk),
            .clk_ddr(core_clk),.clk_periph(periph_clk),.rst_core(rst_video),.rst_sys(rst_video_sys),
            .rst_ddr(),.rst_periph(rst_video_periph),.rst_sys_local());
        yolo_video #(.PERIPH_HZ(PERIPH_HZ)) u_video (
            .clk_sys(sys_clk),.rst_sys(rst_video_sys),.clk_periph(periph_clk),.rst_periph(rst_video_periph),
            .clk_pixel(video_clk),.rst_pixel(rst_video),.control_req(video_req),.control_rsp(video_rsp),
            .memory_req(external_req),.memory_rsp(external_rsp),.hdmi_sda_in(hdmi_sda),
            .hdmi_scl,.hdmi_sda_drive_low(sda_drive_low),.hdmi_reset_n,
            .video_hs(hdmi_hs),.video_vs(hdmi_vs),.video_de(hdmi_de),.video_rgb(hdmi_rgb));
        assign hdmi_sda = sda_drive_low ? 1'b0 : 1'bz;
    end else begin : g_no_video
        assign external_req = '0;
        assign video_rsp = '0;
        assign hdmi_sda = 1'bz;
        assign hdmi_scl = 1'b1;
        assign hdmi_reset_n = 1'b0;
        assign hdmi_hs = 1'b0;
        assign hdmi_vs = 1'b0;
        assign hdmi_de = 1'b0;
        assign hdmi_rgb = '0;
    end
    if (NPU_ENABLE) begin : g_npu
        logic rst_npu, rst_npu_sys;
        // FIFO两端与SoC共用故障复位事件，各自在目的域同步释放。
        soc_reset_controller u_reset (.reset_async(soc_rst),.clk_core(npu_clk),.clk_sys(sys_clk),
            .clk_ddr(core_clk),.clk_periph(periph_clk),.rst_core(rst_npu),.rst_sys(rst_npu_sys),
            .rst_ddr(),.rst_periph(),.rst_sys_local());
        npu_axi_target u_target (.clk_sys(sys_clk),.rst_sys(rst_npu_sys),.clk_npu(npu_clk),.rst_npu,
            .axi_req(npu_req),.axi_rsp(npu_rsp));
    end else begin : g_no_npu
        assign npu_rsp = '0;
    end
    // C1/C4 的 PLL/复位 RTL 与仿真不代表板上时序验收；Flash 管脚仍待板级接入。
    soc_system #(.ITCM_INIT_FILE(ITCM_INIT_FILE),.DTCM_INIT_FILE(DTCM_INIT_FILE),
        .VIDEO_ENABLE(VIDEO_ENABLE),
        .ICACHE_BYTES(ICACHE_BYTES),.DCACHE_BYTES(DCACHE_BYTES),
        .SOC_PROFILE(SOC_PROFILE),.DDR_BYTES(512*1024*1024),.NPU_BYTES((NPU_ENABLE || MM3_ENABLE) ? 65536 : 0),.CLOCK_HZ(125000000),
        .CLOCK_INFO_ENABLE(BOARD_CLOCK_PROFILE != 0), .CORE_CLOCK_HZ(HOT_HZ), .SYS_CLOCK_HZ(SYS_HZ),
        .DDR_CLOCK_HZ(125000000), .PERIPH_CLOCK_HZ(PERIPH_HZ), .UART_DIVISOR((PERIPH_HZ+57600)/115200)) u_soc (
        .clk_core(hot_clk),.clk_sys(sys_clk),.clk_ddr(core_clk),.clk_periph(periph_clk),.reset_async(soc_rst),.ddr_ready(ddr_init_done),
        .uart_rx,.uart_tx,.gpio_in,.gpio_out,.gpio_oe,
        .flash_cs_n(),.flash_sck(),.flash_mosi(),.flash_miso(1'b0),
        .ddr_req(unified_ddr_req),.ddr_rsp(unified_ddr_rsp),.external_req,.external_rsp,.npu_req,.npu_rsp,
        .video_req,.video_rsp,
        .commit_valid(),.commit_pc(),.commit_inst(),.commit_rd(),.commit_rd_we(),.commit_rd_data(),
        .commit_exception(),.commit_trace(),.dmem_store_fire(),.dmem_store_addr(),.dmem_store_data(),.dmem_store_strb());
    ddr_axi_target u_ddr_target (.clk(core_clk),.rst(ddr_bridge_rst),.memory_ready(ddr_init_done),
        .axi_req(unified_ddr_req),.axi_rsp(unified_ddr_rsp),
        .rd_cmd_valid,.rd_cmd_ready,.rd_cmd,.rd_valid,.rd_ready,.rd_data,
        .wr_cmd_valid,.wr_cmd_ready,.wr_cmd,.wr_valid,.wr_ready,.wr_data,.wr_rsp_valid,.wr_rsp_ready,.wr_rsp);
`else
    assign hdmi_sda = 1'bz;
    assign hdmi_scl = 1'b1;
    assign hdmi_reset_n = 1'b0;
    assign hdmi_hs = 1'b0;
    assign hdmi_vs = 1'b0;
    assign hdmi_de = 1'b0;
    assign hdmi_rgb = '0;
    soc_top #(.ITCM_INIT_FILE(ITCM_INIT_FILE), .DTCM_INIT_FILE(DTCM_INIT_FILE),
              .SOC_PROFILE(SOC_PROFILE), .LOCAL_TCM_ENABLE(LOCAL_TCM_ENABLE),
              .DDR_BYTES(512 * 1024 * 1024), .DMA_WIDE_ENABLE(DMA_WIDE_ENABLE), .DMA_BLOCK_ENABLE(DMA_BLOCK_ENABLE),
              .CACHE_BLOCK_ENABLE(CACHE_BLOCK_ENABLE), .CLOCK_HZ(125000000),
              .UART_DIVISOR(1085)) u_soc (
        .clk(core_clk), .rst(soc_rst), .uart_rx, .uart_tx,
        .gpio_in, .gpio_out, .gpio_oe,
        .ddr_req_valid, .ddr_req_ready, .ddr_request,
        .ddr_rsp_valid, .ddr_rsp_ready, .ddr_response,
        .dma_wide_req_valid, .dma_wide_req_ready, .dma_wide_request,
        .dma_wide_rsp_valid, .dma_wide_rsp_ready, .dma_wide_response,
        .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
        .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
        .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp,
        .dma_block_rd_cmd_valid, .dma_block_rd_cmd_ready, .dma_block_rd_cmd,
        .dma_block_rd_valid, .dma_block_rd_ready, .dma_block_rd_data,
        .dma_block_wr_cmd_valid, .dma_block_wr_cmd_ready, .dma_block_wr_cmd,
        .dma_block_wr_valid, .dma_block_wr_ready, .dma_block_wr_data,
        .dma_block_wr_rsp_valid, .dma_block_wr_rsp_ready, .dma_block_wr_rsp,
        .commit_valid(), .commit_pc(), .commit_inst(), .commit_rd(),
        .commit_rd_we(), .commit_rd_data(), .commit_exception(), .commit_trace(),
        .dmem_store_fire(), .dmem_store_addr(), .dmem_store_data(), .dmem_store_strb()
    );

    // 窄访问、I/D行及DMA共用真实DDR；每方向独立owner，Cache自身仍等脏写回完成后才读。
    ddr_block_fabric #(.DDR_BYTES(512 * 1024 * 1024)) u_ddr_port (
        .clk(core_clk), .rst(soc_rst),
        .cpu_req_valid(ddr_req_valid), .cpu_req_ready(ddr_req_ready), .cpu_request(ddr_request),
        .cpu_rsp_valid(ddr_rsp_valid), .cpu_rsp_ready(ddr_rsp_ready), .cpu_response(ddr_response),
        .dma_req_valid(dma_wide_req_valid), .dma_req_ready(dma_wide_req_ready), .dma_request(dma_wide_request),
        .dma_rsp_valid(dma_wide_rsp_valid), .dma_rsp_ready(dma_wide_rsp_ready), .dma_response(dma_wide_response),
        .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
        .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
        .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp,
        .dma_block_rd_cmd_valid, .dma_block_rd_cmd_ready, .dma_block_rd_cmd,
        .dma_block_rd_valid, .dma_block_rd_ready, .dma_block_rd_data,
        .dma_block_wr_cmd_valid, .dma_block_wr_cmd_ready, .dma_block_wr_cmd,
        .dma_block_wr_valid, .dma_block_wr_ready, .dma_block_wr_data,
        .dma_block_wr_rsp_valid, .dma_block_wr_rsp_ready, .dma_block_wr_rsp,
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
    );
`endif
    pango_block_bridge #(.DDR_BYTES(512 * 1024 * 1024)) u_ddr_bridge (
        .clk(core_clk), .rst(ddr_bridge_rst),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp,
        .axi_awaddr, .axi_awuser_ap, .axi_awuser_id, .axi_awlen, .axi_awvalid, .axi_awready,
        .axi_wdata, .axi_wstrb, .axi_wready,
        .axi_araddr, .axi_aruser_ap, .axi_aruser_id, .axi_arlen, .axi_arvalid, .axi_arready,
        .axi_rdata, .axi_rid, .axi_rlast, .axi_rvalid
    );

    // 使用 200HP 参考例程的 DDR3 用户接口。需在 PDS 2025.2 用板载颗粒参数重新生成同名 IP。
    ddr3_test I_ips_ddr_top (
        .ref_clk, .resetn(ddr_reset_n), .core_clk, .pll_lock, .phy_pll_lock,
        .gpll_lock(), .rst_gpll_lock(), .ddrphy_cpd_lock(), .ddr_init_done,
        .axi_awaddr, .axi_awuser_ap, .axi_awuser_id, .axi_awlen, .axi_awready, .axi_awvalid,
        .axi_wdata, .axi_wstrb, .axi_wready, .axi_wusero_id(), .axi_wusero_last(),
        .axi_araddr, .axi_aruser_ap, .axi_aruser_id, .axi_arlen, .axi_arready, .axi_arvalid,
        .axi_rdata, .axi_rid, .axi_rlast, .axi_rvalid,
        .apb_clk(1'b0), .apb_rst_n(1'b0), .apb_sel(1'b0), .apb_enable(1'b0),
        .apb_addr(8'b0), .apb_write(1'b0), .apb_ready(),
        .apb_wdata(16'b0), .apb_rdata(),
        .mem_cs_n, .mem_rst_n, .mem_ck, .mem_ck_n, .mem_cke,
        .mem_ras_n, .mem_cas_n, .mem_we_n, .mem_odt,
        .mem_a, .mem_ba, .mem_dqs, .mem_dqs_n, .mem_dq, .mem_dm,
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0),
        .dbg_ddrphy_rst_n(1'b1), .dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0), .init_samp_position_even(32'b0),
        .init_samp_position_odd(32'b0), .wrcal_position_dyn_adj(1'b0),
        .init_wrcal_position(32'b0), .force_read_clk_ctrl(1'b0),
        .init_slip_step(16'b0), .init_read_clk_ctrl(12'b0),
        .debug_calib_ctrl(), .dbg_slice_status(), .dbg_slice_state(),
        .debug_data(), .dbg_dll_upd_state(), .debug_gpll_dps_phase(),
        .dbg_rst_dps_state(), .dbg_tran_err_rst_cnt(), .dbg_ddrphy_init_fail(),
        .debug_cpd_offset_adj(1'b0), .debug_cpd_offset_dir(1'b0),
        .debug_cpd_offset(10'b0), .debug_dps_cnt_dir0(), .debug_dps_cnt_dir1(),
        .ck_dly_en(1'b1), .init_ck_dly_step(8'b0), .ck_dly_set_bin(),
        .align_error(), .debug_rst_state(), .debug_cpd_state()
    );
endmodule
