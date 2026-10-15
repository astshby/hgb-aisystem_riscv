// Module: pango_200hp_top
// Description: PG2L200H board wrapper for the portable SoC and Pango DDR3 controller.
module pango_200hp_top #(
    parameter ITCM_INIT_FILE = "",
    parameter DTCM_INIT_FILE = ""
) (
    input logic ref_clk_p, ref_clk_n,
    input logic board_reset_n,
    input logic uart_rxd,
    output logic uart_txd,
    output logic ddr_ready_led,
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
    logic [1:0] uart_rx, uart_tx;
    logic [31:0] gpio_in [3], gpio_out [3], gpio_oe [3];
    logic ddr_req_valid, ddr_req_ready, ddr_rsp_valid, ddr_rsp_ready;
    bus_req_t ddr_request;
    bus_rsp_t ddr_response;
    logic [27:0] axi_awaddr, axi_araddr;
    logic axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_awready;
    logic axi_wready, axi_arvalid, axi_arready, axi_rlast, axi_rvalid;
    logic [3:0] axi_awuser_id, axi_awlen, axi_aruser_id, axi_arlen, axi_rid;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;

    GTP_INBUFDS u_refclk_inbuf (.O(ref_clk), .I(ref_clk_p), .IB(ref_clk_n));

    // DDR 校准成功后同步释放 SoC；参考 IP 的 core_clk 为 125 MHz 用户时钟。
    always_ff @(posedge core_clk or negedge board_reset_n) begin
        if (!board_reset_n) reset_sync_q <= '0;
        else reset_sync_q <= {reset_sync_q[0], pll_lock && phy_pll_lock && ddr_init_done};
    end
    assign soc_rst = !reset_sync_q[1];
    assign ddr_ready_led = reset_sync_q[1];
    assign uart_rx = {1'b1, uart_rxd};
    assign uart_txd = uart_tx[0];
    assign gpio_in[0] = '0;
    assign gpio_in[1] = '0;
    assign gpio_in[2] = '0;

    soc_top #(.ITCM_INIT_FILE(ITCM_INIT_FILE), .DTCM_INIT_FILE(DTCM_INIT_FILE),
              .DDR_BYTES(512 * 1024 * 1024), .CLOCK_HZ(125000000),
              .UART_DIVISOR(1085)) u_soc (
        .clk(core_clk), .rst(soc_rst), .uart_rx, .uart_tx,
        .gpio_in, .gpio_out, .gpio_oe,
        .ddr_req_valid, .ddr_req_ready, .ddr_request,
        .ddr_rsp_valid, .ddr_rsp_ready, .ddr_response,
        .commit_valid(), .commit_pc(), .commit_inst(), .commit_rd(),
        .commit_rd_we(), .commit_rd_data(), .commit_exception(),
        .dmem_store_fire(), .dmem_store_addr(), .dmem_store_data(), .dmem_store_strb()
    );

    pango_ddr3_bridge #(.DDR_BYTES(512 * 1024 * 1024)) u_ddr_bridge (
        .clk(core_clk), .rst(soc_rst),
        .req_valid(ddr_req_valid), .req_ready(ddr_req_ready), .request(ddr_request),
        .rsp_valid(ddr_rsp_valid), .rsp_ready(ddr_rsp_ready), .response(ddr_response),
        .axi_awaddr, .axi_awuser_ap, .axi_awuser_id, .axi_awlen, .axi_awvalid, .axi_awready,
        .axi_wdata, .axi_wstrb, .axi_wready,
        .axi_araddr, .axi_aruser_ap, .axi_aruser_id, .axi_arlen, .axi_arvalid, .axi_arready,
        .axi_rdata, .axi_rid, .axi_rlast, .axi_rvalid
    );

    // 使用 200HP 参考例程的 DDR3 用户接口。需在 PDS 2025.2 用板载颗粒参数重新生成同名 IP。
    ddr3_test I_ips_ddr_top (
        .ref_clk, .resetn(board_reset_n), .core_clk, .pll_lock, .phy_pll_lock,
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
