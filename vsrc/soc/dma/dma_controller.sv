// Module: dma_controller
// Description: Joins DMA MMIO registers with an independent local-bus copy master.
module dma_controller #(
    parameter int unsigned DDR_BYTES = 0
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
    input bus_types_pkg::bus_rsp_t master_response
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
    dma_engine #(.DDR_BYTES(DDR_BYTES)) u_engine (
        .clk, .rst, .start_valid, .start_src, .start_dst, .start_length,
        .busy(engine_busy), .finish_valid, .finish_error,
        .finish_code, .finish_bytes, .finish_addr,
        .req_valid(master_req_valid), .req_ready(master_req_ready),
        .request(master_request), .rsp_valid(master_rsp_valid),
        .rsp_ready(master_rsp_ready), .response(master_response)
    );
endmodule
