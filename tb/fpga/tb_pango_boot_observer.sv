// Module: tb_pango_boot_observer
// Description: Check independent/stopped clocks, scalar-event boundaries and asynchronous clears.
module tb_pango_boot_observer #(
    parameter int unsigned PC_WIDTH = 32
);
    timeunit 1ns;
    timeprecision 1ps;
    logic clk_core, clk_sys, clk_periph;
    logic core_running = 1;
    logic board_reset_n = 0, reset_async = 1;
    logic commit_valid = 0, commit_exception = 0, uart_tx = 1;
    logic [PC_WIDTH-1:0] commit_pc = '0;
    logic [6:0] led;
    logic [2:0] seen_high, seen_low;
    logic held_core;
    initial begin
        clk_core = 0;
        forever begin
            #5;
            if (core_running) clk_core = !clk_core;
        end
    end
    initial begin
        clk_sys = 0;
        forever #7 clk_sys = !clk_sys;
    end
    initial begin
        clk_periph = 0;
        forever #11 clk_periph = !clk_periph;
    end
    pango_boot_observer #(.PC_WIDTH(PC_WIDTH), .HEARTBEAT_BITS(3)) dut (.*);

    task automatic check(input logic condition, input string meaning);
        if (!condition) $fatal(1, "%s: led=%b", meaning, led);
    endtask
    task automatic heartbeat_activity;
        seen_high = '0;
        seen_low = '0;
        repeat (80) begin
            @(negedge clk_core);
            seen_high |= led[2:0];
            seen_low |= ~led[2:0];
        end
        check(seen_high == 3'b111 && seen_low == 3'b111, "all three clock heartbeats must change");
    endtask
    task automatic commit_event(input logic valid, input logic exception, input logic [PC_WIDTH-1:0] pc);
        @(negedge clk_core);
        commit_valid = valid;
        commit_exception = exception;
        commit_pc = pc;
        @(negedge clk_core);
        commit_valid = 0;
        commit_exception = 0;
    endtask
    initial begin
        repeat (4) @(negedge clk_core);
        check(led == '0, "board reset clears all observations");
        board_reset_n = 1;
        reset_async = 0;
        heartbeat_activity();
        commit_event(0, 1, PC_WIDTH'(32'h01000020));
        check(led[6:3] == 0, "invalid scalar commit cannot set PC or exception events");
        commit_event(1, 0, PC_WIDTH'(32'h80000000));
        check(led[6:3] == 4'b0001, "ROM retirement alone sets only commit seen");
        commit_event(1, 0, PC_WIDTH'(32'h01000000));
        check(led[6:3] == 4'b0011, "ITCM lower boundary retirement is observed");
        commit_event(1, 1, PC_WIDTH'(32'h0100fffc));
        check(led[6:3] == 4'b1011, "valid scalar exception remains observable");
        @(negedge clk_periph); uart_tx = 0;
        @(negedge clk_periph); uart_tx = 1;
        repeat (3) @(negedge clk_periph);
        check(led[5], "UART low event must remain latched after returning idle");
        @(negedge clk_core); reset_async = 1;
        #1ps;
        check(led[6:3] == 0, "SoC fault asynchronously clears event observations");
        heartbeat_activity();
        reset_async = 0;
        commit_event(1, 0, PC_WIDTH'(32'h01010000));
        check(!led[4], "ITCM upper endpoint is excluded");
        if (PC_WIDTH == 64) begin
            commit_event(1, 0, PC_WIDTH'(64'h0000000101000020));
            check(!led[4], "64-bit high address cannot alias ITCM");
        end
        @(negedge clk_core); core_running = 0; held_core = led[0];
        seen_high = '0; seen_low = '0;
        repeat (80) begin
            @(negedge clk_sys);
            check(led[0] == held_core, "stopped Core clock cannot produce heartbeat");
            seen_high |= led[2:0]; seen_low |= ~led[2:0];
        end
        check(seen_high[2:1] == 2'b11 && seen_low[2:1] == 2'b11, "other domains continue with Core clock stopped");
        board_reset_n = 0;
        #1ps;
        check(led == 0, "board reset clears even a stopped-clock domain");
        $display("PASS pango_boot_observer PC_WIDTH=%0d: independent/held clocks, scalar valid and ITCM range, UART sticky, fault and board reset", PC_WIDTH);
        $finish;
    end
    initial begin
        #100us;
        $fatal(1, "timeout");
    end
endmodule
