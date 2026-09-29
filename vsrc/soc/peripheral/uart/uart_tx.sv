// Module: uart_tx
// Description: Clock-enable 8N1 transmitter; divisor is captured for each frame.
module uart_tx (
    input logic clk, rst,
    input logic start,
    input logic [7:0] data,
    input logic [31:0] divisor,
    output logic ready, tx
);
    logic [9:0] shift_q;
    logic [3:0] bits_q;
    logic [31:0] divider_q, ticks_q;
    assign ready = bits_q == 0;
    assign tx = ready ? 1'b1 : shift_q[0];

    // 不产生新时钟；整个串口使用系统时钟和计数使能，避免引入额外时钟域。
    always_ff @(posedge clk) begin
        if (rst) begin
            shift_q <= '1;
            bits_q <= '0;
            divider_q <= 32'd4;
            ticks_q <= '0;
        end else if (start && ready) begin
            shift_q <= {1'b1, data, 1'b0};
            bits_q <= 4'd10;
            divider_q <= divisor;
            ticks_q <= divisor - 1;
        end else if (!ready) begin
            if (ticks_q == 0) begin
                shift_q <= {1'b1, shift_q[9:1]};
                bits_q <= bits_q - 1'b1;
                ticks_q <= divider_q - 1;
            end else ticks_q <= ticks_q - 1;
        end
    end
endmodule
