// Module: block_to_axi
// Description: Bounded 256-bit block transfers with independent read/write owners and 4 KiB AXI splitting.
module block_to_axi #(
    parameter int unsigned DDR_BYTES = 64 * 1024
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
    output logic awvalid,
    input logic awready,
    output logic awid,
    output logic [31:0] awaddr,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic [1:0] awburst,
    output logic awlock,
    output logic [3:0] awcache, awqos, awregion,
    output logic [2:0] awprot,
    output logic wvalid,
    input logic wready,
    output logic [255:0] wdata,
    output logic [31:0] wstrb,
    output logic wlast,
    input logic bvalid,
    output logic bready,
    input logic bid,
    input logic [1:0] bresp,
    output logic arvalid,
    input logic arready,
    output logic arid,
    output logic [31:0] araddr,
    output logic [7:0] arlen,
    output logic [2:0] arsize,
    output logic [1:0] arburst,
    output logic arlock,
    output logic [3:0] arcache, arqos, arregion,
    output logic [2:0] arprot,
    input logic rvalid,
    output logic rready,
    input logic rid,
    input logic [255:0] rdata,
    input logic [1:0] rresp,
    input logic rlast
);
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    typedef enum logic [1:0] {RD_IDLE, RD_ADDRESS, RD_RECEIVE, RD_RETURN} rd_state_e;
    typedef enum logic [2:0] {WR_IDLE, WR_COLLECT, WR_SEND, WR_RESPONSE, WR_RETURN} wr_state_e;
    rd_state_e rd_state_q;
    wr_state_e wr_state_q;
    block_cmd_t rd_cmd_q, wr_cmd_q;
    block_r_t read_buffer_q [BLOCK_MAX_BEATS];
    block_w_t write_buffer_q [BLOCK_MAX_BEATS];
    logic [2:0] rd_total_q, rd_base_q, rd_segment_q, rd_count_q, rd_output_q;
    logic [2:0] wr_total_q, wr_base_q, wr_segment_q, wr_count_q, wr_collect_q;
    logic rd_bad_frame_q, aw_pending_q;
    bus_error_e wr_error_q, read_error, write_error, beat_error;
    logic rd_cmd_fire, rd_fire, wr_cmd_fire, wr_fire, wr_rsp_fire;
    logic ar_fire, r_fire, aw_fire, w_fire, b_fire;
    xlen_t write_beat_addr;
    logic [31:0] allowed_strb;

    // 地址按逻辑传输大小检查，不用256位数据线扩大窄访问；完整行读允许 execute+size5。
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

    // 命令和W分别保持到各自握手。两个方向各一笔，读写地址不能借用对方owner。
    assign arvalid = !rst && rd_state_q == RD_ADDRESS;
    assign rready = !rst && rd_state_q == RD_RECEIVE;
    assign araddr = 32'(rd_cmd_q.addr + (xlen_t'(rd_base_q) << rd_cmd_q.size));
    assign arlen = 8'(rd_segment_q - 1'b1);
    assign arsize = rd_cmd_q.size;
    assign arid = 1'b0;
    assign arburst = 2'b01;
    assign arlock = 1'b0;
    assign arcache = '0;
    assign arqos = '0;
    assign arregion = '0;
    assign arprot = {rd_cmd_q.execute, 2'b01};
    assign awvalid = !rst && wr_state_q == WR_SEND && aw_pending_q;
    assign awaddr = 32'(wr_cmd_q.addr + (xlen_t'(wr_base_q) << wr_cmd_q.size));
    assign awlen = 8'(wr_segment_q - 1'b1);
    assign awsize = wr_cmd_q.size;
    assign awid = 1'b0;
    assign awburst = 2'b01;
    assign awlock = 1'b0;
    assign awcache = '0;
    assign awqos = '0;
    assign awregion = '0;
    assign awprot = 3'b001;
    assign wvalid = !rst && wr_state_q == WR_SEND && wr_count_q < wr_segment_q;
    assign wdata = write_buffer_q[2'(wr_base_q + wr_count_q)].data;
    assign wstrb = write_buffer_q[2'(wr_base_q + wr_count_q)].strb;
    assign wlast = wr_count_q == wr_segment_q - 1'b1;
    assign bready = !rst && wr_state_q == WR_RESPONSE;
    assign ar_fire = arvalid && arready;
    assign r_fire = rvalid && rready;
    assign aw_fire = awvalid && awready;
    assign w_fire = wvalid && wready;
    assign b_fire = bvalid && bready;

    always_comb begin
        unique case (rresp)
            2'b00: read_error = BUS_OK;
            2'b11: read_error = BUS_DECERR;
            default: read_error = BUS_SLVERR;
        endcase
        if (rid) read_error = BUS_SLVERR;
        unique case (bresp)
            2'b00: write_error = BUS_OK;
            2'b11: write_error = BUS_DECERR;
            default: write_error = BUS_SLVERR;
        endcase
        if (bid) write_error = BUS_SLVERR;
        write_beat_addr = wr_cmd_q.addr + (xlen_t'(wr_collect_q) << wr_cmd_q.size);
        allowed_strb = 32'(((65'd1 << (65'd1 << wr_cmd_q.size))-1) << write_beat_addr[4:0]);
        beat_error = wr_error_q;
        if (beat_error == BUS_OK && ((wr_data.strb & ~allowed_strb) != 0 ||
                                    wr_data.last != (wr_collect_q == wr_total_q-1'b1)))
            beat_error = BUS_SLVERR;
    end

    // 完整缓存再交上游，保证无论下层如何报错，合法长度都返回固定拍数和一个最终last。
    // 早LAST给缺失位置补错；晚LAST继续排空，不让迟到响应污染下一命令。
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
                RD_RECEIVE: if (r_fire) begin
                    if (rd_count_q < rd_segment_q) begin
                        read_buffer_q[2'(rd_base_q + rd_count_q)].data <= rdata;
                        read_buffer_q[2'(rd_base_q + rd_count_q)].error <= read_error;
                    end
                    if (rlast) begin
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
                RD_RETURN: if (rd_fire) begin
                    if (rd_output_q == rd_total_q-1'b1) rd_state_q <= RD_IDLE;
                    else rd_output_q <= rd_output_q + 1'b1;
                end
                default: rd_state_q <= RD_IDLE;
            endcase
        end
    end

    // 写错误也先消费约定W拍数；非法超长命令规范化为一拍，与读端单error-last一致。
    // 只有整块合法才发AXI，分段写的B失败停止后续尚未发出的段，已写数据不回滚。
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
                    if (w_fire) wr_count_q <= wr_count_q + 1'b1;
                    if ((!aw_pending_q || aw_fire) &&
                        (wr_count_q == wr_segment_q || (w_fire && wr_count_q == wr_segment_q-1'b1)))
                        wr_state_q <= WR_RESPONSE;
                end
                WR_RESPONSE: if (b_fire) begin
                    wr_error_q <= write_error;
                    if (write_error != BUS_OK || wr_base_q + wr_segment_q == wr_total_q)
                        wr_state_q <= WR_RETURN;
                    else begin
                        wr_base_q <= wr_base_q + wr_segment_q;
                        wr_segment_q <= segment_count(wr_cmd_q, wr_base_q + wr_segment_q);
                        wr_count_q <= '0;
                        aw_pending_q <= 1'b1;
                        wr_state_q <= WR_SEND;
                    end
                end
                WR_RETURN: if (wr_rsp_fire) wr_state_q <= WR_IDLE;
                default: wr_state_q <= WR_IDLE;
            endcase
        end
    end
endmodule
