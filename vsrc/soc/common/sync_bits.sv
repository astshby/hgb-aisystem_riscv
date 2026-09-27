// Module: sync_bits
// Description: Two-flop input synchronizer for independent asynchronous level signals.
module sync_bits #(
    parameter int WIDTH = 1,
    parameter logic [WIDTH-1:0] RESET_VALUE = '0
) (
    input logic clk, rst,
    input logic [WIDTH-1:0] async_in,
    output logic [WIDTH-1:0] sync_out
);
    // 仅同步独立电平/慢速 GPIO；不能用于跨时钟域数据总线或短脉冲握手。
    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] meta_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            meta_q <= RESET_VALUE;
            sync_out <= RESET_VALUE;
        end else begin
            meta_q <= async_in;
            sync_out <= meta_q;
        end
    end
endmodule
