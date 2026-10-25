// Module: axi_clock_bridge
// Description: Five independent buffered AXI channels; payload and valid have separate ownership.
module axi_clock_bridge #(parameter int DEPTH = 8) (
    input logic s_clk, s_rst, m_clk, m_rst,
    input axi_types_pkg::axi_req_t s_req,
    output axi_types_pkg::axi_rsp_t s_rsp,
    output axi_types_pkg::axi_req_t m_req,
    input axi_types_pkg::axi_rsp_t m_rsp
);
    import axi_types_pkg::*;
    async_fifo #(.WIDTH($bits(axi_a_t)), .DEPTH(DEPTH)) u_aw (
        .s_clk, .s_rst, .m_clk, .m_rst,
        .in_valid(s_req.aw_valid), .in_ready(s_rsp.aw_ready), .in_data(s_req.aw),
        .out_valid(m_req.aw_valid), .out_ready(m_rsp.aw_ready), .out_data(m_req.aw)
    );
    async_fifo #(.WIDTH($bits(axi_w_t)), .DEPTH(DEPTH)) u_w (
        .s_clk, .s_rst, .m_clk, .m_rst,
        .in_valid(s_req.w_valid), .in_ready(s_rsp.w_ready), .in_data(s_req.w),
        .out_valid(m_req.w_valid), .out_ready(m_rsp.w_ready), .out_data(m_req.w)
    );
    async_fifo #(.WIDTH($bits(axi_b_t)), .DEPTH(DEPTH)) u_b (
        .s_clk(m_clk), .s_rst(m_rst), .m_clk(s_clk), .m_rst(s_rst),
        .in_valid(m_rsp.b_valid), .in_ready(m_req.b_ready), .in_data(m_rsp.b),
        .out_valid(s_rsp.b_valid), .out_ready(s_req.b_ready), .out_data(s_rsp.b)
    );
    async_fifo #(.WIDTH($bits(axi_a_t)), .DEPTH(DEPTH)) u_ar (
        .s_clk, .s_rst, .m_clk, .m_rst,
        .in_valid(s_req.ar_valid), .in_ready(s_rsp.ar_ready), .in_data(s_req.ar),
        .out_valid(m_req.ar_valid), .out_ready(m_rsp.ar_ready), .out_data(m_req.ar)
    );
    async_fifo #(.WIDTH($bits(axi_r_t)), .DEPTH(DEPTH)) u_r (
        .s_clk(m_clk), .s_rst(m_rst), .m_clk(s_clk), .m_rst(s_rst),
        .in_valid(m_rsp.r_valid), .in_ready(m_req.r_ready), .in_data(m_rsp.r),
        .out_valid(s_rsp.r_valid), .out_ready(s_req.r_ready), .out_data(s_rsp.r)
    );
endmodule
