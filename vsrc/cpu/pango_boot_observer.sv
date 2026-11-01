// Module: pango_boot_observer
// Description: Independent board-clock heartbeats and sticky scalar commit/UART observations.
module pango_boot_observer #(
    parameter int unsigned PC_WIDTH = 32,
    parameter int unsigned HEARTBEAT_BITS = 26
) (
    input logic clk_core, clk_sys, clk_periph,
    input logic board_reset_n, reset_async,
    input logic commit_valid, commit_exception,
    input logic [PC_WIDTH-1:0] commit_pc,
    input logic uart_tx,
    output logic [6:0] led
);
    timeunit 1ns;
    timeprecision 1ps;
    logic [HEARTBEAT_BITS-1:0] core_count, sys_count, periph_count;
    logic commit_seen, itcm_seen, exception_seen, uart_low_seen;
    wire event_reset = reset_async || !board_reset_n;

    // 心跳只由板级按键清零；SoC故障复位期间仍可判断各时钟是否在运行。
    always_ff @(posedge clk_core or negedge board_reset_n) begin
        if (!board_reset_n) core_count <= '0;
        else core_count <= core_count + 1'b1;
    end
    always_ff @(posedge clk_sys or negedge board_reset_n) begin
        if (!board_reset_n) sys_count <= '0;
        else sys_count <= sys_count + 1'b1;
    end
    always_ff @(posedge clk_periph or negedge board_reset_n) begin
        if (!board_reset_n) periph_count <= '0;
        else periph_count <= periph_count + 1'b1;
    end

    // 仅采样SoC已有标量提交口；不将它解释成双发射全部退休事件或主程序完成。
    always_ff @(posedge clk_core or posedge event_reset) begin
        if (event_reset) begin
            commit_seen <= 1'b0;
            itcm_seen <= 1'b0;
            exception_seen <= 1'b0;
        end else if (commit_valid) begin
            commit_seen <= 1'b1;
            if (commit_pc >= PC_WIDTH'(32'h01000000) &&
                commit_pc < PC_WIDTH'(32'h01010000)) itcm_seen <= 1'b1;
            if (commit_exception) exception_seen <= 1'b1;
        end
    end

    // UART输出属于外设域；见到低电平仅证明内部发送引脚活动，不证明有效帧或电脑接收。
    always_ff @(posedge clk_periph or posedge event_reset) begin
        if (event_reset) uart_low_seen <= 1'b0;
        else if (!uart_tx) uart_low_seen <= 1'b1;
    end
    // LED1/2/3为Core/SYS/外设心跳，LED4/5/6/7为提交、ITCM、UART低电平、提交异常。
    assign led = {exception_seen, uart_low_seen, itcm_seen, commit_seen,
        periph_count[HEARTBEAT_BITS-1], sys_count[HEARTBEAT_BITS-1], core_count[HEARTBEAT_BITS-1]};
endmodule
