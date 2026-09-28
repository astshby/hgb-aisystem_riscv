// Module: soc_info
// Description: Identification, capacity registers and explicit data-cache invalidate command.
module soc_info #(
    parameter logic [31:0] CLOCK_HZ = 50000000,
    parameter bit DCACHE_ENABLE = 1'b1,
    parameter int unsigned DCACHE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 32
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic dcache_invalidate
);
    logic [31:0] read_data, write_data, write_mask;
    logic access_error, access_fire;
    mmio_endpoint u_mmio (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .read_data, .access_error, .access_fire, .write_data, .write_mask
    );
    always_comb begin
        access_error = request.write;
        read_data = '0;
        case (request.addr[11:0])
            12'h000: read_data = 32'(core_config_pkg::XLEN);
            12'h004: read_data = CLOCK_HZ;
            12'h008: read_data = soc_config_pkg::ITCM_BYTES;
            12'h00c: read_data = soc_config_pkg::DTCM_BYTES;
            12'h020: begin
                // 写 1 全失效；读恒为 0。仅按有效 byte mask 检查保留位。
                access_error = request.write && |(write_data & write_mask & 32'hfffffffe);
            end
            12'h024: read_data = 32'(DCACHE_ENABLE);
            12'h028: read_data = DCACHE_BYTES;
            12'h02c: read_data = DCACHE_LINE_BYTES;
            default: access_error = 1'b1;
        endcase
    end
    // 请求接受后寄存维护脉冲，避免 MMIO-ready 与 Cache invalidate 形成组合环。
    // 下一个上升沿清 valid，同时该写响应最早被 CPU 消费；命令无需额外忙状态。
    always_ff @(posedge clk) begin
        if (rst) dcache_invalidate <= 1'b0;
        else dcache_invalidate <= access_fire && request.write && request.addr[11:0] == 12'h020 &&
                                  write_data[0] && write_mask[0];
    end
endmodule
