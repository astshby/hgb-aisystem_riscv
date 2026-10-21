// Module: ddr_block_fabric
// Description: Joins legacy DDR requests, two cache line clients and a block DMA client on one memory backend.
module ddr_block_fabric #(
    parameter int unsigned DDR_BYTES = 64 * 1024
) (
    input logic clk, rst,
    input logic cpu_req_valid,
    output logic cpu_req_ready,
    input bus_types_pkg::bus_req_t cpu_request,
    output logic cpu_rsp_valid,
    input logic cpu_rsp_ready,
    output bus_types_pkg::bus_rsp_t cpu_response,
    input logic dma_req_valid,
    output logic dma_req_ready,
    input bus_types_pkg::ddr_req_t dma_request,
    output logic dma_rsp_valid,
    input logic dma_rsp_ready,
    output bus_types_pkg::ddr_rsp_t dma_response,
    input logic [1:0] cache_rd_cmd_valid,
    output logic [1:0] cache_rd_cmd_ready,
    input block_types_pkg::block_cmd_t cache_rd_cmd [2],
    output logic [1:0] cache_rd_valid,
    input logic [1:0] cache_rd_ready,
    output block_types_pkg::block_r_t cache_rd_data [2],
    input logic [1:0] cache_wr_cmd_valid,
    output logic [1:0] cache_wr_cmd_ready,
    input block_types_pkg::block_cmd_t cache_wr_cmd [2],
    input logic [1:0] cache_wr_valid,
    output logic [1:0] cache_wr_ready,
    input block_types_pkg::block_w_t cache_wr_data [2],
    output logic [1:0] cache_wr_rsp_valid,
    input logic [1:0] cache_wr_rsp_ready,
    output block_types_pkg::block_b_t cache_wr_rsp [2],
    input logic dma_block_rd_cmd_valid,
    output logic dma_block_rd_cmd_ready,
    input block_types_pkg::block_cmd_t dma_block_rd_cmd,
    output logic dma_block_rd_valid,
    input logic dma_block_rd_ready,
    output block_types_pkg::block_r_t dma_block_rd_data,
    input logic dma_block_wr_cmd_valid,
    output logic dma_block_wr_cmd_ready,
    input block_types_pkg::block_cmd_t dma_block_wr_cmd,
    input logic dma_block_wr_valid,
    output logic dma_block_wr_ready,
    input block_types_pkg::block_w_t dma_block_wr_data,
    output logic dma_block_wr_rsp_valid,
    input logic dma_block_wr_rsp_ready,
    output block_types_pkg::block_b_t dma_block_wr_rsp,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data,
    output logic wr_cmd_valid,
    input logic wr_cmd_ready,
    output block_types_pkg::block_cmd_t wr_cmd,
    output logic wr_valid,
    input logic wr_ready,
    output block_types_pkg::block_w_t wr_data,
    input logic wr_rsp_valid,
    output logic wr_rsp_ready,
    input block_types_pkg::block_b_t wr_rsp
);
    import bus_types_pkg::*;
    import block_types_pkg::*;
    logic native_req_valid, native_req_ready, native_rsp_valid, native_rsp_ready;
    ddr_req_t native_request;
    ddr_rsp_t native_response;
    logic [3:0] c_rd_cmd_valid, c_rd_cmd_ready, c_rd_valid, c_rd_ready;
    logic [3:0] c_wr_cmd_valid, c_wr_cmd_ready, c_wr_valid, c_wr_ready;
    logic [3:0] c_wr_rsp_valid, c_wr_rsp_ready;
    block_cmd_t c_rd_cmd [4], c_wr_cmd [4];
    block_r_t c_rd_data [4];
    block_w_t c_wr_data [4];
    block_b_t c_wr_rsp [4];

    // 原CPU窄口/DMA单拍口保留同一适配，不生成第二份外存或偷偷扩大窄访问大小。
    ddr_port_arbiter u_legacy_port (
        .clk, .rst, .cpu_req_valid, .cpu_req_ready, .cpu_request,
        .cpu_rsp_valid, .cpu_rsp_ready, .cpu_response,
        .dma_req_valid, .dma_req_ready, .dma_request, .dma_rsp_valid, .dma_rsp_ready, .dma_response,
        .req_valid(native_req_valid), .req_ready(native_req_ready), .request(native_request),
        .rsp_valid(native_rsp_valid), .rsp_ready(native_rsp_ready), .response(native_response)
    );
    ddr_block_adapter #(.DDR_BYTES(DDR_BYTES)) u_legacy_adapter (
        .clk, .rst, .req_valid(native_req_valid), .req_ready(native_req_ready), .request(native_request),
        .rsp_valid(native_rsp_valid), .rsp_ready(native_rsp_ready), .response(native_response),
        .rd_cmd_valid(c_rd_cmd_valid[0]), .rd_cmd_ready(c_rd_cmd_ready[0]), .rd_cmd(c_rd_cmd[0]),
        .rd_valid(c_rd_valid[0]), .rd_ready(c_rd_ready[0]), .rd_data(c_rd_data[0]),
        .wr_cmd_valid(c_wr_cmd_valid[0]), .wr_cmd_ready(c_wr_cmd_ready[0]), .wr_cmd(c_wr_cmd[0]),
        .wr_valid(c_wr_valid[0]), .wr_ready(c_wr_ready[0]), .wr_data(c_wr_data[0]),
        .wr_rsp_valid(c_wr_rsp_valid[0]), .wr_rsp_ready(c_wr_rsp_ready[0]), .wr_rsp(c_wr_rsp[0])
    );
    // client1/2固定为I$/D$；client3留给DMA双块调度。读写方向有各自的真实owner。
    for (genvar client = 0; client < 2; client++) begin : g_cache_client
        assign c_rd_cmd_valid[client+1] = cache_rd_cmd_valid[client];
        assign cache_rd_cmd_ready[client] = c_rd_cmd_ready[client+1];
        assign c_rd_cmd[client+1] = cache_rd_cmd[client];
        assign cache_rd_valid[client] = c_rd_valid[client+1];
        assign c_rd_ready[client+1] = cache_rd_ready[client];
        assign cache_rd_data[client] = c_rd_data[client+1];
        assign c_wr_cmd_valid[client+1] = cache_wr_cmd_valid[client];
        assign cache_wr_cmd_ready[client] = c_wr_cmd_ready[client+1];
        assign c_wr_cmd[client+1] = cache_wr_cmd[client];
        assign c_wr_valid[client+1] = cache_wr_valid[client];
        assign cache_wr_ready[client] = c_wr_ready[client+1];
        assign c_wr_data[client+1] = cache_wr_data[client];
        assign cache_wr_rsp_valid[client] = c_wr_rsp_valid[client+1];
        assign c_wr_rsp_ready[client+1] = cache_wr_rsp_ready[client];
        assign cache_wr_rsp[client] = c_wr_rsp[client+1];
    end
    assign c_rd_cmd_valid[3] = dma_block_rd_cmd_valid;
    assign dma_block_rd_cmd_ready = c_rd_cmd_ready[3];
    assign c_rd_cmd[3] = dma_block_rd_cmd;
    assign dma_block_rd_valid = c_rd_valid[3];
    assign c_rd_ready[3] = dma_block_rd_ready;
    assign dma_block_rd_data = c_rd_data[3];
    assign c_wr_cmd_valid[3] = dma_block_wr_cmd_valid;
    assign dma_block_wr_cmd_ready = c_wr_cmd_ready[3];
    assign c_wr_cmd[3] = dma_block_wr_cmd;
    assign c_wr_valid[3] = dma_block_wr_valid;
    assign dma_block_wr_ready = c_wr_ready[3];
    assign c_wr_data[3] = dma_block_wr_data;
    assign dma_block_wr_rsp_valid = c_wr_rsp_valid[3];
    assign c_wr_rsp_ready[3] = dma_block_wr_rsp_ready;
    assign dma_block_wr_rsp = c_wr_rsp[3];
    block_arbiter #(.CLIENTS(4)) u_arbiter (
        .clk, .rst, .c_rd_cmd_valid, .c_rd_cmd_ready, .c_rd_cmd,
        .c_rd_valid, .c_rd_ready, .c_rd_data, .c_wr_cmd_valid, .c_wr_cmd_ready, .c_wr_cmd,
        .c_wr_valid, .c_wr_ready, .c_wr_data, .c_wr_rsp_valid, .c_wr_rsp_ready, .c_wr_rsp,
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
    );
endmodule
