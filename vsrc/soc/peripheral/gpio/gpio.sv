// Module: gpio
// Description: 32-bit synchronized GPIO bank with output enables and edge interrupt latches.
module gpio (
    input logic clk, rst,
    input logic [31:0] gpio_in,
    output logic [31:0] gpio_out, gpio_oe,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic irq
);
    logic [31:0] input_sync, previous_q, enable_q, rise_q, fall_q, pending_q;
    logic [31:0] edge_event, read_data, write_data, write_mask;
    logic access_fire, access_error;
    logic [11:0] offset;
    assign offset = request.addr[11:0];
    sync_bits #(.WIDTH(32)) u_sync (.clk, .rst, .async_in(gpio_in), .sync_out(input_sync));
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );
    assign edge_event = (input_sync & ~previous_q & rise_q) |
                        (~input_sync & previous_q & fall_q);
    assign irq = |(pending_q & enable_q);
    always_comb begin
        read_data = '0;
        access_error = 1'b0;
        case (offset)
            12'h000: begin
                read_data = input_sync;
                access_error = request.write;
            end
            12'h004: read_data = gpio_out;
            12'h008: read_data = gpio_oe;
            12'h00c: read_data = enable_q;
            12'h010: read_data = rise_q;
            12'h014: read_data = fall_q;
            12'h018: read_data = pending_q;
            default: access_error = 1'b1;
        endcase
    end
    // 输入先同步再检测边沿；待处理位由事件置位，写 1 清除且新事件优先。
    always_ff @(posedge clk) begin
        if (rst) begin
            previous_q <= '0;
            gpio_out <= '0;
            gpio_oe <= '0;
            enable_q <= '0;
            rise_q <= '0;
            fall_q <= '0;
            pending_q <= '0;
        end else begin
            previous_q <= input_sync;
            pending_q <= pending_q | edge_event;
            if (access_fire && request.write) begin
                case (offset)
                    12'h004: gpio_out <= (gpio_out & ~write_mask) | (write_data & write_mask);
                    12'h008: gpio_oe <= (gpio_oe & ~write_mask) | (write_data & write_mask);
                    12'h00c: enable_q <= (enable_q & ~write_mask) | (write_data & write_mask);
                    12'h010: rise_q <= (rise_q & ~write_mask) | (write_data & write_mask);
                    12'h014: fall_q <= (fall_q & ~write_mask) | (write_data & write_mask);
                    12'h018: pending_q <= (pending_q & ~(write_data & write_mask)) | edge_event;
                    default: ;
                endcase
            end
        end
    end
endmodule
