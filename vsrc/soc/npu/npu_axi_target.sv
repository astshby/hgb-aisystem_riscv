// Module: npu_axi_target
// Description: Buffered AXI clock crossing and 32-bit local accesses to the pinned YOLO NPU.
module npu_axi_target #(
    parameter logic [31:0] BASE = soc_addr_pkg::NPU_SRAM_BASE
) (
    input logic clk_sys, rst_sys, clk_npu, rst_npu,
    input axi_types_pkg::axi_req_t axi_req,
    output axi_types_pkg::axi_rsp_t axi_rsp
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    axi_types_pkg::axi_req_t local_axi;
    axi_types_pkg::axi_rsp_t local_axi_rsp;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_req_t request;
    bus_rsp_t response;
    logic legal, error_valid_q, lane_q;
    logic device_ready, device_valid, device_error;
    logic [31:0] device_data;

    // 整个 AXI beat 跨域后在 NPU 域拆成 32 位访问；不逐字往返跨域握手。
    // 两侧使用共同系统复位，禁止仅重置一侧 FIFO 后继续旧事务。
    axi_clock_bridge #(.DEPTH(4)) u_cdc (
        .s_clk(clk_sys), .s_rst(rst_sys), .m_clk(clk_npu), .m_rst(rst_npu),
        .s_req(axi_req), .s_rsp(axi_rsp), .m_req(local_axi), .m_rsp(local_axi_rsp)
    );
    axi_bus_target #(.LOCAL_BYTES(4)) u_target (
        .clk(clk_npu), .rst(rst_npu), .axi_req(local_axi), .axi_rsp(local_axi_rsp),
        .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response
    );

    // 这是设备寄存器及暂存窗口，不能当作可执行或可缓存 RAM。
    // 完整地址检查在截取局部 16 位之前完成，非法请求没有设备副作用。
    assign legal = request.addr >= xlen_t'(BASE) &&
        65'(request.addr) < 65'(BASE) + 65536 && !request.execute &&
        request.size == MEM_WORD && request.addr[1:0] == 0;
    assign req_ready = !rst_npu && (legal ? device_ready : !error_valid_q);
    assign rsp_valid = device_valid || error_valid_q;
    assign response.error = error_valid_q ? BUS_DECERR : device_error ? BUS_SLVERR : BUS_OK;
    assign response.rdata = xlen_t'(error_valid_q ? 32'b0 : device_data) <<
        (XLEN == 64 && lane_q ? 32 : 0);
    always_ff @(posedge clk_npu) begin
        if (rst_npu) begin
            error_valid_q <= 0;
            lane_q <= 0;
        end else begin
            if (rsp_valid && rsp_ready) error_valid_q <= 0;
            if (req_valid && req_ready) begin
                error_valid_q <= !legal;
                lane_q <= request.addr[2];
            end
        end
    end
    npu_mmio128 u_device (
        .clk(clk_npu), .rst(rst_npu), .req_valid(req_valid && legal), .req_ready(device_ready),
        .req_write(request.write), .req_addr(request.addr[15:0]),
        .req_wdata(32'(request.wdata >> (XLEN == 64 && request.addr[2] ? 32 : 0))),
        .req_wstrb(4'(request.wstrb >> (XLEN == 64 && request.addr[2] ? 4 : 0))),
        .rsp_valid(device_valid), .rsp_ready, .rsp_rdata(device_data), .rsp_error(device_error)
    );
endmodule
