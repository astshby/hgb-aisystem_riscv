// Module: cache_axi_adapter
// Description: One AXI master for scalar misses and cache/DMA blocks with distinct local IDs.
module cache_axi_adapter (
    input logic clk, rst,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    input logic rd_cmd_valid,
    output logic rd_cmd_ready,
    input block_types_pkg::block_cmd_t rd_cmd,
    output logic rd_valid,
    input logic rd_ready,
    output block_types_pkg::block_r_t rd_data,
    input logic wr_cmd_valid,
    output logic wr_cmd_ready,
    input block_types_pkg::block_cmd_t wr_cmd,
    input logic wr_valid,
    output logic wr_ready,
    input block_types_pkg::block_w_t wr_data,
    output logic wr_rsp_valid,
    input logic wr_rsp_ready,
    output block_types_pkg::block_b_t wr_rsp,
    output axi_types_pkg::axi_req_t axi_req,
    input axi_types_pkg::axi_rsp_t axi_rsp
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import axi_types_pkg::*;
    bus_req_t scalar_q;
    bus_rsp_t scalar_response_q;
    logic scalar_active_q, scalar_aw_q, scalar_ar_q, scalar_rsp_q;
    logic block_rd_q, block_wr_q;
    logic ar_lock_q, aw_lock_q, ar_block_q, aw_block_q;
    logic select_ar_block, select_aw_block;
    logic w_owner_valid, w_owner_ready, w_owner_pop, w_owner;
    logic [1:0] w_occupancy;
    logic aw_fire, ar_fire, w_fire;
    axi_req_t a;
    axi_rsp_t b;
    function automatic bus_error_e bus_error(input axi_resp_e e);
        return e == AXI_OKAY ? BUS_OK : e == AXI_DECERR ? BUS_DECERR : BUS_SLVERR;
    endfunction
    function automatic axi_a_t address(input block_cmd_t c, input axi_id_t id);
        return '{id:id, addr:32'(c.addr), len:c.len, size:c.size, burst:2'b01,
                 prot:{c.execute,2'b00}, default:'0};
    endfunction
    axi_register_slice u_exit (.clk, .rst, .s_req(a), .s_rsp(b), .m_req(axi_req), .m_rsp(axi_rsp));
    // W 按已接受 AW 的源序列选择，标量写和 Cache 写回不能交织。
    rv_fifo #(.WIDTH(1), .DEPTH(2)) u_w_owner (
        .clk, .rst, .in_valid(aw_fire), .in_ready(w_owner_ready), .in_data(select_aw_block),
        .out_valid(w_owner_valid), .out_ready(w_owner_pop), .out_data(w_owner), .occupancy(w_occupancy)
    );
    assign req_ready = !rst && !scalar_active_q;
    assign rsp_valid = !rst && scalar_rsp_q;
    assign response = scalar_response_q;
    assign select_ar_block = ar_lock_q ? ar_block_q : !(scalar_active_q && !scalar_q.write && !scalar_ar_q && !scalar_rsp_q);
    assign select_aw_block = aw_lock_q ? aw_block_q : !(scalar_active_q && scalar_q.write && !scalar_aw_q && !scalar_rsp_q);
    assign ar_fire = a.ar_valid && b.ar_ready;
    assign aw_fire = a.aw_valid && b.aw_ready;
    assign w_fire = a.w_valid && b.w_ready;
    assign w_owner_pop = w_fire && a.w.last;
    always_comb begin
        a = '0;
        a.ar_valid = select_ar_block ? rd_cmd_valid && !block_rd_q :
                     scalar_active_q && !scalar_q.write && !scalar_ar_q && !scalar_rsp_q;
        a.ar = select_ar_block ? address(rd_cmd, 1) :
               address('{addr:scalar_q.addr, size:3'(scalar_q.size), len:0, execute:scalar_q.execute}, 0);
        a.aw_valid = w_owner_ready && (select_aw_block ? wr_cmd_valid && !block_wr_q :
                     scalar_active_q && scalar_q.write && !scalar_aw_q && !scalar_rsp_q);
        a.aw = select_aw_block ? address(wr_cmd, 1) :
               address('{addr:scalar_q.addr, size:3'(scalar_q.size), len:0, execute:scalar_q.execute}, 0);
        a.w_valid = w_owner_valid && (w_owner ? wr_valid : 1'b1);
        a.w = w_owner ? axi_w_t'(wr_data) :
              '{data:256'(scalar_q.wdata) << ((int'(scalar_q.addr[4:0])/DBUS_BYTES)*XLEN),
                strb:32'(scalar_q.wstrb) << ((int'(scalar_q.addr[4:0])/DBUS_BYTES)*DBUS_BYTES), last:1'b1};
        a.r_ready = b.r.id[0] ? rd_ready : !scalar_rsp_q;
        a.b_ready = b.b.id[0] ? wr_rsp_ready : !scalar_rsp_q;
        rd_cmd_ready = !rst && select_ar_block && !block_rd_q && b.ar_ready;
        wr_cmd_ready = !rst && select_aw_block && !block_wr_q && w_owner_ready && b.aw_ready;
        wr_ready = !rst && w_owner_valid && w_owner && b.w_ready;
        rd_valid = !rst && b.r_valid && b.r.id[0];
        rd_data = '{data:b.r.data, error:bus_error(b.r.resp), last:b.r.last};
        wr_rsp_valid = !rst && b.b_valid && b.b.id[0];
        wr_rsp = '{error:bus_error(b.b.resp)};
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            scalar_active_q <= 0; scalar_aw_q <= 0; scalar_ar_q <= 0; scalar_rsp_q <= 0;
            block_rd_q <= 0; block_wr_q <= 0;
            ar_lock_q <= 0; aw_lock_q <= 0; ar_block_q <= 0; aw_block_q <= 0;
        end else begin
            if (req_valid && req_ready) begin
                scalar_q <= request; scalar_active_q <= 1; scalar_aw_q <= 0; scalar_ar_q <= 0;
                // RV64 高位不能在物理地址端静默丢失。
                if ((64'(request.addr) >> 32) != 0) begin
                    scalar_rsp_q <= 1;
                    scalar_response_q <= '{rdata:'0, error:BUS_DECERR};
                end
            end
            if (rsp_valid && rsp_ready) begin scalar_rsp_q <= 0; scalar_active_q <= 0; end
            if (a.ar_valid) begin ar_lock_q <= !b.ar_ready; ar_block_q <= select_ar_block; end
            if (a.aw_valid) begin aw_lock_q <= !b.aw_ready; aw_block_q <= select_aw_block; end
            if (ar_fire) begin
                if (select_ar_block) block_rd_q <= 1; else scalar_ar_q <= 1;
            end
            if (aw_fire) begin
                if (select_aw_block) block_wr_q <= 1; else scalar_aw_q <= 1;
            end
            if (b.r_valid && a.r_ready) begin
                if (b.r.id[0]) begin if (b.r.last) block_rd_q <= 0; end
                else begin
                    scalar_rsp_q <= 1;
                    scalar_response_q <= '{rdata:xlen_t'(b.r.data >> ((int'(scalar_q.addr[4:0])/DBUS_BYTES)*XLEN)),
                                           error:bus_error(b.r.resp)};
                end
            end
            if (b.b_valid && a.b_ready) begin
                if (b.b.id[0]) block_wr_q <= 0;
                else begin scalar_rsp_q <= 1; scalar_response_q <= '{rdata:'0, error:bus_error(b.b.resp)}; end
            end
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (rst) rd_cmd_valid |-> (64'(rd_cmd.addr) >> 32) == 0);
    assert property (@(posedge clk) disable iff (rst) wr_cmd_valid |-> (64'(wr_cmd.addr) >> 32) == 0);
`endif
endmodule
