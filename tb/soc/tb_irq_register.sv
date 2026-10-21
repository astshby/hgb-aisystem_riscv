// Module: tb_irq_register
// Description: Checks one-cycle same-clock interrupt assertion, clearing, and reset.
module tb_irq_register;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 1'b0, rst = 1'b1;
    logic [2:0] device_pending = '0, core_pending;
    logic [2:0] previous;
    always #5 clk = ~clk;
    irq_register dut (.*);
    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int n = 0; n < 16; n++) begin
            previous = core_pending;
            device_pending = 3'(n ^ (n >> 1));
            #1;
            assert (core_pending == previous) else $fatal(1, "IRQ combinational bypass");
            @(posedge clk);
            #1;
            assert (core_pending == device_pending) else $fatal(1, "IRQ sample delayed or lost");
            @(negedge clk);
        end
        device_pending = 3'b111;
        @(posedge clk);
        #1;
        assert (core_pending == 3'b111) else $fatal(1, "IRQ assertion before reset failed");
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        assert (core_pending == '0) else $fatal(1, "IRQ reset failed");
        $display("PASS tb_irq_register combinations=16 reset=1");
        $finish;
    end
endmodule
