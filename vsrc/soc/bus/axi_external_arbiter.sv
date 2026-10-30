// Module: axi_external_arbiter
// Description: Two external AXI masters share one existing SoC master slot with independent read/write owners.
module axi_external_arbiter (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t s_req [2],
    output axi_types_pkg::axi_rsp_t s_rsp [2],
    output axi_types_pkg::axi_req_t m_req,
    input axi_types_pkg::axi_rsp_t m_rsp
);
    import axi_types_pkg::*;
    typedef enum logic [1:0] {IDLE, ADDRESS, DATA, RESPONSE} state_t;
    state_t read_state_q, write_state_q;
    logic read_owner_q, write_owner_q, read_next_q, write_next_q;
    logic read_owner, write_owner, read_selected, write_selected;
    logic [7:0] write_len_q, write_beat_q;
    logic ar_fire, aw_fire, w_fire, rlast_fire, b_fire;

    // 在突发边界轮询。被反压的地址保存 owner，不能由后来的请求替换。
    // 每方向只接纳一笔，原本地 ID 无需新增位；另一个方向仍可独立前进。
    always_comb begin
        read_owner = read_owner_q;
        write_owner = write_owner_q;
        read_selected = 1'b0;
        write_selected = 1'b0;
        if (read_state_q == IDLE) begin
            read_owner = s_req[read_next_q].ar_valid ? read_next_q : !read_next_q;
            read_selected = s_req[read_owner].ar_valid;
        end else if (read_state_q == ADDRESS) read_selected = 1'b1;
        if (write_state_q == IDLE) begin
            write_owner = s_req[write_next_q].aw_valid ? write_next_q : !write_next_q;
            write_selected = s_req[write_owner].aw_valid;
        end else if (write_state_q == ADDRESS) write_selected = 1'b1;
        m_req = '0;
        for (int m = 0; m < 2; m++) s_rsp[m] = '0;
        if (!rst) begin
            if (read_selected) begin
                m_req.ar_valid = s_req[read_owner].ar_valid;
                m_req.ar = s_req[read_owner].ar;
                s_rsp[read_owner].ar_ready = m_rsp.ar_ready;
            end
            if (read_state_q == RESPONSE) begin
                s_rsp[read_owner_q].r_valid = m_rsp.r_valid;
                s_rsp[read_owner_q].r = m_rsp.r;
                m_req.r_ready = s_req[read_owner_q].r_ready;
            end
            if (write_selected) begin
                m_req.aw_valid = s_req[write_owner].aw_valid;
                m_req.aw = s_req[write_owner].aw;
                s_rsp[write_owner].aw_ready = m_rsp.aw_ready;
            end
            if (write_state_q == DATA) begin
                m_req.w_valid = s_req[write_owner_q].w_valid;
                m_req.w = s_req[write_owner_q].w;
                s_rsp[write_owner_q].w_ready = m_rsp.w_ready;
            end
            if (write_state_q == RESPONSE) begin
                s_rsp[write_owner_q].b_valid = m_rsp.b_valid;
                s_rsp[write_owner_q].b = m_rsp.b;
                m_req.b_ready = s_req[write_owner_q].b_ready;
            end
        end
    end
    assign ar_fire = m_req.ar_valid && m_rsp.ar_ready;
    assign aw_fire = m_req.aw_valid && m_rsp.aw_ready;
    assign w_fire = m_req.w_valid && m_rsp.w_ready;
    assign rlast_fire = m_rsp.r_valid && m_req.r_ready && m_rsp.r.last;
    assign b_fire = m_rsp.b_valid && m_req.b_ready;
    always_ff @(posedge clk) begin
        if (rst) begin
            read_state_q <= IDLE;
            write_state_q <= IDLE;
            read_owner_q <= 1'b0;
            write_owner_q <= 1'b0;
            read_next_q <= 1'b0;
            write_next_q <= 1'b0;
            write_len_q <= '0;
            write_beat_q <= '0;
        end else begin
            if (read_selected) begin
                read_owner_q <= read_owner;
                read_state_q <= ar_fire ? RESPONSE : ADDRESS;
            end else if (rlast_fire) begin
                read_state_q <= IDLE;
                read_next_q <= !read_owner_q;
            end
            if (write_selected) begin
                write_owner_q <= write_owner;
                if (aw_fire) begin
                    write_state_q <= DATA;
                    write_len_q <= m_req.aw.len;
                    write_beat_q <= '0;
                end else write_state_q <= ADDRESS;
            end else if (w_fire) begin
                if (write_beat_q == write_len_q) write_state_q <= RESPONSE;
                else write_beat_q <= write_beat_q + 1'b1;
            end else if (b_fire) begin
                write_state_q <= IDLE;
                write_next_q <= !write_owner_q;
            end
        end
    end
endmodule
