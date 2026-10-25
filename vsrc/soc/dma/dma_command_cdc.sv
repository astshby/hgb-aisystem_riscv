// Module: dma_command_cdc
// Description: Atomic DMA command/result mailboxes; peripheral BUSY covers the complete cross-domain transaction.
module dma_command_cdc #(
    parameter int DDR_BYTES = 0,
    parameter int FLASH_BYTES = 0
) (
    input logic clk_sys, rst_sys, clk_periph, rst_periph,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic irq,
    output axi_types_pkg::axi_req_t axi_req,
    input axi_types_pkg::axi_rsp_t axi_rsp
);
    typedef struct packed {logic [31:0] src, dst, length;} command_t;
    typedef struct packed {logic error; logic [2:0] code; logic [31:0] bytes, addr;} result_t;
    command_t command_in, command_out;
    result_t result_in, result_out;
    logic start_valid, command_ready, command_valid, command_accept;
    logic busy_q, engine_busy, finish_valid, result_ready, result_valid;
    dma_regs u_regs (.clk(clk_periph), .rst(rst_periph), .req_valid, .req_ready, .request,
        .rsp_valid, .rsp_ready, .response, .irq, .engine_busy(busy_q),
        .finish_valid(result_valid), .finish_error(result_out.error), .finish_code(result_out.code),
        .finish_bytes(result_out.bytes), .finish_addr(result_out.addr),
        .start_valid, .start_src(command_in.src), .start_dst(command_in.dst), .start_length(command_in.length));
    async_fifo #(.WIDTH($bits(command_t)), .DEPTH(2)) u_command (
        .s_clk(clk_periph), .s_rst(rst_periph), .m_clk(clk_sys), .m_rst(rst_sys),
        .in_valid(start_valid), .in_ready(command_ready), .in_data(command_in),
        .out_valid(command_valid), .out_ready(!engine_busy), .out_data(command_out));
    assign command_accept = command_valid && !engine_busy;
    dma_axi_master #(.DDR_BYTES(DDR_BYTES), .FLASH_BYTES(FLASH_BYTES)) u_master (
        .clk(clk_sys), .rst(rst_sys), .start_valid(command_accept), .start_src(command_out.src),
        .start_dst(command_out.dst), .start_length(command_out.length), .busy(engine_busy),
        .finish_valid, .finish_error(result_in.error), .finish_code(result_in.code),
        .finish_bytes(result_in.bytes), .finish_addr(result_in.addr), .axi_req, .axi_rsp);
    async_fifo #(.WIDTH($bits(result_t)), .DEPTH(2)) u_result (
        .s_clk(clk_sys), .s_rst(rst_sys), .m_clk(clk_periph), .m_rst(rst_periph),
        .in_valid(finish_valid), .in_ready(result_ready), .in_data(result_in),
        .out_valid(result_valid), .out_ready(1'b1), .out_data(result_out));
    always_ff @(posedge clk_periph) begin
        if (rst_periph) busy_q <= 0;
        else if (result_valid) busy_q <= 0;
        else if (start_valid) busy_q <= 1;
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk_periph) disable iff (rst_periph) start_valid |-> command_ready && !busy_q);
    assert property (@(posedge clk_sys) disable iff (rst_sys) finish_valid |-> result_ready);
`endif
endmodule
