// Module: axi_native_memory_model
// Description: AXI-to-Pango integration model with unthrottled native read pulses and immediate write consumption.
module axi_native_memory_model #(parameter int BYTES=262144) (
    input logic clk, rst, stall, memory_ready,
    input axi_types_pkg::axi_req_t req,
    output axi_types_pkg::axi_rsp_t rsp
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    block_cmd_t rd_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t wr_cmd;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic [27:0] axi_awaddr, axi_araddr;
    logic axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_arvalid, axi_awready, axi_arready, axi_wready;
    logic [3:0] axi_awuser_id, axi_awlen, axi_aruser_id, axi_arlen, axi_rid;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;
    logic axi_rlast, axi_rvalid;
    byte unsigned memory [BYTES], expected [BYTES];
    int checks = 0, cycle_q = 0, ar_count = 0, aw_count = 0, overlaps = 0;
    int immediate_reads = 0, immediate_writes = 0, sequence_number = 0;
    logic read_pending_q = 0, write_pending_q = 0, immediate = 1, pause_read = 0;
    int read_left_q = 0, write_left_q = 0, read_delay_q = 0, read_index_q = 0;
    int read_addr_q = 0, write_addr_q = 0, read_address, write_address, actual_read_beats;
    int malformed = 0;
    logic ar_fire, aw_fire, read_pulse, write_pulse;
    pango_block_bridge #(.DDR_BYTES(BYTES)) dut (.*);
    assign axi_arready = !rst && !stall && !read_pending_q && cycle_q%4 != 2;
    assign axi_awready = !rst && !stall && !write_pending_q && cycle_q%4 != 0;
    assign ar_fire = axi_arvalid && axi_arready;
    assign aw_fire = axi_awvalid && axi_awready;
    assign axi_rvalid = !rst && !pause_read && ((read_pending_q && read_delay_q == 0) || (immediate && ar_fire));
    assign axi_wready = !rst && (write_pending_q || aw_fire) && (immediate || cycle_q%3 != 1);
    assign read_pulse = axi_rvalid;
    assign write_pulse = axi_wready;
    always_comb begin
        actual_read_beats = malformed == 1 ? 1 : int'(axi_arlen)+1+(malformed == 2 ? 2 : 0);
        read_address = read_pending_q ? read_addr_q : int'(axi_araddr)*4;
        write_address = write_pending_q ? write_addr_q : int'(axi_awaddr)*4;
        axi_rlast = read_pending_q ? read_left_q == 1 : actual_read_beats == 1;
        axi_rid = malformed == 3 && read_index_q == 1 ? 4'd1 : 4'd0;
        for (int b = 0; b < 32; b++)
            axi_rdata[b*8 +: 8] = read_address+b < BYTES ? memory[read_address+b] : 8'd0;
    end

    // 原生接口没有RREADY/WVALID：模型发脉冲后不会重发，写数据只在WREADY沿消费一次。
    // 模型状态用NBA，激励在下降沿改变；独立字节数组提供读写真值。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0; read_pending_q <= 0; write_pending_q <= 0;
            read_left_q <= 0; write_left_q <= 0; read_delay_q <= 0; read_index_q <= 0;
            read_addr_q <= 0; write_addr_q <= 0;
            ar_count <= 0; aw_count <= 0; overlaps <= 0;
            immediate_reads <= 0; immediate_writes <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            if (ar_fire) begin
                assert (axi_aruser_id == 0 && !axi_aruser_ap && axi_araddr[2:0] == 0 &&
                        int'(axi_araddr[9:0])*4 + (int'(axi_arlen)+1)*32 <= 4096)
                    else $fatal(1, "bad native AR address/length");
                ar_count <= ar_count + 1;
                read_pending_q <= 1;
                read_addr_q <= int'(axi_araddr)*4;
                read_left_q <= actual_read_beats;
                read_index_q <= 0;
                read_delay_q <= 3;
            end
            if (read_pending_q && read_delay_q != 0) read_delay_q <= read_delay_q-1;
            if (read_pulse) begin
                if (ar_fire) immediate_reads <= immediate_reads + 1;
                if (axi_rlast) read_pending_q <= 0;
                else begin
                    read_pending_q <= 1;
                    read_addr_q <= read_address + 32;
                    read_left_q <= (read_pending_q ? read_left_q : actual_read_beats)-1;
                    read_index_q <= read_pending_q ? read_index_q+1 : 1;
                    read_delay_q <= immediate ? 0 : cycle_q%3;
                end
            end
            if (aw_fire) begin
                assert (axi_awuser_id == 0 && !axi_awuser_ap && axi_awaddr[2:0] == 0 &&
                        int'(axi_awaddr[9:0])*4 + (int'(axi_awlen)+1)*32 <= 4096)
                    else $fatal(1, "bad native AW address/length");
                aw_count <= aw_count + 1;
                write_pending_q <= 1;
                write_addr_q <= int'(axi_awaddr)*4;
                write_left_q <= int'(axi_awlen)+1;
            end
            if (write_pulse) begin
                if (aw_fire) immediate_writes <= immediate_writes + 1;
                for (int b = 0; b < 32; b++) if (axi_wstrb[b]) memory[write_address+b] <= axi_wdata[b*8 +: 8];
                if ((write_pending_q ? write_left_q : int'(axi_awlen)+1) == 1) write_pending_q <= 0;
                else begin
                    write_pending_q <= 1;
                    write_addr_q <= write_address + 32;
                    write_left_q <= (write_pending_q ? write_left_q : int'(axi_awlen)+1)-1;
                end
            end
            if (read_pending_q && write_pending_q) overlaps <= overlaps+1;
        end
    end
    ddr_axi_target u_axi (.clk,.rst,.memory_ready,.axi_req(req),.axi_rsp(rsp),
        .rd_cmd_valid,.rd_cmd_ready,.rd_cmd,.rd_valid,.rd_ready,.rd_data,
        .wr_cmd_valid,.wr_cmd_ready,.wr_cmd,.wr_valid,.wr_ready,.wr_data,.wr_rsp_valid,.wr_rsp_ready,.wr_rsp);
endmodule
