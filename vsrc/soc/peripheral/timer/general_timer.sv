// Module: general_timer
// Description: Programmable 32-bit one-shot/periodic timer with sticky interrupt status.
module general_timer (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic irq
);
    logic [31:0] count_q, limit_q, control_q, read_data, write_data, write_mask;
    logic pending_q, access_fire, access_error, event_now;
    logic [11:0] offset;
    assign offset = request.addr[11:0];
    assign irq = pending_q && control_q[2];
    assign event_now = control_q[0] && count_q >= limit_q;
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );
    always_comb begin
        read_data = '0;
        access_error = 1'b0;
        case (offset)
            12'h000: read_data = count_q;
            12'h004: read_data = limit_q;
            12'h008: read_data = control_q;
            12'h00c: read_data = {31'b0, pending_q};
            default: access_error = 1'b1;
        endcase
    end

    // CTRL[0]=enable，[1]=periodic，[2]=IRQ enable；STATUS[0] 写 1 清除。
    always_ff @(posedge clk) begin
        if (rst) begin
            count_q <= '0;
            limit_q <= '1;
            control_q <= '0;
            pending_q <= 1'b0;
        end else begin
            if (control_q[0]) begin
                if (event_now) begin
                    count_q <= '0;
                    if (!control_q[1]) control_q[0] <= 1'b0;
                end else count_q <= count_q + 32'd1;
            end
            if (access_fire && request.write) begin
                case (offset)
                    12'h000: count_q <= (count_q & ~write_mask) | (write_data & write_mask);
                    12'h004: limit_q <= (limit_q & ~write_mask) | (write_data & write_mask);
                    12'h008: control_q <= ((control_q & ~write_mask) | (write_data & write_mask)) & 32'h7;
                    12'h00c: if (write_mask[0] && write_data[0]) pending_q <= 1'b0;
                    default: ;
                endcase
            end
            // 同拍新事件优先于软件清除，避免边界时刻丢中断。
            if (event_now) pending_q <= 1'b1;
        end
    end
endmodule
