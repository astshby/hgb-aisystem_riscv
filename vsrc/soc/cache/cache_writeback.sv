// Module: cache_writeback
// Description: Synchronous-array line reader with serial or buffered block writeback and explicit completion.
module cache_writeback #(
    parameter int LINE_BYTES = 32,
    parameter int WORD_W = $clog2(LINE_BYTES/core_config_pkg::DBUS_BYTES),
    parameter bit BLOCK_ENABLE = 1'b0
) (
    input logic clk, rst, start_valid,
    output logic start_ready,
    input core_types_pkg::xlen_t line_addr,
    output logic read_enable,
    output logic [WORD_W-1:0] read_word,
    input core_types_pkg::xlen_t read_data,
    output logic done_valid,
    input logic done_ready,
    output bus_types_pkg::bus_error_e error,
    output core_types_pkg::xlen_t fault_addr,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    input bus_types_pkg::bus_rsp_t response,
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
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    typedef enum logic [3:0] {
        IDLE, READ, CAPTURE, SEND, WAIT_RESPONSE, DONE, BLOCK_CMD, BLOCK_SEND, BLOCK_RESPONSE
    } state_e;
    state_e state_q;
    xlen_t base_q, data_q;
    logic [WORD_W-1:0] word_q;
    localparam int BLOCK_BEATS = LINE_BYTES / DDR_BEAT_BYTES;
    localparam int BEAT_W = BLOCK_BEATS > 1 ? $clog2(BLOCK_BEATS) : 1;
    logic [LINE_BYTES*8-1:0] line_q;
    logic [BEAT_W-1:0] block_beat_q;
    logic wr_cmd_fire, wr_fire, wr_rsp_fire;
    assign start_ready = state_q == IDLE;
    assign done_valid = state_q == DONE;
    assign read_enable = state_q == READ;
    assign read_word = word_q;
    assign req_valid = !rst && state_q == SEND;
    always_comb begin
        request = '0;
        request.addr = base_q + (xlen_t'(word_q) << $clog2(DBUS_BYTES));
        request.write = 1'b1;
        request.size = mem_size_e'($clog2(DBUS_BYTES));
        request.wdata = data_q;
        request.wstrb = '1;
    end

    // 先按同步RAM时序收齐整行，再发块命令；W反压只保持当前beat，不重复读阵列。
    assign wr_cmd_valid = BLOCK_ENABLE && !rst && state_q == BLOCK_CMD;
    assign wr_cmd = '{addr:base_q, len:8'(BLOCK_BEATS-1),
        size:3'($clog2(DDR_BEAT_BYTES)), execute:1'b0};
    assign wr_valid = BLOCK_ENABLE && !rst && state_q == BLOCK_SEND;
    assign wr_data = '{data:line_q[int'(block_beat_q)*DDR_DATA_W +: DDR_DATA_W],
        strb:'1, last:block_beat_q == BEAT_W'(BLOCK_BEATS-1)};
    assign wr_rsp_ready = BLOCK_ENABLE && !rst && state_q == BLOCK_RESPONSE;
    assign wr_cmd_fire = wr_cmd_valid && wr_cmd_ready;
    assign wr_fire = wr_valid && wr_ready;
    assign wr_rsp_fire = wr_rsp_valid && wr_rsp_ready;
    always_ff @(posedge clk) begin
        if (!rst && BLOCK_ENABLE && state_q == CAPTURE)
            line_q[int'(word_q)*XLEN +: XLEN] <= read_data;
    end
    // READ 沿触发同步 RAM；CAPTURE 再锁存数据，SEND 反压时地址与数据都不能改变。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            base_q <= '0;
            data_q <= '0;
            word_q <= '0;
            block_beat_q <= '0;
            error <= BUS_OK;
            fault_addr <= '0;
        end else case (state_q)
            IDLE: if (start_valid) begin
                base_q <= line_addr;
                word_q <= '0;
                block_beat_q <= '0;
                error <= BUS_OK;
                fault_addr <= '0;
                state_q <= READ;
            end
            READ: state_q <= CAPTURE;
            CAPTURE: begin
                data_q <= read_data;
                if (!BLOCK_ENABLE) state_q <= SEND;
                else if (word_q == WORD_W'(LINE_BYTES/DBUS_BYTES-1)) state_q <= BLOCK_CMD;
                else begin word_q <= word_q + 1'b1; state_q <= READ; end
            end
            SEND: if (req_ready) state_q <= WAIT_RESPONSE;
            WAIT_RESPONSE: if (rsp_valid) begin
                if (response.error != BUS_OK) begin
                    error <= response.error;
                    fault_addr <= request.addr;
                    state_q <= DONE;
                end else if (word_q == WORD_W'(LINE_BYTES/DBUS_BYTES-1)) state_q <= DONE;
                else begin word_q <= word_q + 1'b1; state_q <= READ; end
            end
            BLOCK_CMD: if (wr_cmd_fire) state_q <= BLOCK_SEND;
            BLOCK_SEND: if (wr_fire) begin
                if (wr_data.last) state_q <= BLOCK_RESPONSE;
                else block_beat_q <= block_beat_q + 1'b1;
            end
            // B只报告整笔写回状态，不能推测失败的具体beat；失败地址记录victim行基址。
            // 即使部分beat已写入DDR，缓存仍保留原valid/dirty/data，允许软件重试整行。
            BLOCK_RESPONSE: if (wr_rsp_fire) begin
                error <= wr_rsp.error;
                fault_addr <= wr_rsp.error == BUS_OK ? '0 : base_q;
                state_q <= DONE;
            end
            DONE: if (done_ready) state_q <= IDLE;
            default: state_q <= IDLE;
        endcase
    end

`ifndef SYNTHESIS
    initial if (BLOCK_ENABLE) assert (LINE_BYTES >= DDR_BEAT_BYTES &&
        LINE_BYTES <= BLOCK_MAX_BYTES && (LINE_BYTES & (LINE_BYTES-1)) == 0)
        else $fatal(1, "Block writeback requires a 32/64/128-byte line");
`endif
endmodule
