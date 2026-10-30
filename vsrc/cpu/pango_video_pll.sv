// Module: pango_video_pll
// Description: Independent LOGOS2 PPLL for the board's 27 MHz HDMI reference and 148.5 MHz pixel clock.
module pango_video_pll (
    input logic ref_clk,
    input logic reset_n,
    output wire clk_pixel,
    output wire locked
);
    wire pll_pixel;

    // 同板 HDMI dyn_pll 参数：27/1 *2 *33 =1782 MHz VCO，/12=148.5 MHz。
    // 这里只声明原语参数，不复制厂商 IP。PPLL 独立于系统 GPLL 和 DDR PLL。
    // PLL 自身只由板级复位控制；失锁触发系统协调复位，不反向复位本 PLL。
    GTP_PPLL #(
        .CLKIN_FREQ(27.0), .LOCK_MODE(1'b0),
        .STATIC_RATIOI(1), .STATIC_RATIOM(2), .STATIC_RATIOF(33),
        .STATIC_RATIO0(12), .STATIC_DUTY0(12), .STATIC_DUTYF(33),
        .STATIC_RATIO1(36), .STATIC_DUTY1(36),
        .STATIC_RATIO2(36), .STATIC_DUTY2(36),
        .STATIC_RATIO3(36), .STATIC_DUTY3(36),
        .STATIC_RATIO4(36), .STATIC_DUTY4(36),
        .STATIC_RATIOPHY(36), .STATIC_DUTYPHY(36),
        .INTERNAL_FB("CLKOUTF"), .EXTERNAL_FB("DISABLE"), .BANDWIDTH("LOW")
    ) u_pll (
        .CLKIN1(ref_clk), .CLKIN2(1'b0), .CLKIN_SEL(1'b0), .CLKFB(1'b0),
        .RST(!reset_n), .PLL_PWD(1'b0), .CLKOUT0(pll_pixel), .LOCK(locked),
        .CLKOUT0N(), .CLKOUT1(), .CLKOUT1N(), .CLKOUT2(), .CLKOUT2N(),
        .CLKOUT3(), .CLKOUT3N(), .CLKOUT4(), .CLKOUTPHY(), .CLKOUTPHYN(),
        .CLKOUTF(), .CLKOUTFN(),
        .CLKOUT0_SYN(1'b0), .CLKOUT1_SYN(1'b0), .CLKOUT2_SYN(1'b0),
        .CLKOUT3_SYN(1'b0), .CLKOUT4_SYN(1'b0), .CLKOUTPHY_SYN(1'b0), .CLKOUTF_SYN(1'b0),
        .APB_CLK(1'b0), .APB_RST_N(1'b0), .APB_ADDR(5'b0), .APB_SEL(1'b0),
        .APB_EN(1'b0), .APB_WRITE(1'b0), .APB_WDATA(16'b0), .APB_RDATA(), .APB_READY()
    );
    GTP_CLKBUFG u_pixel_clock (.CLKIN(pll_pixel), .CLKOUT(clk_pixel));
endmodule
