// Module: tb_pango_soc_pll
// Description: Measure C1/C4 periods using the unmodified vendor GPLL simulation model.
module tb_pango_soc_pll;
    timeunit 1ns;
    timeprecision 1ps;
    parameter int CLOCK_PROFILE = 1;
    logic ref_clk = 0, reset_n = 0;
    wire clk_core, clk_sys, clk_periph, locked;
    always #4ns ref_clk = ~ref_clk;
    pango_soc_pll #(.CLOCK_PROFILE(CLOCK_PROFILE)) dut (.*);
    task automatic measure(input int domain, input realtime expected);
        realtime first_edge, period;
        for (int i = 0; i < 10; i++) begin
            case (domain)
                0: @(posedge clk_core);
                1: @(posedge clk_sys);
                2: @(posedge clk_periph);
                default: $fatal(1, "bad domain");
            endcase
            if (i > 0) begin
                period = $realtime - first_edge;
                assert (period >= expected-0.002ns && period <= expected+0.002ns)
                    else $fatal(1, "domain %0d period %0.4f expected %0.4f", domain, period, expected);
            end
            first_edge = $realtime;
        end
    endtask
    initial begin
        repeat (10) @(negedge ref_clk);
        reset_n = 1;
        wait (locked);
        repeat (200) @(negedge ref_clk);
        measure(0, 10ns);
        measure(1, CLOCK_PROFILE == 4 ? 10ns : 12.5ns);
        measure(2, 40ns);
        $display("PASS vendor GPLL C%0d: core=100 sys=%0d periph=25 MHz", CLOCK_PROFILE,
            CLOCK_PROFILE == 4 ? 100 : 80);
        $finish;
    end
    initial begin
        #1ms;
        $fatal(1, "vendor PLL model did not lock");
    end
endmodule
