// Module: axi_to_axil
// Description: Single-transfer 256-to-64 control bridge preserving IDs and rejecting expanded MMIO accesses.
module axi_to_axil (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t s_req,
    output axi_types_pkg::axi_rsp_t s_rsp,
    output axi_types_pkg::axil_req_t m_req,
    input axi_types_pkg::axil_rsp_t m_rsp
);
    import axi_types_pkg::*;
    axi_req_t q;
    axi_rsp_t p;
    axi_a_t ar_q, aw_q;
    axi_w_t w_q;
    logic read_q, write_q, aw_sent_q, w_sent_q;
    logic read_error_q, write_error_q, write_collected_q;
    logic [7:0] drain_q, read_beat_q;
    function automatic logic legal(input axi_a_t a);
        logic timer64;
        timer64 = core_config_pkg::XLEN == 64 && a.addr[31:16] == 16'h0200 &&
                  (a.addr[15:0] == 16'h4000 || a.addr[15:0] == 16'hbff8);
        return a.len == 0 && !a.prot[2] && !a.lock && a.burst == 1 &&
               a.addr[1:0] == 0 && (a.size == 2 || (a.size == 3 && timer64));
    endfunction
    axi_register_slice u_channels (.clk, .rst, .s_req, .s_rsp, .m_req(q), .m_rsp(p));
    always_comb begin
        p = '0; m_req = '0;
        p.ar_ready = !read_q && (legal(q.ar) ? m_rsp.ar_ready : 1'b1);
        m_req.ar_valid = q.ar_valid && !read_q && legal(q.ar);
        m_req.ar = '{addr:q.ar.addr, prot:q.ar.prot};
        p.r_valid = read_q && (read_error_q || m_rsp.r_valid);
        p.r = '{id:ar_q.id, resp:read_error_q ? AXI_SLVERR : m_rsp.r.resp, last:!read_error_q || read_beat_q==ar_q.len,
                data:read_error_q ? '0 : 256'(m_rsp.r.data) << (64*int'(ar_q.addr[4:3]))};
        m_req.r_ready = read_q && !read_error_q && q.r_ready;
        p.aw_ready = !write_q;
        p.w_ready = write_q && !write_collected_q;
        m_req.aw_valid = write_q && write_collected_q && !write_error_q && !aw_sent_q;
        m_req.aw = '{addr:aw_q.addr, prot:aw_q.prot};
        m_req.w_valid = write_q && write_collected_q && !write_error_q && !w_sent_q;
        m_req.w = '{data:64'(w_q.data >> (64*int'(aw_q.addr[4:3]))),
                    strb:8'(w_q.strb >> (8*int'(aw_q.addr[4:3])))};
        p.b_valid = write_q && write_collected_q && (write_error_q || (aw_sent_q && w_sent_q && m_rsp.b_valid));
        p.b = '{id:aw_q.id, resp:write_error_q ? AXI_SLVERR : m_rsp.b};
        m_req.b_ready = write_q && aw_sent_q && w_sent_q && q.b_ready;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            read_q <= 0; write_q <= 0; aw_sent_q <= 0; w_sent_q <= 0;
            read_error_q <= 0; write_error_q <= 0; write_collected_q <= 0; drain_q <= 0; read_beat_q <= 0;
        end else begin
            if (q.ar_valid && p.ar_ready) begin read_q <= 1; ar_q <= q.ar; read_error_q <= !legal(q.ar); read_beat_q <= 0; end
            if (p.r_valid && q.r_ready) begin
                read_beat_q <= read_beat_q+1'b1;
                if (p.r.last) read_q <= 0;
            end
            if (q.aw_valid && p.aw_ready) begin
                write_q <= 1; aw_q <= q.aw; write_error_q <= !legal(q.aw);
                write_collected_q <= 0; aw_sent_q <= 0; w_sent_q <= 0; drain_q <= 0;
            end
            if (q.w_valid && p.w_ready) begin
                w_q <= q.w; drain_q <= drain_q+1'b1;
                if (drain_q == aw_q.len) write_collected_q <= 1;
                if (q.w.last != (drain_q == aw_q.len) ||
                    |(q.w.strb & ~((32'hffffffff >> (32-(1<<aw_q.size))) << aw_q.addr[4:0])))
                    write_error_q <= 1;
            end
            if (m_req.aw_valid && m_rsp.aw_ready) aw_sent_q <= 1;
            if (m_req.w_valid && m_rsp.w_ready) w_sent_q <= 1;
            if (p.b_valid && q.b_ready) write_q <= 0;
        end
    end
endmodule
