// Module: tb_pango_soc_pll
// Description: Measure C1/C4 and optional NPU periods using the unmodified vendor GPLL simulation model.
module tb_pango_soc_pll;
    timeunit 1ns;
    timeprecision 1ps;
    parameter int CLOCK_PROFILE = 1;
    parameter bit NPU_ENABLE = 0;
    logic ref_clk = 0, reset_n = 0;
    wire clk_core, clk_sys, clk_periph, clk_npu, locked;
    always #4ns ref_clk = ~ref_clk;
    pango_soc_pll #(.CLOCK_PROFILE(CLOCK_PROFILE), .NPU_ENABLE(NPU_ENABLE)) dut (.*);
    task automatic measure(input int domain, input realtime expected);
        realtime first_edge, period;
        for (int i = 0; i < 10; i++) begin
            case (domain)
                0: @(posedge clk_core);
                1: @(posedge clk_sys);
                2: @(posedge clk_periph);
                3: @(posedge clk_npu);
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
        if (NPU_ENABLE) measure(3, 10ns);
        else assert (clk_npu == 0) else $fatal(1, "disabled NPU clock toggled");
        $display("PASS vendor GPLL C%0d: core=100 sys=%0d periph=25 npu=%0d MHz", CLOCK_PROFILE,
            CLOCK_PROFILE == 4 ? 100 : 80, NPU_ENABLE ? 100 : 0);
        $finish;
    end
    initial begin
        #1ms;
        $fatal(1, "vendor PLL model did not lock");
    end
endmodule
