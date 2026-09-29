// Module: soc_info
// Description: Identification, capacity registers and asynchronous data-cache maintenance commands.
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
    output logic cache_command_valid,
    output cache_pkg::cache_maint_op_e cache_command,
    input logic cache_command_ready, cache_busy, cache_fatal,
    input cache_pkg::cache_maint_error_e cache_error,
    input core_types_pkg::xlen_t cache_fault_addr
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
                // 1=invalidate、2=clean、3=flush；写 0 为 NOP，忙时拒绝新命令。
                access_error = request.write &&
                    (|(write_data & write_mask & 32'hfffffffc) ||
                     (write_mask[0] && |write_data[1:0] && !cache_command_ready));
            end
            12'h024: read_data = DCACHE_ENABLE ? 32'd3 : 32'd0;
            12'h028: read_data = DCACHE_BYTES;
            12'h02c: read_data = DCACHE_LINE_BYTES;
            12'h030: read_data = {27'b0, cache_error, cache_fatal, (cache_error != cache_pkg::CACHE_OK), cache_busy};
            12'h034: read_data = 32'(cache_fault_addr);
            default: access_error = 1'b1;
        endcase
    end
    // 控制器在接受沿入队，MMIO 响应只确认入队；释放原 D 事务后才能开始写回。
    // command_ready 来自控制器寄存状态，不直接反馈 Cache 失效到 MMIO-ready。
    assign cache_command_valid = access_fire && request.write && request.addr[11:0] == 12'h020 &&
                                 write_mask[0] && |write_data[1:0];
    assign cache_command = cache_pkg::cache_maint_op_e'(write_data[1:0]);
endmodule
