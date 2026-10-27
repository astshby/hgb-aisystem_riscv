// Module: tb_pango_measure_scan
// Description: Full-bit scan controllability, stable holding and nonintrusive snapshot checks.
module tb_pango_measure_scan;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 0;
    always #5 clk = !clk;
    logic rst = 1, shift = 0, update = 0, capture = 0, serial_in = 0;
    logic serial_out, one_out;
    logic [12:0] drive;
    logic [72:0] observe = 0;
    logic one_drive;
    pango_measure_scan #(.INPUT_BITS(13), .OUTPUT_BITS(73)) dut (
        .clk, .rst, .shift, .update, .capture, .serial_in, .serial_out, .drive, .observe);
    pango_measure_scan one (
        .clk, .rst, .shift, .update, .capture, .serial_in, .serial_out(one_out),
        .drive(one_drive), .observe(observe[0]));
    task automatic load(input logic [12:0] value);
        logic [12:0] previous;
        previous = drive;
        for (int i = 12; i >= 0; i--) begin
            @(negedge clk); shift = 1; serial_in = value[i];
            @(posedge clk); #1;
            assert (drive == previous) else $fatal(1, "shift changed holding value");
        end
        @(negedge clk); shift = 0; update = 1;
        @(posedge clk); #1;
        assert (drive == value && one_drive == value[0]) else $fatal(1, "input serialization mismatch");
        @(negedge clk); update = 0;
    endtask
    task automatic sample(input logic [72:0] value);
        logic [72:0] result;
        logic [12:0] previous;
        previous = drive;
        @(negedge clk); observe = value; capture = 1;
        @(posedge clk); #1;
        assert (one_out == value[0]) else $fatal(1, "single-bit capture mismatch");
        @(negedge clk); capture = 0; observe = ~value;
        for (int i = 72; i >= 0; i--) begin
            result[i] = serial_out;
            shift = 1; serial_in = 0;
            @(posedge clk); #1;
            assert (drive == previous) else $fatal(1, "snapshot read changed DUT input");
            @(negedge clk);
        end
        shift = 0;
        assert (result == value) else $fatal(1, "snapshot changed with live outputs");
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        for (int i = 0; i < 13; i++) load(13'(1) << i);
        for (int i = 0; i < 73; i++) sample(73'(1) << i);
        load(13'h1753);
        // 第二次 update 无需重新移位即可提交清零串，适合握手后立即撤销 valid。
        @(negedge clk); update = 1;
        @(posedge clk); #1;
        assert (drive == 0) else $fatal(1, "update did not clear staging register");
        @(negedge clk); update = 0; shift = 1; capture = 1; observe = 73'h1a56789abcdef;
        @(posedge clk); #1;
        assert (dut.snapshot_q == observe) else $fatal(1, "capture must precede output shift");
        @(negedge clk); shift = 0; capture = 0; rst = 1;
        @(posedge clk); #1;
        assert (drive == 0 && serial_out == 0) else $fatal(1, "scan reset failed");
        $display("PASS tb_pango_measure_scan input_bits=13 output_bits=73 walking_inputs=13 walking_outputs=73 width1=1");
        $finish;
    end
endmodule
