// Module: cache_refill
// Description: Configurable-word or buffered block line fill with one original-demand fallback on error.
module cache_refill #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WORD_BYTES = 4,
    parameter int unsigned WORD_W = $clog2(LINE_BYTES / WORD_BYTES),
    parameter bit BLOCK_ENABLE = 1'b0
) (
    input logic clk, rst,
    input logic start_valid,
    input logic fallback_enable,
    output logic start_ready,
    input bus_types_pkg::bus_req_t request,
    output logic done_valid,
    input logic done_ready,
    output logic installable,
    output bus_types_pkg::bus_rsp_t response,
    output logic write_valid,
    output logic [WORD_W-1:0] write_word,
    output logic [WORD_BYTES*8-1:0] write_data,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output bus_types_pkg::bus_req_t mem_request,
    input logic mem_rsp_valid,
    input bus_types_pkg::bus_rsp_t mem_response,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    typedef enum logic [3:0] {
        IDLE, SEND, WAIT_DATA, RETRY_SEND, RETRY_WAIT, DONE,
        BLOCK_CMD, BLOCK_READ, BLOCK_DRAIN, BLOCK_WRITE
    } state_e;
    state_e state_q;
    bus_req_t request_q;
    bus_rsp_t response_q;
    logic [WORD_W-1:0] word_q;
    logic installable_q, fallback_q;
    xlen_t beat_addr;
    localparam int BYTE_W = $clog2(WORD_BYTES);
    localparam int BLOCK_BEATS = LINE_BYTES / DDR_BEAT_BYTES;
    localparam int BEAT_W = BLOCK_BEATS > 1 ? $clog2(BLOCK_BEATS) : 1;
    logic [BEAT_W-1:0] block_beat_q;
    logic [LINE_BYTES*8-1:0] line_q;
    bus_error_e block_error_q;
    logic rd_cmd_fire, rd_fire;
    logic [WORD_BYTES*8-1:0] buffered_word;

    // I$ 的 WORD_BYTES 固定为 4，D$ 为 DBUS_BYTES。
    // RV64 的 execute 请求仍必须为 MEM_WORD；用子请求地址而非 CPU 原地址选择 lane。
    assign beat_addr = (request_q.addr & ~xlen_t'(LINE_BYTES-1)) + (xlen_t'(word_q) << BYTE_W);
    assign start_ready = state_q == IDLE;
    assign done_valid = state_q == DONE;
    assign installable = installable_q;
    assign response = response_q;
    assign mem_req_valid = !rst && (state_q == SEND || state_q == RETRY_SEND);
    always_comb begin
        mem_request = request_q;
        if (state_q == SEND) begin
            mem_request.addr = beat_addr;
            mem_request.size = mem_size_e'(BYTE_W);
        end
    end
    assign write_valid = (state_q == WAIT_DATA && mem_rsp_valid && mem_response.error == BUS_OK) ||
                         state_q == BLOCK_WRITE;
    assign write_word = word_q;
    assign buffered_word = line_q[int'(word_q)*WORD_BYTES*8 +: WORD_BYTES*8];
    assign write_data = state_q == BLOCK_WRITE ? buffered_word :
        (WORD_BYTES*8)'(mem_response.rdata >> (8 * beat_addr[$clog2(DBUS_BYTES)-1:0]));

    // 块口只扩展已授权的缓存行；原请求回退仍走标量口，保留大小、权限和lane语义。
    assign rd_cmd_valid = BLOCK_ENABLE && !rst && state_q == BLOCK_CMD;
    assign rd_cmd = '{addr:request_q.addr & ~xlen_t'(LINE_BYTES-1),
        len:8'(BLOCK_BEATS-1), size:3'($clog2(DDR_BEAT_BYTES)), execute:request_q.execute};
    assign rd_ready = BLOCK_ENABLE && !rst && (state_q == BLOCK_READ || state_q == BLOCK_DRAIN);
    assign rd_cmd_fire = rd_cmd_valid && rd_cmd_ready;
    assign rd_fire = rd_valid && rd_ready;

    // 整行在最后一个成功beat之前不写RAM。错误流仍消费至last，不能把尾部响应当作下一请求。
    always_ff @(posedge clk) begin
        if (!rst && state_q == BLOCK_READ && rd_fire)
            line_q[int'(block_beat_q)*DDR_DATA_W +: DDR_DATA_W] <= rd_data.data;
    end

    // 不把邻近字或扩宽访问的填行错误归给原指令；只回退一次原地址、原大小、原权限的访问。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            word_q <= '0;
            request_q <= '0;
            response_q <= '0;
            installable_q <= 1'b0;
            fallback_q <= 1'b0;
            block_beat_q <= '0;
            block_error_q <= BUS_OK;
        end else begin
            case (state_q)
                IDLE: if (start_valid) begin
                    request_q <= request;
                    fallback_q <= fallback_enable;
                    word_q <= '0;
                    response_q <= '0;
                    installable_q <= 1'b0;
                    block_beat_q <= '0;
                    block_error_q <= BUS_OK;
                    state_q <= BLOCK_ENABLE ? BLOCK_CMD : SEND;
                end
                SEND: if (mem_req_ready) state_q <= WAIT_DATA;
                WAIT_DATA: if (mem_rsp_valid) begin
                    if (mem_response.error != BUS_OK) begin
                        response_q <= mem_response;
                        state_q <= fallback_q ? RETRY_SEND : DONE;
                    end
                    else begin
                        if (word_q == request_q.addr[BYTE_W +: WORD_W]) response_q <= mem_response;
                        if (word_q == WORD_W'(LINE_BYTES/WORD_BYTES-1)) begin
                            installable_q <= 1'b1;
                            state_q <= DONE;
                        end else begin
                            word_q <= word_q + 1'b1;
                            state_q <= SEND;
                        end
                    end
                end
                RETRY_SEND: if (mem_req_ready) state_q <= RETRY_WAIT;
                RETRY_WAIT: if (mem_rsp_valid) begin
                    response_q <= mem_response;
                    state_q <= DONE;
                end
                BLOCK_CMD: if (rd_cmd_fire) state_q <= BLOCK_READ;
                BLOCK_READ: if (rd_fire) begin
                    if (rd_data.error != BUS_OK && block_error_q == BUS_OK) begin
                        block_error_q <= rd_data.error;
                        response_q.error <= rd_data.error;
                    end
                    if (rd_data.last) begin
                        if (block_beat_q == BEAT_W'(BLOCK_BEATS-1) &&
                            block_error_q == BUS_OK && rd_data.error == BUS_OK) begin
                            word_q <= '0;
                            state_q <= BLOCK_WRITE;
                        end else begin
                            if (block_error_q == BUS_OK && rd_data.error == BUS_OK)
                                response_q.error <= BUS_SLVERR;
                            state_q <= fallback_q ? RETRY_SEND : DONE;
                        end
                    end else if (block_beat_q == BEAT_W'(BLOCK_BEATS-1)) begin
                        if (block_error_q == BUS_OK && rd_data.error == BUS_OK)
                            response_q.error <= BUS_SLVERR;
                        state_q <= BLOCK_DRAIN;
                    end else block_beat_q <= block_beat_q + 1'b1;
                end
                BLOCK_DRAIN: if (rd_fire && rd_data.last)
                    state_q <= fallback_q ? RETRY_SEND : DONE;
                BLOCK_WRITE: begin
                    if (word_q == request_q.addr[BYTE_W +: WORD_W]) begin
                        response_q.rdata <= xlen_t'(buffered_word) <<
                            (8 * beat_addr[$clog2(DBUS_BYTES)-1:0]);
                        response_q.error <= BUS_OK;
                    end
                    if (word_q == WORD_W'(LINE_BYTES/WORD_BYTES-1)) begin
                        installable_q <= 1'b1;
                        state_q <= DONE;
                    end else word_q <= word_q + 1'b1;
                end
                DONE: if (done_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial if (BLOCK_ENABLE) assert (LINE_BYTES >= DDR_BEAT_BYTES &&
        LINE_BYTES <= BLOCK_MAX_BYTES && (LINE_BYTES & (LINE_BYTES-1)) == 0)
        else $fatal(1, "Block refill requires a 32/64/128-byte line");
`endif
endmodule
