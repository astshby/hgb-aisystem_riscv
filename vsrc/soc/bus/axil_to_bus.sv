// Module: axil_to_bus
// Description: Queued AXI4-Lite64 endpoint for existing scalar MMIO register semantics.
module axil_to_bus (
    input logic clk, rst,
    input axi_types_pkg::axil_req_t axi_req,
    output axi_types_pkg::axil_rsp_t axi_rsp,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::bus_rsp_t response
);
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    import core_types_pkg::*;
    import core_config_pkg::*;
    axil_a_t aw, ar;
    axil_w_t w;
    logic aw_valid, ar_valid, w_valid, aw_pop, ar_pop, w_pop;
    logic active_q, write_q, next_write_q, lane_q, select_write;
    logic b_valid, b_ready, r_valid, r_ready;
    axi_resp_e b;
    axil_r_t r;
    axi_resp_e error_code;
    // ADS 不允许 FIFO logic 输出直接驱动 enum/含 enum 的输出结构。
    logic [1:0] b_out;
    logic [$bits(axil_r_t)-1:0] r_out;
    assign axi_rsp.b = axi_resp_e'(b_out);
    assign axi_rsp.r = axil_r_t'(r_out);
    rv_fifo #(.WIDTH($bits(axil_a_t))) u_aw (.clk, .rst, .in_valid(axi_req.aw_valid), .in_ready(axi_rsp.aw_ready),
        .in_data(axi_req.aw), .out_valid(aw_valid), .out_ready(aw_pop), .out_data(aw), .occupancy());
    rv_fifo #(.WIDTH($bits(axil_a_t))) u_ar (.clk, .rst, .in_valid(axi_req.ar_valid), .in_ready(axi_rsp.ar_ready),
        .in_data(axi_req.ar), .out_valid(ar_valid), .out_ready(ar_pop), .out_data(ar), .occupancy());
    rv_fifo #(.WIDTH($bits(axil_w_t))) u_w (.clk, .rst, .in_valid(axi_req.w_valid), .in_ready(axi_rsp.w_ready),
        .in_data(axi_req.w), .out_valid(w_valid), .out_ready(w_pop), .out_data(w), .occupancy());
    rv_fifo #(.WIDTH($bits(axi_resp_e))) u_b (.clk, .rst, .in_valid(b_valid), .in_ready(b_ready),
        .in_data(b), .out_valid(axi_rsp.b_valid), .out_ready(axi_req.b_ready), .out_data(b_out), .occupancy());
    rv_fifo #(.WIDTH($bits(axil_r_t))) u_r (.clk, .rst, .in_valid(r_valid), .in_ready(r_ready),
        .in_data(r), .out_valid(axi_rsp.r_valid), .out_ready(axi_req.r_ready), .out_data(r_out), .occupancy());
    assign select_write = aw_valid && w_valid && (next_write_q || !ar_valid);
    assign req_valid = !rst && !active_q && (select_write || ar_valid);
    assign aw_pop = req_valid && req_ready && select_write;
    assign w_pop = aw_pop;
    assign ar_pop = req_valid && req_ready && !select_write;
    assign error_code = response.error == BUS_OK ? AXI_OKAY : response.error == BUS_DECERR ? AXI_DECERR : AXI_SLVERR;
    assign b_valid = active_q && write_q && rsp_valid;
    assign b = error_code;
    assign r_valid = active_q && !write_q && rsp_valid;
    assign r = '{data:64'(response.rdata) << (XLEN == 32 && lane_q ? 32 : 0), resp:error_code};
    assign rsp_ready = active_q && (write_q ? b_ready : r_ready);
    always_comb begin
        request = '0;
        request.addr = xlen_t'(select_write ? aw.addr : ar.addr);
        request.execute = select_write ? aw.prot[2] : ar.prot[2];
        request.write = select_write;
        request.size = MEM_WORD;
        // Lite 没有 SIZE。64 位 timer 寄存器一次采样，32 位子访问由上游 byte lane 提取。
        if (XLEN == 64 && request.addr[31:16] == 16'h0200 &&
            (request.addr[15:0] == 16'h4000 || request.addr[15:0] == 16'hbff8)) request.size = MEM_DWORD;
        request.wdata = xlen_t'(w.data >> (XLEN == 32 && aw.addr[2] ? 32 : 0));
        request.wstrb = DBUS_BYTES'(w.strb >> (XLEN == 32 && aw.addr[2] ? 4 : 0));
    end
    always_ff @(posedge clk) begin
        if (rst) begin active_q <= 0; write_q <= 0; next_write_q <= 0; lane_q <= 0; end
        else begin
            if (req_valid && req_ready) begin
                active_q <= 1; write_q <= select_write; lane_q <= request.addr[2];
                next_write_q <= !select_write;
            end
            if (rsp_valid && rsp_ready) active_q <= 0;
        end
    end
endmodule
