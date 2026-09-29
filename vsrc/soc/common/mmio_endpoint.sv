// Module: mmio_endpoint
// Description: Shared one-slot response and 32-bit register lane adapter.
module mmio_endpoint (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    input logic [31:0] read_data,
    input logic access_error,
    output logic access_fire,
    output logic [31:0] write_data, write_mask
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic [$clog2(DBUS_BYTES)-1:0] lane;
    logic format_error;
    assign lane = request.addr[$clog2(DBUS_BYTES)-1:0];
    assign write_data = 32'(request.wdata >> (lane*8));
    always_comb begin
        write_mask = '0;
        for (int b = 0; b < 4; b++)
            if (int'(lane) + b < DBUS_BYTES && request.wstrb[int'(lane) + b])
                write_mask[b*8 +: 8] = '1;
    end
    assign format_error = request.execute || request.size != MEM_WORD || request.addr[1:0] != 0;
    assign req_ready = !rsp_valid || rsp_ready;
    // 副作用仅在请求接受且合法时执行；响应保持期间不能再次读清除/写设备。
    assign access_fire = req_valid && req_ready && !access_error && !format_error;
    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 1'b0;
            response <= '0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                response.error <= access_error || format_error ? BUS_SLVERR : BUS_OK;
                response.rdata <= request.write || access_error || format_error ?
                                  '0 : (xlen_t'(read_data) << (lane*8));
            end
        end
    end
endmodule
