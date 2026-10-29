// Module: pango_soc_reset
// Description: Reference-clock reset supervisor with independent boot and coordinated DDR recovery.
module pango_soc_reset #(
    parameter int unsigned HOLD_CYCLES = 64,
    parameter int unsigned WATCHDOG_CYCLES = 128
) (
    input logic ref_clk,
    input logic clk_ddr,
    input logic board_reset_n,
    input logic soc_pll_locked,
    input logic ddr_pll_locked,
    input logic ddr_phy_locked,
    input logic ddr_ready,
    output logic reset_async,
    output logic ddr_reset_n
);
    localparam int unsigned WATCH_W = $clog2(WATCHDOG_CYCLES + 1);
    logic [HOLD_CYCLES-1:0] hold_q;
    logic ddr_armed_q, fault_async, ddr_healthy, ddr_fault;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [2:0] healthy_sync_q;
    logic [3:0] heartbeat_q;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [2:0] heartbeat_release_q;
    (* ASYNC_REG = "TRUE", PAP_ASYNC_REG = 1, syn_allow_retiming = 0 *) logic [2:0] heartbeat_sync_q;
    logic heartbeat_seen_q;
    logic [WATCH_W-1:0] watchdog_q;

    assign ddr_healthy = ddr_pll_locked && ddr_phy_locked && ddr_ready;
    // 首次启动只等待独立 SoC PLL；DDR 尚未校准不阻止 ROM/TCM/MMIO 执行。
    // DDR 曾就绪后，失锁/撤销 ready/停钟均作整机重启；不保留在途事务。
    assign fault_async = !board_reset_n || !soc_pll_locked;
    // DDR 健康状态先同步到持续运行的参考域；检测后由 hold_q 异步置位各域复位。
    // 不让 armed 的异步清零组合反馈到自身复位请求，避免形成过短的复位脉冲。
    assign ddr_fault = ddr_armed_q &&
        (!healthy_sync_q[2] || watchdog_q == WATCH_W'(WATCHDOG_CYCLES));
    assign reset_async = fault_async || hold_q[HOLD_CYCLES-1];
    assign ddr_reset_n = board_reset_n && !reset_async;

    // 在稳定参考钟上展宽复位，避免 DDR 停钟时无法复位，且清 armed 后不会缩短脉冲。
    always_ff @(posedge ref_clk or posedge fault_async) begin
        if (fault_async) hold_q <= '1;
        else if (ddr_fault) hold_q <= '1;
        else hold_q <= {hold_q[HOLD_CYCLES-2:0], 1'b0};
    end

    // 看门狗计数器也遵循 DDR 域同步释放，停止的时钟不会提前退出复位。
    always_ff @(posedge clk_ddr or posedge reset_async) begin
        if (reset_async) heartbeat_release_q <= '1;
        else heartbeat_release_q <= {heartbeat_release_q[1:0], 1'b0};
    end
    always_ff @(posedge clk_ddr or posedge heartbeat_release_q[2]) begin
        if (heartbeat_release_q[2]) heartbeat_q <= '0;
        else heartbeat_q <= heartbeat_q + 1'b1;
    end
    always_ff @(posedge ref_clk or posedge reset_async) begin
        if (reset_async) begin
            healthy_sync_q <= '0;
            heartbeat_sync_q <= '0;
            heartbeat_seen_q <= 1'b0;
            watchdog_q <= '0;
            ddr_armed_q <= 1'b0;
        end else begin
            healthy_sync_q <= {healthy_sync_q[1:0], ddr_healthy};
            heartbeat_sync_q <= {heartbeat_sync_q[1:0], heartbeat_q[3]};
            heartbeat_seen_q <= heartbeat_sync_q[2];
            if (healthy_sync_q[2]) ddr_armed_q <= 1'b1;
            if (!ddr_armed_q || heartbeat_seen_q != heartbeat_sync_q[2]) watchdog_q <= '0;
            else if (watchdog_q < WATCH_W'(WATCHDOG_CYCLES)) watchdog_q <= watchdog_q + 1'b1;
        end
    end

    initial begin
        assert (HOLD_CYCLES >= 4 && WATCHDOG_CYCLES >= 32)
            else $fatal(1, "reset hold and DDR heartbeat watchdog are too short");
    end
endmodule
