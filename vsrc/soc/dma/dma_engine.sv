// Module: dma_engine
// Description: Selects preserved single-beat or bounded overlapping block DMA with unchanged task completion semantics.
module dma_engine #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit WIDE_ENABLE = 1'b0,
    parameter bit BLOCK_ENABLE = 1'b0
) (
    input logic clk, rst,
    input logic start_valid,
    input logic [31:0] start_src, start_dst, start_length,
    output logic busy,
    output logic finish_valid, finish_error,
    output logic [2:0] finish_code,
    output logic [31:0] finish_bytes, finish_addr,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::bus_rsp_t response,
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
    // 静态选择只有一份任务所有者；BLOCK=0原窄/宽路径不经新的缓冲或调度。
    generate
        if (BLOCK_ENABLE) begin
            dma_block_engine #(.DDR_BYTES(DDR_BYTES), .WIDE_ENABLE(WIDE_ENABLE)) u_block (
                .clk, .rst, .start_valid, .start_src, .start_dst, .start_length,
                .busy, .finish_valid, .finish_error, .finish_code, .finish_bytes, .finish_addr,
                .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
                .blk_rd_cmd_valid, .blk_rd_cmd_ready, .blk_rd_cmd,
                .blk_rd_valid, .blk_rd_ready, .blk_rd_data,
                .blk_wr_cmd_valid, .blk_wr_cmd_ready, .blk_wr_cmd,
                .blk_wr_valid, .blk_wr_ready, .blk_wr_data,
                .blk_wr_rsp_valid, .blk_wr_rsp_ready, .blk_wr_rsp
            );
            assign wide_req_valid = 1'b0;
            assign wide_request = '0;
            assign wide_rsp_ready = 1'b0;
        end else begin
            dma_legacy_engine #(.DDR_BYTES(DDR_BYTES), .WIDE_ENABLE(WIDE_ENABLE)) u_legacy (
                .clk, .rst, .start_valid, .start_src, .start_dst, .start_length,
                .busy, .finish_valid, .finish_error, .finish_code, .finish_bytes, .finish_addr,
                .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
                .wide_req_valid, .wide_req_ready, .wide_request,
                .wide_rsp_valid, .wide_rsp_ready, .wide_response
            );
            assign blk_rd_cmd_valid = 1'b0;
            assign blk_rd_cmd = '0;
            assign blk_rd_ready = 1'b0;
            assign blk_wr_cmd_valid = 1'b0;
            assign blk_wr_cmd = '0;
            assign blk_wr_valid = 1'b0;
            assign blk_wr_data = '0;
            assign blk_wr_rsp_ready = 1'b0;
        end
    endgenerate
endmodule
