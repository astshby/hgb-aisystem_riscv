// Module: axi_error_target
// Description: Returns bounded DECERR bursts and consumes exactly AWLEN+1 write beats.
module axi_error_target (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t req,
    output axi_types_pkg::axi_rsp_t rsp
);
    import axi_types_pkg::*;
    axi_req_t q;
    axi_rsp_t p;
    axi_a_t ar_q, aw_q;
    logic rd_q, wr_q, b_q;
    logic [7:0] ri_q, wi_q;
    axi_register_slice u_channels (.clk, .rst, .s_req(req), .s_rsp(rsp), .m_req(q), .m_rsp(p));
    always_comb begin
        p = '0;
        p.ar_ready = !rd_q;
        p.aw_ready = !wr_q && !b_q;
        p.w_ready = wr_q && !b_q;
        p.r_valid = rd_q;
        p.r = '{id:ar_q.id, data:'0, resp:AXI_DECERR, last:ri_q == ar_q.len};
        p.b_valid = b_q;
        p.b = '{id:aw_q.id, resp:AXI_DECERR};
    end
    always_ff @(posedge clk) begin
        if (rst) begin rd_q <= 0; wr_q <= 0; b_q <= 0; ri_q <= 0; wi_q <= 0; end
        else begin
            if (q.ar_valid && p.ar_ready) begin ar_q <= q.ar; rd_q <= 1; ri_q <= 0; end
            if (p.r_valid && q.r_ready) begin
                ri_q <= ri_q + 1'b1;
                if (p.r.last) rd_q <= 0;
            end
            if (q.aw_valid && p.aw_ready) begin aw_q <= q.aw; wr_q <= 1; wi_q <= 0; end
            if (q.w_valid && p.w_ready) begin
                wi_q <= wi_q + 1'b1;
                if (wi_q == aw_q.len) begin wr_q <= 0; b_q <= 1; end
            end
            if (p.b_valid && q.b_ready) b_q <= 0;
        end
    end
endmodule
