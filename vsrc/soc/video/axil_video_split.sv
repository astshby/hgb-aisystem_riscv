// Module: axil_video_split
// Description: Registered AXI-Lite64 routes; independent AW/W queues preserve ordered write ownership.
module axil_video_split #(
    parameter logic [31:0] VIDEO_BASE = 32'h10070000
) (
    input logic clk, rst,
    input axi_types_pkg::axil_req_t s_req,
    output axi_types_pkg::axil_rsp_t s_rsp,
    output axi_types_pkg::axil_req_t video_req, periph_req,
    input axi_types_pkg::axil_rsp_t video_rsp, periph_rsp
);
    import axi_types_pkg::*;
    typedef struct packed {logic video; axil_a_t address;} routed_a_t;
    routed_a_t aw, ar, write_address_q, read_address_q;
    axil_w_t w, write_data_q;
    logic aw_valid, ar_valid, w_valid, take_write, take_read;
    logic write_active_q, read_active_q, aw_sent_q, w_sent_q, ar_sent_q;
    axil_rsp_t write_response, read_response;
    rv_fifo #(.WIDTH($bits(routed_a_t))) u_aw (
        .clk,.rst,.in_valid(s_req.aw_valid),.in_ready(s_rsp.aw_ready),
        .in_data({s_req.aw.addr[31:12]==VIDEO_BASE[31:12],s_req.aw}),
        .out_valid(aw_valid),.out_ready(take_write),.out_data(aw),.occupancy());
    rv_fifo #(.WIDTH($bits(routed_a_t))) u_ar (
        .clk,.rst,.in_valid(s_req.ar_valid),.in_ready(s_rsp.ar_ready),
        .in_data({s_req.ar.addr[31:12]==VIDEO_BASE[31:12],s_req.ar}),
        .out_valid(ar_valid),.out_ready(take_read),.out_data(ar),.occupancy());
    rv_fifo #(.WIDTH($bits(axil_w_t))) u_w (
        .clk,.rst,.in_valid(s_req.w_valid),.in_ready(s_rsp.w_ready),.in_data(s_req.w),
        .out_valid(w_valid),.out_ready(take_write),.out_data(w),.occupancy());
    assign take_write = !rst && !write_active_q && aw_valid && w_valid;
    assign take_read = !rst && !read_active_q && ar_valid;
    assign write_response = write_address_q.video ? video_rsp : periph_rsp;
    assign read_response = read_address_q.video ? video_rsp : periph_rsp;
    always_comb begin
        video_req='0; periph_req='0;
        s_rsp.b_valid=write_active_q && aw_sent_q && w_sent_q && write_response.b_valid;
        s_rsp.b=write_response.b;
        s_rsp.r_valid=read_active_q && ar_sent_q && read_response.r_valid;
        s_rsp.r=read_response.r;
        if (write_address_q.video) begin
            video_req.aw_valid=write_active_q && !aw_sent_q;
            video_req.aw=write_address_q.address;
            video_req.w_valid=write_active_q && !w_sent_q;
            video_req.w=write_data_q;
            video_req.b_ready=write_active_q && aw_sent_q && w_sent_q && s_req.b_ready;
        end else begin
            periph_req.aw_valid=write_active_q && !aw_sent_q;
            periph_req.aw=write_address_q.address;
            periph_req.w_valid=write_active_q && !w_sent_q;
            periph_req.w=write_data_q;
            periph_req.b_ready=write_active_q && aw_sent_q && w_sent_q && s_req.b_ready;
        end
        if (read_address_q.video) begin
            video_req.ar_valid=read_active_q && !ar_sent_q;
            video_req.ar=read_address_q.address;
            video_req.r_ready=read_active_q && ar_sent_q && s_req.r_ready;
        end else begin
            periph_req.ar_valid=read_active_q && !ar_sent_q;
            periph_req.ar=read_address_q.address;
            periph_req.r_ready=read_active_q && ar_sent_q && s_req.r_ready;
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            write_active_q<=0; read_active_q<=0;
            aw_sent_q<=0; w_sent_q<=0; ar_sent_q<=0;
            write_address_q<='0; read_address_q<='0;
        end else begin
            if (take_write) begin
                write_active_q<=1; write_address_q<=aw; write_data_q<=w;
                aw_sent_q<=0; w_sent_q<=0;
            end
            if (take_read) begin read_active_q<=1; read_address_q<=ar; ar_sent_q<=0; end
            if (write_active_q && !aw_sent_q && write_response.aw_ready) aw_sent_q<=1;
            if (write_active_q && !w_sent_q && write_response.w_ready) w_sent_q<=1;
            if (read_active_q && !ar_sent_q && read_response.ar_ready) ar_sent_q<=1;
            if (s_rsp.b_valid && s_req.b_ready) write_active_q<=0;
            if (s_rsp.r_valid && s_req.r_ready) read_active_q<=0;
        end
    end
endmodule
