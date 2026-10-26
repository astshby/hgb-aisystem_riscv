// Module: axi_bus_target_reference
// Description: Frozen 6cb7535 AXI target for cycle comparison of running beat addresses.
module axi_bus_target_reference #(
    parameter bit READ_ONLY = 0,
    parameter int LOCAL_BYTES = core_config_pkg::DBUS_BYTES
) (
    input logic clk, rst,
    input axi_types_pkg::axi_req_t axi_req,
    output axi_types_pkg::axi_rsp_t axi_rsp,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::bus_rsp_t response
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import axi_types_pkg::*;
    axi_req_t q;
    axi_rsp_t p;
    axi_a_t read_q, write_q;
    logic read_active_q, write_active_q, pending_q, pending_write_q, next_write_q;
    logic [7:0] read_beat_q, write_beat_q;
    logic [5:0] read_offset_q, write_offset_q;
    logic [255:0] read_data_q;
    axi_resp_e read_error_q, write_error_q;
    logic r_valid_q, b_valid_q;
    axi_r_t r_q;
    axi_b_t b_q;
    logic choose_write, choose_read, bad_write, skip_write, local_fire;
    logic [31:0] read_addr, write_addr, allowed_strb;
    logic [5:0] read_bytes, write_bytes, read_step, write_step;
    logic read_end, write_end, write_w_fire;
    axi_resp_e local_error;
    logic [255:0] merged_read;
    axi_register_slice u_channels (.clk, .rst, .s_req(axi_req), .s_rsp(axi_rsp), .m_req(q), .m_rsp(p));
    assign read_addr = read_q.addr + (32'(read_beat_q) << read_q.size) + 32'(read_offset_q);
    assign write_addr = write_q.addr + (32'(write_beat_q) << write_q.size) + 32'(write_offset_q);
    assign read_bytes = 6'd1 << read_q.size;
    assign write_bytes = 6'd1 << write_q.size;
    assign read_step = read_q.prot[2] ? 6'd4 : 6'(LOCAL_BYTES);
    assign write_step = 6'(LOCAL_BYTES);
    assign read_end = read_offset_q + read_step >= read_bytes;
    assign write_end = write_offset_q + write_step >= write_bytes;
    assign allowed_strb = (32'hffffffff >> (32-int'(write_bytes))) << write_q.addr[4:0];
    assign bad_write = READ_ONLY ||
                       (q.w.last != (write_beat_q == write_q.len)) || |(q.w.strb & ~allowed_strb);
    assign local_error = response.error == BUS_OK ? AXI_OKAY :
                         response.error == BUS_DECERR ? AXI_DECERR : AXI_SLVERR;
    assign choose_write = !pending_q && write_active_q && q.w_valid && !b_valid_q &&
                          (next_write_q || !read_active_q || r_valid_q);
    assign choose_read = !pending_q && read_active_q && !r_valid_q && !choose_write;
    assign skip_write = choose_write && (bad_write ||
                        (q.w.strb >> (DBUS_BYTES * (int'(write_addr[4:0]) / DBUS_BYTES))) == 0);
    assign req_valid = !rst && ((choose_write && !skip_write) || choose_read);
    assign local_fire = req_valid && req_ready;
    assign rsp_ready = !rst && pending_q;
    assign write_w_fire = skip_write || (pending_q && pending_write_q && rsp_valid && write_end);
    always_comb begin
        request = '0;
        request.write = choose_write;
        request.execute = choose_read && read_q.prot[2];
        request.addr = xlen_t'(choose_write ? write_addr : read_addr);
        request.size = mem_size_e'(choose_write ?
            (int'(write_q.size) > $clog2(LOCAL_BYTES) ? 3'($clog2(LOCAL_BYTES)) : write_q.size) :
            (read_q.prot[2] && read_q.size > 2 ? 3'd2 :
             int'(read_q.size) > $clog2(LOCAL_BYTES) ? 3'($clog2(LOCAL_BYTES)) : read_q.size));
        request.wdata = xlen_t'(q.w.data >> ((int'(write_addr[4:0]) / DBUS_BYTES) * XLEN));
        request.wstrb = DBUS_BYTES'(q.w.strb >> ((int'(write_addr[4:0]) / DBUS_BYTES) * DBUS_BYTES));
        p = '0;
        p.ar_ready = !rst && !read_active_q && !r_valid_q;
        p.aw_ready = !rst && !write_active_q && !b_valid_q;
        p.w_ready = !rst && write_w_fire;
        p.r_valid = !rst && r_valid_q; p.r = r_q;
        p.b_valid = !rst && b_valid_q; p.b = b_q;
        merged_read = read_data_q;
        // 32 位设备在 RV64 下仍逐字访问；只填当前字，不能覆盖同 beat 的相邻读回值。
        merged_read[(int'(read_addr[4:0]) / LOCAL_BYTES)*(8*LOCAL_BYTES) +: 8*LOCAL_BYTES] =
            (8*LOCAL_BYTES)'(response.rdata >>
                (8*(int'(read_addr[$clog2(DBUS_BYTES)-1:0]) / LOCAL_BYTES)*LOCAL_BYTES));
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            read_active_q <= 0; write_active_q <= 0; pending_q <= 0;
            pending_write_q <= 0; next_write_q <= 0; r_valid_q <= 0; b_valid_q <= 0;
            read_offset_q <= 0; write_offset_q <= 0; read_beat_q <= 0; write_beat_q <= 0;
            read_error_q <= AXI_OKAY; write_error_q <= AXI_OKAY;
        end else begin
            if (q.ar_valid && p.ar_ready) begin
                read_q <= q.ar; read_active_q <= 1; read_beat_q <= 0;
                read_offset_q <= 0; read_data_q <= '0; read_error_q <= AXI_OKAY;
            end
            if (q.aw_valid && p.aw_ready) begin
                write_q <= q.aw; write_active_q <= 1; write_beat_q <= 0;
                write_offset_q <= 0; write_error_q <= AXI_OKAY;
            end
            if (q.r_ready && r_valid_q) begin
                r_valid_q <= 0;
                if (r_q.last) read_active_q <= 0;
                else begin
                    read_beat_q <= read_beat_q + 1'b1;
                    read_offset_q <= 0; read_data_q <= '0; read_error_q <= AXI_OKAY;
                end
            end
            if (q.b_ready && b_valid_q) begin b_valid_q <= 0; write_active_q <= 0; end
            if (local_fire) begin pending_q <= 1; pending_write_q <= choose_write; end
            if (pending_q && rsp_valid) begin
                pending_q <= 0;
                next_write_q <= !pending_write_q;
                if (pending_write_q) begin
                    if (local_error != AXI_OKAY) write_error_q <= local_error;
                    if (!write_end) write_offset_q <= write_offset_q + write_step;
                end else begin
                    read_data_q <= merged_read;
                    if (local_error != AXI_OKAY) read_error_q <= local_error;
                    if (read_end) begin
                        r_valid_q <= 1;
                        r_q <= '{id:read_q.id, data:merged_read,
                                 resp:(read_error_q == AXI_OKAY ? local_error : read_error_q),
                                 last:(read_beat_q == read_q.len)};
                    end else read_offset_q <= read_offset_q + read_step;
                end
            end
            if (write_w_fire) begin
                write_offset_q <= 0;
                next_write_q <= 0;
                if (bad_write) write_error_q <= AXI_SLVERR;
                if (write_beat_q == write_q.len) begin
                    b_valid_q <= 1;
                    b_q <= '{id:write_q.id, resp:(bad_write ? AXI_SLVERR :
                             write_error_q != AXI_OKAY ? write_error_q :
                             skip_write ? AXI_OKAY : local_error)};
                end else write_beat_q <= write_beat_q + 1'b1;
            end
        end
    end
endmodule
