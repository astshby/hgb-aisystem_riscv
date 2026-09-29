// Module: uart
// Description: Single-byte buffered 8N1 MMIO UART with RX/TX/error level interrupts.
module uart #(
    parameter logic [31:0] RESET_DIVISOR = 434
) (
    input logic clk, rst, rx,
    output logic tx, irq,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    logic [31:0] divisor_q, irq_enable_q, read_data, write_data, write_mask, merged_divisor;
    logic [7:0] rx_data_q, rx_data;
    logic rx_valid_q, overrun_q, frame_error_q;
    logic tx_ready, tx_start, rx_received, rx_frame_error, rx_pop;
    logic access_fire, access_error;
    logic [11:0] offset;
    assign offset = request.addr[11:0];
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );
    uart_tx u_tx (.clk, .rst, .start(tx_start), .data(write_data[7:0]), .divisor(divisor_q),
                  .ready(tx_ready), .tx);
    uart_rx u_rx (.clk, .rst, .rx, .divisor(divisor_q), .received(rx_received),
                  .frame_error(rx_frame_error), .data(rx_data));
    assign tx_start = access_fire && request.write && offset == 0 && write_mask[0];
    assign rx_pop = access_fire && !request.write && offset == 4;
    assign irq = (irq_enable_q[0] && rx_valid_q) || (irq_enable_q[1] && tx_ready) ||
                 (irq_enable_q[2] && (overrun_q || frame_error_q));
    assign merged_divisor = (divisor_q & ~write_mask) | (write_data & write_mask);

    // 软件先轮询 TX-ready；忙时写 TX 返回错误而不是丢字符。RX 空读返回 0。
    always_comb begin
        read_data = '0;
        access_error = 1'b0;
        case (offset)
            12'h000: access_error = request.write && !tx_ready;
            12'h004: begin
                read_data = rx_valid_q ? {24'b0, rx_data_q} : '0;
                access_error = request.write;
            end
            12'h008: read_data = {28'b0, frame_error_q, overrun_q, rx_valid_q, tx_ready};
            12'h00c: read_data = divisor_q;
            12'h010: read_data = irq_enable_q;
            default: access_error = 1'b1;
        endcase
    end

    // 字符读取只在请求接受时出队；响应反压不会重复清除接收缓冲。
    always_ff @(posedge clk) begin
        if (rst) begin
            divisor_q <= RESET_DIVISOR < 4 ? 32'd4 : RESET_DIVISOR;
            irq_enable_q <= '0;
            rx_data_q <= '0;
            rx_valid_q <= 1'b0;
            overrun_q <= 1'b0;
            frame_error_q <= 1'b0;
        end else begin
            if (rx_pop) rx_valid_q <= 1'b0;
            if (access_fire && request.write) begin
                case (offset)
                    12'h008: begin
                        if (write_data[2] && write_mask[2]) overrun_q <= 1'b0;
                        if (write_data[3] && write_mask[3]) frame_error_q <= 1'b0;
                    end
                    12'h00c: divisor_q <= merged_divisor < 4 ? 32'd4 : merged_divisor;
                    12'h010: irq_enable_q <= ((irq_enable_q & ~write_mask) |
                                              (write_data & write_mask)) & 32'h7;
                    default: ;
                endcase
            end
            if (rx_received) begin
                if (rx_valid_q && !rx_pop) overrun_q <= 1'b1;
                else begin
                    rx_data_q <= rx_data;
                    rx_valid_q <= 1'b1;
                end
            end
            if (rx_frame_error) frame_error_q <= 1'b1;
        end
    end
endmodule
