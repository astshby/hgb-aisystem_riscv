// Module: cache_refill
// Description: Serial configurable-word line fill with one original-demand fallback on error.
module cache_refill #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WORD_BYTES = 4,
    parameter int unsigned WORD_W = $clog2(LINE_BYTES / WORD_BYTES)
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
    input bus_types_pkg::bus_rsp_t mem_response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    typedef enum logic [2:0] {IDLE, SEND, WAIT_DATA, RETRY_SEND, RETRY_WAIT, DONE} state_e;
    state_e state_q;
    bus_req_t request_q;
    bus_rsp_t response_q;
    logic [WORD_W-1:0] word_q;
    logic installable_q, fallback_q;
    xlen_t beat_addr;
    localparam int BYTE_W = $clog2(WORD_BYTES);

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
    assign write_valid = state_q == WAIT_DATA && mem_rsp_valid && mem_response.error == BUS_OK;
    assign write_word = word_q;
    assign write_data = (WORD_BYTES*8)'(mem_response.rdata >> (8 * beat_addr[$clog2(DBUS_BYTES)-1:0]));

    // 不把邻近字或扩宽访问的填行错误归给原指令；只回退一次原地址、原大小、原权限的访问。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            word_q <= '0;
            request_q <= '0;
            response_q <= '0;
            installable_q <= 1'b0;
            fallback_q <= 1'b0;
        end else begin
            case (state_q)
                IDLE: if (start_valid) begin
                    request_q <= request;
                    fallback_q <= fallback_enable;
                    word_q <= '0;
                    response_q <= '0;
                    installable_q <= 1'b0;
                    state_q <= SEND;
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
                DONE: if (done_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
