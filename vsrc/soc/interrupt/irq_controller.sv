// Module: irq_controller
// Description: Seven-source single-context priority controller with claim/complete gateways.
module irq_controller (
    input logic clk, rst,
    input logic [6:0] sources,
    output logic irq,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response
);
    logic [2:0] priority_q [1:7];
    logic [2:0] threshold_q, selected, best_priority;
    logic [7:1] pending_q, service_q, enable_q;
    logic [31:0] read_data, write_data, write_mask;
    logic access_fire, access_error;
    logic [21:0] offset;
    assign offset = request.addr[21:0];
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );

    // 优先级数值越大越优先，同级选较小 ID；ID 0 表示没有可领取的中断。
    always_comb begin
        selected = 0;
        best_priority = threshold_q;
        for (int i = 1; i <= 7; i++)
            if (pending_q[i] && enable_q[i] && priority_q[i] > best_priority) begin
                selected = 3'(i);
                best_priority = priority_q[i];
            end
    end
    assign irq = selected != 0;
    always_comb begin
        read_data = '0;
        access_error = 1'b0;
        if (offset >= 4 && offset <= 28)
            read_data = {29'b0, priority_q[offset[4:2]]};
        else case (offset)
            22'h000000: access_error = request.write;
            22'h001000: begin
                read_data[7:1] = pending_q;
                access_error = request.write;
            end
            22'h002000: read_data[7:1] = enable_q;
            22'h200000: read_data = {29'b0, threshold_q};
            22'h200004: read_data = {29'b0, selected};
            default: access_error = 1'b1;
        endcase
    end

    // 每源最多一个 pending 或 in-service；完成后仍为高电平才重新挂起。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= '0;
            service_q <= '0;
            enable_q <= '0;
            threshold_q <= '0;
            for (int i = 1; i <= 7; i++) priority_q[i] <= '0;
        end else begin
            for (int i = 1; i <= 7; i++)
                if (sources[i-1] && !service_q[i]) pending_q[i] <= 1'b1;
            if (access_fire) begin
                if (!request.write && offset == 22'h200004 && selected != 0) begin
                    pending_q[selected] <= 1'b0;
                    service_q[selected] <= 1'b1;
                end
                if (request.write) begin
                    if (offset >= 4 && offset <= 28 && write_mask[0])
                        priority_q[offset[4:2]] <= write_data[2:0];
                    else case (offset)
                        22'h002000: enable_q <= (enable_q & ~write_mask[7:1]) |
                                                (write_data[7:1] & write_mask[7:1]);
                        22'h200000: if (write_mask[0]) threshold_q <= write_data[2:0];
                        22'h200004: if (write_mask[0] && write_data >= 1 && write_data <= 7)
                            service_q[write_data[2:0]] <= 1'b0;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
