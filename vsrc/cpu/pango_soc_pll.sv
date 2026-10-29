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
    // C1/C4 保留 800 MHz 历史档；C5-C8 共用一颗 900 MHz VCO GPLL。
    // C6: 100/100/60；C7: 90/100/60；C8: (900/11)/100/60 MHz。
    // DDR 用户钟独立为 125 MHz；NPU 输出仍为 100 MHz。各档均待物理验收。
    localparam bit HIGH_VCO = CLOCK_PROFILE >= 5;
    localparam real VCO_RATIOF = HIGH_VCO ? 9.0 : 8.0;
    localparam int unsigned VCO_DUTY = HIGH_VCO ? 9 : 8;
    localparam int unsigned CORE_DIV = CLOCK_PROFILE == 8 ? 11 :
        ((CLOCK_PROFILE == 5 || CLOCK_PROFILE == 7) ? 10 : (HIGH_VCO ? 9 : 8));
    localparam real CORE_RATIO = real'(CORE_DIV);
    localparam int unsigned CORE_DUTY = CORE_DIV;
    localparam int unsigned SYS_DIV = CLOCK_PROFILE == 1 ? 10 : (HIGH_VCO ? 9 : 8);
    localparam int unsigned PERIPH_DIV = CLOCK_PROFILE >= 6 ? 15 : (HIGH_VCO ? 36 : 32);
    localparam int unsigned NPU_DIV = HIGH_VCO ? 9 : 8;
    wire pll_core, pll_sys, pll_periph, pll_npu;

    // 125 / 5 = 25 MHz PFD；25 * 4 * 8/9 = 800/900 MHz VCO。
    // CLKOUTF 内反馈；C6-C8 的 /15 外设输出为 60 MHz，占空比均取 50%。
    // 参数依据 LOGOS2 PLL IP 的公式/检查范围；站点及 DDR IP 共存留给物理实现核对。
    GTP_GPLL #(
        .CLKIN_FREQ(125.0), .STATIC_RATIOI(5), .STATIC_RATIOM(4),
        .STATIC_RATIOF(VCO_RATIOF), .STATIC_DUTYF(VCO_DUTY),
        .STATIC_RATIO0(CORE_RATIO), .STATIC_DUTY0(CORE_DUTY),
        .STATIC_RATIO1(SYS_DIV), .STATIC_DUTY1(SYS_DIV),
        .STATIC_RATIO2(PERIPH_DIV), .STATIC_DUTY2(PERIPH_DIV),
        .STATIC_RATIO3(NPU_DIV), .STATIC_DUTY3(NPU_DIV),
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
    // 独立输出：800 MHz /8 或 900 MHz /9，NPU 均为 100 MHz。
    if (NPU_ENABLE) begin : g_npu_clock
        GTP_CLKBUFG u_clock (.CLKIN(pll_npu), .CLKOUT(clk_npu));
    end else begin : g_no_npu_clock
        assign clk_npu = 1'b0;
    end

    initial begin
        assert (CLOCK_PROFILE == 1 || (CLOCK_PROFILE >= 4 && CLOCK_PROFILE <= 8))
            else $fatal(1, "pango_soc_pll supports C1 and C4-C8 only");
    end
endmodule
