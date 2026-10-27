// Module: axi_register_slice
// Description: Five independent buffered AXI channels; payload and valid have separate ownership.
module axi_register_slice #(parameter int DEPTH = 2) (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t s_req,
    output axi_types_pkg::axi_rsp_t s_rsp,
    output axi_types_pkg::axi_req_t m_req,
    input axi_types_pkg::axi_rsp_t m_rsp
);
    import axi_types_pkg::*;
    rv_fifo #(.WIDTH($bits(axi_a_t)), .DEPTH(DEPTH)) u_aw (
        .clk, .rst,
        .in_valid(s_req.aw_valid), .in_ready(s_rsp.aw_ready), .in_data(s_req.aw),
        .out_valid(m_req.aw_valid), .out_ready(m_rsp.aw_ready), .out_data(m_req.aw), .occupancy()
    );
    rv_fifo #(.WIDTH($bits(axi_w_t)), .DEPTH(DEPTH)) u_w (
        .clk, .rst,
        .in_valid(s_req.w_valid), .in_ready(s_rsp.w_ready), .in_data(s_req.w),
        .out_valid(m_req.w_valid), .out_ready(m_rsp.w_ready), .out_data(m_req.w), .occupancy()
    );
    rv_fifo #(.WIDTH($bits(axi_b_t)), .DEPTH(DEPTH)) u_b (
        .clk, .rst,
        .in_valid(m_rsp.b_valid), .in_ready(m_req.b_ready), .in_data(m_rsp.b),
        .out_valid(s_rsp.b_valid), .out_ready(s_req.b_ready), .out_data(s_rsp.b), .occupancy()
    );
    rv_fifo #(.WIDTH($bits(axi_a_t)), .DEPTH(DEPTH)) u_ar (
        .clk, .rst,
        .in_valid(s_req.ar_valid), .in_ready(s_rsp.ar_ready), .in_data(s_req.ar),
        .out_valid(m_req.ar_valid), .out_ready(m_rsp.ar_ready), .out_data(m_req.ar), .occupancy()
    );
    rv_fifo #(.WIDTH($bits(axi_r_t)), .DEPTH(DEPTH)) u_r (
        .clk, .rst,
        .in_valid(m_rsp.r_valid), .in_ready(m_req.r_ready), .in_data(m_rsp.r),
        .out_valid(s_rsp.r_valid), .out_ready(s_req.r_ready), .out_data(s_rsp.r), .occupancy()
    );
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (rst) s_req.aw_valid && !s_rsp.aw_ready |=> rst || (s_req.aw_valid && $stable(s_req.aw)));
    assert property (@(posedge clk) disable iff (rst) s_req.ar_valid && !s_rsp.ar_ready |=> rst || (s_req.ar_valid && $stable(s_req.ar)));
    assert property (@(posedge clk) disable iff (rst) s_req.w_valid && !s_rsp.w_ready |=> rst || (s_req.w_valid && $stable(s_req.w)));
    assert property (@(posedge clk) disable iff (rst) m_rsp.r_valid && !m_req.r_ready |=> rst || (m_rsp.r_valid && $stable(m_rsp.r)));
    assert property (@(posedge clk) disable iff (rst) m_rsp.b_valid && !m_req.b_ready |=> rst || (m_rsp.b_valid && $stable(m_rsp.b)));
`endif
endmodule
