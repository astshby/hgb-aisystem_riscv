// Module: axi_availability_gate
// Description: Registered DDR admission; unavailable targets return errors without waiting for their clock.
module axi_availability_gate (
    input logic clk, rst, available,
    input axi_types_pkg::axi_req_t s_req,
    output axi_types_pkg::axi_rsp_t s_rsp,
    output axi_types_pkg::axi_req_t m_req,
    input axi_types_pkg::axi_rsp_t m_rsp
);
    import axi_types_pkg::*;
    axi_req_t q, error_req;
    axi_rsp_t p, error_rsp;
    axi_a_t read_q, write_q;
    logic read_active_q, write_active_q, read_error_q, write_error_q;
    logic ar_sent_q, aw_sent_q, w_done_q;
    logic [7:0] w_count_q;
    logic ar_ready, aw_ready, w_ready;
    axi_r_t r;
    axi_b_t b;
    logic r_valid, b_valid;
    axi_register_slice u_entry (.clk,.rst,.s_req,.s_rsp,.m_req(q),.m_rsp(p));
    axi_error_target u_error (.clk,.rst,.req(error_req),.rsp(error_rsp));
    assign ar_ready=read_error_q ? error_rsp.ar_ready : m_rsp.ar_ready;
    assign aw_ready=write_error_q ? error_rsp.aw_ready : m_rsp.aw_ready;
    assign w_ready=write_error_q ? error_rsp.w_ready : m_rsp.w_ready;
    assign r=read_error_q ? error_rsp.r : m_rsp.r;
    assign b=write_error_q ? error_rsp.b : m_rsp.b;
    assign r_valid=read_error_q ? error_rsp.r_valid : m_rsp.r_valid;
    assign b_valid=write_error_q ? error_rsp.b_valid : m_rsp.b_valid;
    always_comb begin
        p='0; m_req='0; error_req='0;
        p.ar_ready=!read_active_q;
        p.aw_ready=!write_active_q;
        m_req.ar=read_q; error_req.ar=read_q;
        m_req.aw=write_q; error_req.aw=write_q;
        m_req.w=q.w; error_req.w=q.w;
        m_req.ar_valid=read_active_q && !ar_sent_q && !read_error_q;
        error_req.ar_valid=read_active_q && !ar_sent_q && read_error_q;
        m_req.aw_valid=write_active_q && !aw_sent_q && !write_error_q;
        error_req.aw_valid=write_active_q && !aw_sent_q && write_error_q;
        // 已保存 AW 归属后即可发送 W，不等待 AWREADY，避免通道互等。
        m_req.w_valid=write_active_q && !w_done_q && !write_error_q && q.w_valid;
        error_req.w_valid=write_active_q && !w_done_q && write_error_q && q.w_valid;
        p.w_ready=write_active_q && !w_done_q && w_ready;
        p.r_valid=read_active_q && ar_sent_q && r_valid; p.r=r;
        m_req.r_ready=read_active_q && ar_sent_q && !read_error_q && q.r_ready;
        error_req.r_ready=read_active_q && ar_sent_q && read_error_q && q.r_ready;
        p.b_valid=write_active_q && aw_sent_q && w_done_q && b_valid; p.b=b;
        m_req.b_ready=write_active_q && aw_sent_q && w_done_q && !write_error_q && q.b_ready;
        error_req.b_ready=write_active_q && aw_sent_q && w_done_q && write_error_q && q.b_ready;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            read_active_q<=0;write_active_q<=0;read_error_q<=0;write_error_q<=0;
            ar_sent_q<=0;aw_sent_q<=0;w_done_q<=0;w_count_q<=0;
        end else begin
            if(q.ar_valid && p.ar_ready) begin read_active_q<=1;read_q<=q.ar;read_error_q<=!available;ar_sent_q<=0;end
            if(q.aw_valid && p.aw_ready) begin
                write_active_q<=1;write_q<=q.aw;write_error_q<=!available;aw_sent_q<=0;w_done_q<=0;w_count_q<=0;
            end
            if(read_active_q && !ar_sent_q && ar_ready) ar_sent_q<=1;
            if(write_active_q && !aw_sent_q && aw_ready) aw_sent_q<=1;
            if(q.w_valid && p.w_ready) begin
                w_count_q<=w_count_q+1'b1;
                if(w_count_q==write_q.len) w_done_q<=1;
            end
            if(p.r_valid && q.r_ready && p.r.last) read_active_q<=0;
            if(p.b_valid && q.b_ready) write_active_q<=0;
        end
    end
endmodule
