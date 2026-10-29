// Module: tb_pango_video_pll
// Description: Measure the unmodified vendor PPLL model and exercise coordinated reset on video clock health loss.
module tb_pango_video_pll;
    timeunit 1ns;
    timeprecision 1ps;
    localparam realtime PIXEL_PERIOD = 1s / 148500000.0;
    logic ref_clk = 0, sys_clk = 0, periph_clk = 0, reset_n = 0;
    logic inject_lock_fault = 0;
    wire clk_pixel, locked, reset_async, ddr_reset_n;
    wire rst_pixel, rst_sys, rst_periph;

    always #5ns sys_clk = ~sys_clk;
    always #(1s/120000000.0) periph_clk = ~periph_clk;
    initial begin
        realtime origin;
        longint unsigned edge_count;
        origin = 1ns;
        edge_count = 0;
        #1ns;
        forever begin
            edge_count++;
            #(origin + real'(edge_count)*(1s/54000000.0)-$realtime);
            ref_clk = ~ref_clk;
        end
    end
    pango_video_pll dut (.ref_clk, .reset_n, .clk_pixel, .locked);
    // fault 注入位只作用于系统健康输入，不 force 厂商原语，也不复位 PPLL。
    pango_soc_reset #(.HOLD_CYCLES(8), .WATCHDOG_CYCLES(128)) u_supervisor (
        .ref_clk(sys_clk), .clk_ddr(sys_clk), .board_reset_n(reset_n),
        .soc_pll_locked(locked && !inject_lock_fault), .ddr_pll_locked(1'b1),
        .ddr_phy_locked(1'b1), .ddr_ready(1'b1), .reset_async, .ddr_reset_n);
    soc_reset_controller u_release (
        .clk_core(clk_pixel), .clk_sys(sys_clk), .clk_ddr(sys_clk), .clk_periph(periph_clk),
        .reset_async, .rst_core(rst_pixel), .rst_sys, .rst_ddr(), .rst_periph, .rst_sys_local());

    task automatic measure;
        realtime last_edge, actual_period, first_edge;
        @(posedge clk_pixel);
        first_edge = $realtime;
        last_edge = $realtime;
        for (int edge_number = 0; edge_number < 1000; edge_number++) begin
            @(posedge clk_pixel);
            actual_period = $realtime-last_edge;
            assert (actual_period > PIXEL_PERIOD-0.002ns && actual_period < PIXEL_PERIOD+0.002ns)
                else $fatal(1,"PPLL period=%0.6f expected=%0.6f",actual_period,PIXEL_PERIOD);
            last_edge = $realtime;
        end
        $display("VIDEO_PLL measured_edges=1000 mean_period_ns=%0.9f frequency_MHz=%0.6f",
            ($realtime-first_edge)/1000.0, 1000000.0/($realtime-first_edge));
    endtask
    initial begin
        repeat (10) @(negedge ref_clk);
        reset_n = 1;
        wait (locked && !reset_async && !rst_pixel && !rst_sys && !rst_periph);
        measure();
        @(negedge sys_clk);
        inject_lock_fault = 1;
        #1ps;
        assert (reset_async && rst_pixel && rst_sys && rst_periph && !ddr_reset_n)
            else $fatal(1,"video loss did not reset all interface owners");
        repeat (8) @(negedge sys_clk);
        assert (locked) else $fatal(1,"system reset fed back to PPLL");
        inject_lock_fault = 0;
        wait (!reset_async && !rst_pixel && !rst_sys && !rst_periph);
        measure();
        @(negedge ref_clk);
        reset_n = 0;
        repeat (10) @(negedge ref_clk);
        reset_n = 1;
        wait (locked && !reset_async && !rst_pixel && !rst_sys && !rst_periph);
        measure();
        $display("PASS vendor PPLL 27MHz -> 148.5MHz periods=3000 video_health_recovery=1 board_reset_relock=1");
        $finish;
    end
    initial begin
        #1ms;
        $fatal(1,"vendor PPLL/reset test timeout");
    end
endmodule
