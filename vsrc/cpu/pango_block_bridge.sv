// Module: pango_block_bridge
// Description: Buffered bounded block transfers to the Pango native 256-bit DDR port, without AXI B/RREADY semantics.
module pango_block_bridge #(
    parameter int unsigned DDR_BYTES = 512 * 1024 * 1024
) (
    input logic clk, rst,
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
    output logic [27:0] axi_awaddr,
    output logic axi_awuser_ap,
    output logic [3:0] axi_awuser_id, axi_awlen,
    output logic axi_awvalid,
    input logic axi_awready,
    output logic [255:0] axi_wdata,
    output logic [31:0] axi_wstrb,
    input logic axi_wready,
    output logic [27:0] axi_araddr,
    output logic axi_aruser_ap,
    output logic [3:0] axi_aruser_id, axi_arlen,
    output logic axi_arvalid,
    input logic axi_arready,
    input logic [255:0] axi_rdata,
    input logic [3:0] axi_rid,
    input logic axi_rlast, axi_rvalid
);
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    typedef enum logic [1:0] {RD_IDLE, RD_ADDRESS, RD_RECEIVE, RD_RETURN} rd_state_e;
    typedef enum logic [1:0] {WR_IDLE, WR_COLLECT, WR_SEND, WR_RETURN} wr_state_e;
    rd_state_e rd_state_q;
    wr_state_e wr_state_q;
    block_cmd_t rd_cmd_q, wr_cmd_q;
    block_r_t read_buffer_q [BLOCK_MAX_BEATS];
    block_w_t write_buffer_q [BLOCK_MAX_BEATS];
    logic [2:0] rd_total_q, rd_base_q, rd_segment_q, rd_count_q, rd_output_q;
    logic [2:0] wr_total_q, wr_base_q, wr_segment_q, wr_count_q, wr_collect_q;
    logic rd_bad_frame_q, aw_pending_q;
    bus_error_e wr_error_q, beat_error;
    logic rd_cmd_fire, rd_fire, wr_cmd_fire, wr_fire, wr_rsp_fire;
    logic ar_fire, aw_fire, read_capture, write_capture;
    xlen_t read_address, write_address, write_beat_addr;
    logic [31:0] allowed_strb;

    function automatic bus_error_e command_error(input block_cmd_t command, input logic writing);
        logic [64:0] end_address;
        end_address = 65'(command.addr) + ((65'(command.len) + 1) << command.size);
        if (65'(command.addr) < 65'(DDR_BASE) ||
            end_address > 65'(DDR_BASE) + 65'(DDR_BYTES) || end_address > (65'd1 << 32))
            return BUS_DECERR;
        if (command.len >= 8'(BLOCK_MAX_BEATS) || command.size > 5 ||
            (command.len != 0 && command.size != 5) ||
            (65'(command.addr) & ((65'd1 << command.size)-1)) != 0 ||
            (command.execute && (writing || (command.size != 2 && command.size != 5))))
            return BUS_SLVERR;
        return BUS_OK;
    endfunction

    function automatic logic [2:0] segment_count(input block_cmd_t command, input logic [2:0] base);
        logic [64:0] address;
        int unsigned remaining, page_beats;
        address = 65'(command.addr) + (65'(base) << command.size);
        remaining = int'(command.len) + 1 - int'(base);
        page_beats = (4096 - int'(address[11:0])) >> command.size;
        return 3'(remaining < page_beats ? remaining : page_beats);
    endfunction

    // 读槽接纳命令即预约整个块，native R没有反压；写槽收齐后才允许发AW。
    assign rd_cmd_ready = !rst && rd_state_q == RD_IDLE;
    assign rd_valid = !rst && rd_state_q == RD_RETURN;
    assign rd_data = read_buffer_q[rd_output_q[1:0]];
    assign wr_cmd_ready = !rst && wr_state_q == WR_IDLE;
    assign wr_ready = !rst && wr_state_q == WR_COLLECT;
    assign wr_rsp_valid = !rst && wr_state_q == WR_RETURN;
    assign wr_rsp.error = wr_error_q;
    assign rd_cmd_fire = rd_cmd_valid && rd_cmd_ready;
    assign rd_fire = rd_valid && rd_ready;
    assign wr_cmd_fire = wr_cmd_valid && wr_cmd_ready;
    assign wr_fire = wr_valid && wr_ready;
    assign wr_rsp_fire = wr_rsp_valid && wr_rsp_ready;
    assign read_address = rd_cmd_q.addr + (xlen_t'(rd_base_q) << rd_cmd_q.size);
    assign write_address = wr_cmd_q.addr + (xlen_t'(wr_base_q) << wr_cmd_q.size);
    assign axi_araddr = 28'((read_address - xlen_t'(DDR_BASE)) >> 2) & 28'hffffff8;
    assign axi_awaddr = 28'((write_address - xlen_t'(DDR_BASE)) >> 2) & 28'hffffff8;
    assign axi_arlen = 4'(rd_segment_q - 1'b1);
    assign axi_awlen = 4'(wr_segment_q - 1'b1);
    assign axi_aruser_ap = 1'b0;
    assign axi_awuser_ap = 1'b0;
    assign axi_aruser_id = '0;
    assign axi_awuser_id = '0;
    assign axi_arvalid = !rst && rd_state_q == RD_ADDRESS;
    assign axi_awvalid = !rst && wr_state_q == WR_SEND && aw_pending_q;
    assign axi_wdata = write_buffer_q[2'(wr_base_q + wr_count_q)].data;
    assign axi_wstrb = write_buffer_q[2'(wr_base_q + wr_count_q)].strb;
    assign ar_fire = axi_arvalid && axi_arready;
    assign aw_fire = axi_awvalid && axi_awready;
    // IP允许命令接受同沿给数据/索取写数据；不能假定响应至少晚一拍。
    assign read_capture = !rst && axi_rvalid && (rd_state_q == RD_RECEIVE || ar_fire);
    assign write_capture = !rst && wr_state_q == WR_SEND &&
                           (!aw_pending_q || aw_fire) && axi_wready;
    always_comb begin
        write_beat_addr = wr_cmd_q.addr + (xlen_t'(wr_collect_q) << wr_cmd_q.size);
        allowed_strb = 32'(((65'd1 << (65'd1 << wr_cmd_q.size))-1) << write_beat_addr[4:0]);
        beat_error = wr_error_q;
        if (beat_error == BUS_OK && ((wr_data.strb & ~allowed_strb) != 0 ||
                                    wr_data.last != (wr_collect_q == wr_total_q-1'b1)))
            beat_error = BUS_SLVERR;
    end

    // 真实RLAST前不复用owner。无RRESP，只能检测ID/帧结构；不会虚构DDR颗粒错误。
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_state_q <= RD_IDLE;
            rd_cmd_q <= '0;
            rd_total_q <= '0;
            rd_base_q <= '0;
            rd_segment_q <= '0;
            rd_count_q <= '0;
            rd_output_q <= '0;
            rd_bad_frame_q <= 1'b0;
            for (int i = 0; i < BLOCK_MAX_BEATS; i++) read_buffer_q[i] <= '0;
        end else begin
            unique case (rd_state_q)
                RD_IDLE: if (rd_cmd_fire) begin
                    rd_cmd_q <= rd_cmd;
                    rd_total_q <= rd_cmd.len < 8'(BLOCK_MAX_BEATS) ? 3'(rd_cmd.len)+1'b1 : 3'd1;
                    rd_base_q <= '0;
                    rd_count_q <= '0;
                    rd_output_q <= '0;
                    rd_segment_q <= segment_count(rd_cmd, 3'd0);
                    rd_bad_frame_q <= 1'b0;
                    for (int i = 0; i < BLOCK_MAX_BEATS; i++)
                        read_buffer_q[i] <= '{data:'0, error:command_error(rd_cmd, 1'b0),
                                             last:(rd_cmd.len < 8'(BLOCK_MAX_BEATS) ? i == int'(rd_cmd.len) : i == 0)};
                    rd_state_q <= command_error(rd_cmd, 1'b0) == BUS_OK ? RD_ADDRESS : RD_RETURN;
                end
                RD_ADDRESS: if (ar_fire) rd_state_q <= RD_RECEIVE;
                RD_RETURN: if (rd_fire) begin
                    if (rd_output_q == rd_total_q-1'b1) rd_state_q <= RD_IDLE;
                    else rd_output_q <= rd_output_q + 1'b1;
                end
                default: ;
            endcase
            if (read_capture) begin
                if (rd_count_q < rd_segment_q) begin
                    read_buffer_q[2'(rd_base_q + rd_count_q)].data <= axi_rdata;
                    read_buffer_q[2'(rd_base_q + rd_count_q)].error <= axi_rid == 0 ? BUS_OK : BUS_SLVERR;
                end
                if (axi_rlast) begin
                    if (rd_bad_frame_q || rd_count_q != rd_segment_q-1'b1)
                        for (int i = 0; i < BLOCK_MAX_BEATS; i++)
                            if (i >= int'(rd_base_q) && i < int'(rd_base_q) + int'(rd_segment_q))
                                read_buffer_q[i].error <= BUS_SLVERR;
                    if (rd_base_q + rd_segment_q == rd_total_q) rd_state_q <= RD_RETURN;
                    else begin
                        rd_base_q <= rd_base_q + rd_segment_q;
                        rd_segment_q <= segment_count(rd_cmd_q, rd_base_q + rd_segment_q);
                        rd_count_q <= '0;
                        rd_bad_frame_q <= 1'b0;
                        rd_state_q <= RD_ADDRESS;
                    end
                end else if (rd_count_q < rd_segment_q) begin
                    rd_count_q <= rd_count_q + 1'b1;
                    if (rd_count_q == rd_segment_q-1'b1) rd_bad_frame_q <= 1'b1;
                end else rd_bad_frame_q <= 1'b1;
            end
        end
    end

    // native无WVALID/B：完整数据预备后，按WREADY逐拍推进，末拍接受仅表示用户口接纳。
    // 协调复位才能清owner；不能把本地复位解释为撤销已发送的外存写。
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_state_q <= WR_IDLE;
            wr_cmd_q <= '0;
            wr_total_q <= '0;
            wr_base_q <= '0;
            wr_segment_q <= '0;
            wr_count_q <= '0;
            wr_collect_q <= '0;
            wr_error_q <= BUS_OK;
            aw_pending_q <= 1'b0;
            for (int i = 0; i < BLOCK_MAX_BEATS; i++) write_buffer_q[i] <= '0;
        end else begin
            unique case (wr_state_q)
                WR_IDLE: if (wr_cmd_fire) begin
                    wr_cmd_q <= wr_cmd;
                    wr_total_q <= wr_cmd.len < 8'(BLOCK_MAX_BEATS) ? 3'(wr_cmd.len)+1'b1 : 3'd1;
                    wr_base_q <= '0;
                    wr_count_q <= '0;
                    wr_collect_q <= '0;
                    wr_segment_q <= segment_count(wr_cmd, 3'd0);
                    wr_error_q <= command_error(wr_cmd, 1'b1);
                    wr_state_q <= WR_COLLECT;
                end
                WR_COLLECT: if (wr_fire) begin
                    write_buffer_q[wr_collect_q[1:0]] <= wr_data;
                    wr_error_q <= beat_error;
                    if (wr_collect_q == wr_total_q-1'b1) begin
                        aw_pending_q <= 1'b1;
                        wr_state_q <= beat_error == BUS_OK ? WR_SEND : WR_RETURN;
                    end else wr_collect_q <= wr_collect_q + 1'b1;
                end
                WR_SEND: begin
                    if (aw_fire) aw_pending_q <= 1'b0;
                    if (write_capture) begin
                        if (wr_count_q == wr_segment_q-1'b1) begin
                            if (wr_base_q + wr_segment_q == wr_total_q) wr_state_q <= WR_RETURN;
                            else begin
                                wr_base_q <= wr_base_q + wr_segment_q;
                                wr_segment_q <= segment_count(wr_cmd_q, wr_base_q + wr_segment_q);
                                wr_count_q <= '0;
                                aw_pending_q <= 1'b1;
                            end
                        end else wr_count_q <= wr_count_q + 1'b1;
                    end
                end
                WR_RETURN: if (wr_rsp_fire) wr_state_q <= WR_IDLE;
                default: wr_state_q <= WR_IDLE;
            endcase
        end
    end
endmodule
