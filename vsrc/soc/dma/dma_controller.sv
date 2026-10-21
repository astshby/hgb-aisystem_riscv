// Module: dma_controller
// Description: Joins DMA MMIO registers with an independent local-bus copy master.
module dma_controller #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit WIDE_ENABLE = 1'b0,
    parameter bit BLOCK_ENABLE = 1'b0
) (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic irq,
    output logic master_req_valid,
    input logic master_req_ready,
    output bus_types_pkg::bus_req_t master_request,
    input logic master_rsp_valid,
    output logic master_rsp_ready,
    input bus_types_pkg::bus_rsp_t master_response,
    output logic wide_req_valid,
    input logic wide_req_ready,
    output bus_types_pkg::ddr_req_t wide_request,
    input logic wide_rsp_valid,
    output logic wide_rsp_ready,
    input bus_types_pkg::ddr_rsp_t wide_response,
    output logic blk_rd_cmd_valid,
    input logic blk_rd_cmd_ready,
    output block_types_pkg::block_cmd_t blk_rd_cmd,
    input logic blk_rd_valid,
    output logic blk_rd_ready,
    input block_types_pkg::block_r_t blk_rd_data,
    output logic blk_wr_cmd_valid,
    input logic blk_wr_cmd_ready,
    output block_types_pkg::block_cmd_t blk_wr_cmd,
    output logic blk_wr_valid,
    input logic blk_wr_ready,
    output block_types_pkg::block_w_t blk_wr_data,
    input logic blk_wr_rsp_valid,
    output logic blk_wr_rsp_ready,
    input block_types_pkg::block_b_t blk_wr_rsp
);
    logic start_valid, engine_busy, finish_valid, finish_error;
    logic [31:0] start_src, start_dst, start_length, finish_bytes, finish_addr;
    logic [2:0] finish_code;
    dma_regs u_regs (
        .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
        .response, .engine_busy, .finish_valid, .finish_error,
        .finish_code, .finish_bytes, .finish_addr,
        .start_valid, .start_src, .start_dst, .start_length, .irq
    );
    dma_engine #(.DDR_BYTES(DDR_BYTES), .WIDE_ENABLE(WIDE_ENABLE), .BLOCK_ENABLE(BLOCK_ENABLE)) u_engine (
        .clk, .rst, .start_valid, .start_src, .start_dst, .start_length,
        .busy(engine_busy), .finish_valid, .finish_error,
        .finish_code, .finish_bytes, .finish_addr,
        .req_valid(master_req_valid), .req_ready(master_req_ready),
        .request(master_request), .rsp_valid(master_rsp_valid),
        .rsp_ready(master_rsp_ready), .response(master_response),
        .wide_req_valid, .wide_req_ready, .wide_request,
        .wide_rsp_valid, .wide_rsp_ready, .wide_response,
        .blk_rd_cmd_valid, .blk_rd_cmd_ready, .blk_rd_cmd,
        .blk_rd_valid, .blk_rd_ready, .blk_rd_data,
        .blk_wr_cmd_valid, .blk_wr_cmd_ready, .blk_wr_cmd,
        .blk_wr_valid, .blk_wr_ready, .blk_wr_data,
        .blk_wr_rsp_valid, .blk_wr_rsp_ready, .blk_wr_rsp
    );
endmodule
