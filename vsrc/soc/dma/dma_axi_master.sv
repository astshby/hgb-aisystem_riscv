// Module: dma_axi_master
// Description: Two-buffer copy engine with one unified AXI master for Flash, TCM and DDR.
module dma_axi_master #(
    parameter int DDR_BYTES = 0,
    parameter int FLASH_BYTES = 0
) (
    input logic clk, rst,
    input logic start_valid,
    input logic [31:0] start_src, start_dst, start_length,
    output logic busy, finish_valid, finish_error,
    output logic [2:0] finish_code,
    output logic [31:0] finish_bytes, finish_addr,
    output axi_types_pkg::axi_req_t axi_req,
    input axi_types_pkg::axi_rsp_t axi_rsp
);
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_types_pkg::bus_req_t request;
    bus_types_pkg::bus_rsp_t response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_types_pkg::block_cmd_t rd_cmd, wr_cmd;
    block_types_pkg::block_r_t rd_data;
    block_types_pkg::block_w_t wr_data;
    block_types_pkg::block_b_t wr_rsp;
    dma_block_engine #(.DDR_BYTES(DDR_BYTES), .FLASH_BYTES(FLASH_BYTES), .WIDE_ENABLE(1), .UNIFIED_BUS(1)) u_engine (
        .clk, .rst, .start_valid, .start_src, .start_dst, .start_length,
        .busy, .finish_valid, .finish_error, .finish_code, .finish_bytes, .finish_addr,
        .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
        .blk_rd_cmd_valid(rd_cmd_valid), .blk_rd_cmd_ready(rd_cmd_ready), .blk_rd_cmd(rd_cmd),
        .blk_rd_valid(rd_valid), .blk_rd_ready(rd_ready), .blk_rd_data(rd_data),
        .blk_wr_cmd_valid(wr_cmd_valid), .blk_wr_cmd_ready(wr_cmd_ready), .blk_wr_cmd(wr_cmd),
        .blk_wr_valid(wr_valid), .blk_wr_ready(wr_ready), .blk_wr_data(wr_data),
        .blk_wr_rsp_valid(wr_rsp_valid), .blk_wr_rsp_ready(wr_rsp_ready), .blk_wr_rsp(wr_rsp)
    );
    cache_axi_adapter u_axi (.clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp, .axi_req, .axi_rsp);
endmodule
