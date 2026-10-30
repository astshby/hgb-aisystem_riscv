// Module: tb_pango_soc_pll
// Description: Measure application and historical clocks using the unmodified vendor GPLL simulation model.
module tb_pango_soc_pll;
    timeunit 1ns;
    timeprecision 1ps;
    parameter int CLOCK_PROFILE = 1;
    parameter bit NPU_ENABLE = 0;
    localparam realtime CORE_PERIOD = CLOCK_PROFILE == 9 ? (800ns / 71.0) :
        (CLOCK_PROFILE == 10 ? (704ns / 59.0) : (CLOCK_PROFILE == 8 ? (110ns / 9.0) :
        ((CLOCK_PROFILE == 5 || CLOCK_PROFILE == 7) ? (100ns / 9.0) : 10ns)));
    localparam realtime SYS_PERIOD = CLOCK_PROFILE == 9 ? (720ns / 71.0) :
        (CLOCK_PROFILE == 10 ? (576ns / 59.0) : (CLOCK_PROFILE == 1 ? 12.5ns : 10ns));
    localparam realtime PERIPH_PERIOD = CLOCK_PROFILE == 9 ? (1040ns / 71.0) :
        (CLOCK_PROFILE == 10 ? (896ns / 59.0) : (CLOCK_PROFILE >= 6 ? (50ns / 3.0) : 40ns));
    localparam realtime NPU_PERIOD = CLOCK_PROFILE == 9 ? (720ns / 71.0) :
        (CLOCK_PROFILE == 10 ? (640ns / 59.0) : 10ns);
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
        measure(0, CORE_PERIOD);
        measure(1, SYS_PERIOD);
        measure(2, PERIPH_PERIOD);
        if (NPU_ENABLE) measure(3, NPU_PERIOD);
        else assert (clk_npu == 0) else $fatal(1, "disabled NPU clock toggled");
        $display("PASS vendor GPLL C%0d: periods core=%0.6f sys=%0.6f periph=%0.6f ns npu=%0.6f MHz",
            CLOCK_PROFILE, CORE_PERIOD, SYS_PERIOD, PERIPH_PERIOD, NPU_ENABLE ? 1000.0/NPU_PERIOD : 0.0);
        $finish;
    end
    initial begin
        #1ms;
        $fatal(1, "vendor PLL model did not lock");
    end
endmodule
