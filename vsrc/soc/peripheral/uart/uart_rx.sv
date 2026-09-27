// Module: uart_rx
// Description: Synchronized 8N1 receiver with midpoint sampling and frame-error reporting.
module uart_rx (
    input logic clk, rst, rx,
    input logic [31:0] divisor,
    output logic received, frame_error,
    output logic [7:0] data
);
    typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_e;
    rx_state_e state_q;
    logic rx_sync;
    logic [31:0] divider_q, ticks_q;
    logic [2:0] bit_q;
    logic [7:0] shift_q;
    sync_bits #(.RESET_VALUE(1'b1)) u_sync (.clk, .rst, .async_in(rx), .sync_out(rx_sync));

    // 起始位中点复核，数据/停止位随后逐位采样；这是无 FIFO 的首版接收器。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= RX_IDLE;
            divider_q <= 32'd4;
            ticks_q <= '0;
            bit_q <= '0;
            shift_q <= '0;
            data <= '0;
            received <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            received <= 1'b0;
            frame_error <= 1'b0;
            case (state_q)
                RX_IDLE: if (!rx_sync) begin
                    divider_q <= divisor;
                    ticks_q <= (divisor >> 1) - 1;
                    state_q <= RX_START;
                end
                RX_START: if (ticks_q != 0) ticks_q <= ticks_q - 1;
                    else if (rx_sync) state_q <= RX_IDLE;
                    else begin
                        bit_q <= '0;
                        ticks_q <= divider_q - 1;
                        state_q <= RX_DATA;
                    end
                RX_DATA: if (ticks_q != 0) ticks_q <= ticks_q - 1;
                    else begin
                        shift_q[bit_q] <= rx_sync;
                        bit_q <= bit_q + 1'b1;
                        ticks_q <= divider_q - 1;
                        if (bit_q == 7) state_q <= RX_STOP;
                    end
                RX_STOP: if (ticks_q != 0) ticks_q <= ticks_q - 1;
                    else begin
                        state_q <= RX_IDLE;
                        if (rx_sync) begin
                            data <= shift_q;
                            received <= 1'b1;
                        end else frame_error <= 1'b1;
                    end
                default: state_q <= RX_IDLE;
            endcase
        end
    end
endmodule
