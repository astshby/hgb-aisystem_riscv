// Module: pango_soc_pll
// Description: Static LOGOS2 GPLL profiles for the Core, system and peripheral domains.
module pango_soc_pll #(
    parameter int unsigned CLOCK_PROFILE = 1,
    parameter bit NPU_ENABLE = 0
) (
    input logic ref_clk,
    input logic reset_n,
    output wire clk_core,
    output wire clk_sys,
    output wire clk_periph,
    output wire clk_npu,
    output wire locked
);
    localparam int unsigned SYS_DIV = CLOCK_PROFILE == 4 ? 8 : 10;
    wire pll_core, pll_sys, pll_periph, pll_npu;

    // 125 / 5 = 25 MHz PFD；25 * 4 * 8 = 800 MHz VCO。
    // CLKOUTF 内反馈，ODIV=8/10/32 对应 100/80/25 MHz；C4 仅将 SYS 改为 /8。
    // 参数依据 LOGOS2 PLL IP 的公式/检查范围；站点及 DDR IP 共存留给物理实现核对。
    GTP_GPLL #(
        .CLKIN_FREQ(125.0), .STATIC_RATIOI(5), .STATIC_RATIOM(4),
        .STATIC_RATIOF(8.0), .STATIC_DUTYF(8),
        .STATIC_RATIO0(8.0), .STATIC_DUTY0(8),
        .STATIC_RATIO1(SYS_DIV), .STATIC_DUTY1(SYS_DIV),
        .STATIC_RATIO2(32), .STATIC_DUTY2(32),
        .STATIC_RATIO3(8), .STATIC_DUTY3(8),
        .STATIC_RATIO4(8), .STATIC_DUTY4(8),
        .STATIC_RATIO5(8), .STATIC_DUTY5(8),
        .STATIC_RATIO6(8), .STATIC_DUTY6(8),
        .INTERNAL_FB("CLKOUTF"), .EXTERNAL_FB("DISABLE"), .BANDWIDTH("OPTIMIZED")
    ) u_pll (
        .CLKIN1(ref_clk), .CLKIN2(1'b0), .CLKIN_SEL(1'b0), .CLKFB(1'b0),
        .RST(!reset_n), .PLL_PWD(1'b0),
        .CLKOUT0(pll_core), .CLKOUT1(pll_sys), .CLKOUT2(pll_periph), .LOCK(locked),
        .CLKOUT0N(), .CLKOUT1N(), .CLKOUT2N(), .CLKOUT3(pll_npu), .CLKOUT3N(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKOUTF(), .CLKOUTFN(), .DPS_DONE(),
        .DPS_CLK(1'b0), .DPS_EN(1'b0), .DPS_DIR(1'b0),
        .CLKOUT0_SYN(1'b0), .CLKOUT1_SYN(1'b0), .CLKOUT2_SYN(1'b0),
        .CLKOUT3_SYN(1'b0), .CLKOUT4_SYN(1'b0), .CLKOUT5_SYN(1'b0),
        .CLKOUT6_SYN(1'b0), .CLKOUTF_SYN(1'b0),
        .APB_CLK(1'b0), .APB_RST_N(1'b0), .APB_ADDR(5'b0), .APB_SEL(1'b0),
        .APB_EN(1'b0), .APB_WRITE(1'b0), .APB_WDATA(16'b0), .APB_RDATA(), .APB_READY()
    );
    GTP_CLKBUFG u_core_clock (.CLKIN(pll_core), .CLKOUT(clk_core));
    GTP_CLKBUFG u_sys_clock (.CLKIN(pll_sys), .CLKOUT(clk_sys));
    GTP_CLKBUFG u_periph_clock (.CLKIN(pll_periph), .CLKOUT(clk_periph));
    // 独立输出 /8=100 MHz；保留域边界，Core 后续改分频不要求 NPU 跟随。
    if (NPU_ENABLE) begin : g_npu_clock
        GTP_CLKBUFG u_clock (.CLKIN(pll_npu), .CLKOUT(clk_npu));
    end else begin : g_no_npu_clock
        assign clk_npu = 1'b0;
    end

    initial begin
        assert (CLOCK_PROFILE == 1 || CLOCK_PROFILE == 4)
            else $fatal(1, "pango_soc_pll supports C1 and C4 only");
    end
endmodule
