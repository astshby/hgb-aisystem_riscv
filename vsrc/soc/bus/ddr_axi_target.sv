// Module: ddr_axi_target
// Description: AXI IDs and ownership to a bounded native DDR block backend with calibration admission checks.
module ddr_axi_target (
    input logic clk, rst, memory_ready,
    input axi_types_pkg::axi_req_t axi_req,
    output axi_types_pkg::axi_rsp_t axi_rsp,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data,
    output logic wr_cmd_valid,
    input logic wr_cmd_ready,
    output block_types_pkg::block_cmd_t wr_cmd,
    output logic wr_valid,
    input logic wr_ready,
    output block_types_pkg::block_w_t wr_data,
    input logic wr_rsp_valid,
    output logic wr_rsp_ready,
    input block_types_pkg::block_b_t wr_rsp
);
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    axi_req_t q;
    axi_rsp_t p;
    axi_a_t read_q, write_q;
    logic reading_q, writing_q, read_sent_q, write_sent_q, write_data_done_q;
    logic [7:0] read_beat_q, write_beat_q;
    axi_resp_e read_error_q, write_error_q;
    function automatic axi_resp_e error_code(input bus_error_e e);
        return e == BUS_OK ? AXI_OKAY : e == BUS_DECERR ? AXI_DECERR : AXI_SLVERR;
    endfunction
    function automatic axi_resp_e admission(input axi_a_t a);
        if (!memory_ready) return AXI_DECERR;
        if (a.lock || a.burst != 1 || a.len > 3 || a.size > 5 ||
            (a.len != 0 && a.size != 5) || (a.addr & ((32'd1 << a.size)-1)) != 0) return AXI_SLVERR;
        return AXI_OKAY;
    endfunction
    axi_register_slice u_channels (.clk,.rst,.s_req(axi_req),.s_rsp(axi_rsp),.m_req(q),.m_rsp(p));
    assign rd_cmd_valid = reading_q && !read_sent_q && read_error_q == AXI_OKAY;
    assign rd_cmd = '{addr:core_types_pkg::xlen_t'(read_q.addr),len:read_q.len,size:read_q.size,execute:read_q.prot[2]};
    assign wr_cmd_valid = writing_q && !write_sent_q && write_error_q == AXI_OKAY;
    assign wr_cmd = '{addr:core_types_pkg::xlen_t'(write_q.addr),len:write_q.len,size:write_q.size,execute:write_q.prot[2]};
    assign wr_valid = writing_q && write_sent_q && !write_data_done_q && q.w_valid;
    assign wr_data = block_types_pkg::block_w_t'(q.w);
    assign rd_ready = reading_q && read_sent_q && q.r_ready;
    assign wr_rsp_ready = writing_q && write_sent_q && write_data_done_q && q.b_ready;
    always_comb begin
        p = '0;
        p.ar_ready = !reading_q;
        p.aw_ready = !writing_q;
        p.w_ready = writing_q && !write_data_done_q && (write_error_q != AXI_OKAY || (write_sent_q && wr_ready));
        p.r_valid = reading_q && (read_error_q != AXI_OKAY || (read_sent_q && rd_valid));
        p.r = '{id:read_q.id,data:read_error_q != AXI_OKAY ? '0 : rd_data.data,
                resp:read_error_q != AXI_OKAY ? read_error_q : error_code(rd_data.error),
                last:read_error_q != AXI_OKAY ? read_beat_q == read_q.len : rd_data.last};
        p.b_valid = writing_q && write_data_done_q && (write_error_q != AXI_OKAY || (write_sent_q && wr_rsp_valid));
        p.b = '{id:write_q.id,resp:write_error_q != AXI_OKAY ? write_error_q : error_code(wr_rsp.error)};
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            reading_q <= 0; writing_q <= 0; read_sent_q <= 0; write_sent_q <= 0; write_data_done_q <= 0;
            read_beat_q <= 0; write_beat_q <= 0; read_error_q <= AXI_OKAY; write_error_q <= AXI_OKAY;
        end else begin
            if (q.ar_valid && p.ar_ready) begin
                read_q <= q.ar; reading_q <= 1; read_sent_q <= 0; read_beat_q <= 0; read_error_q <= admission(q.ar);
            end
            if (q.aw_valid && p.aw_ready) begin
                write_q <= q.aw; writing_q <= 1; write_sent_q <= 0; write_beat_q <= 0;
                write_data_done_q <= 0; write_error_q <= admission(q.aw);
            end
            if (rd_cmd_valid && rd_cmd_ready) read_sent_q <= 1;
            if (wr_cmd_valid && wr_cmd_ready) write_sent_q <= 1;
            if (q.w_valid && p.w_ready) begin
                write_beat_q <= write_beat_q+1'b1;
                if (write_beat_q == write_q.len) write_data_done_q <= 1;
            end
            if (p.r_valid && q.r_ready) begin
                read_beat_q <= read_beat_q+1'b1;
                if (p.r.last) reading_q <= 0;
            end
            if (p.b_valid && q.b_ready) writing_q <= 0;
        end
    end
endmodule
