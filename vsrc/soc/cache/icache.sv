// Module: icache
// Description: Blocking two-way DDR instruction cache with synchronous data arrays and uncached bypass.
module icache #(
    parameter bit ENABLE = 1'b1,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned CACHE_BYTES = 4096,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic clk, rst, invalidate,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output bus_types_pkg::bus_req_t mem_request,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input bus_types_pkg::bus_rsp_t mem_response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    localparam int SETS = CACHE_BYTES / (2 * LINE_BYTES);
    localparam int SET_W = $clog2(SETS), OFFSET_W = $clog2(LINE_BYTES);
    localparam int WORD_W = OFFSET_W-2, TAG_W = 32-SET_W-OFFSET_W;
    localparam int DATA_W = SET_W+WORD_W;
    typedef enum logic [1:0] {IDLE, LOOKUP, FILL, RESPOND} state_e;
    state_e state_q;
    logic cache_req_valid, cache_req_ready, cache_rsp_valid, cache_rsp_ready;
    bus_req_t cache_request, request_q;
    bus_rsp_t cache_response, response_q;
    logic refill_req_valid, refill_req_ready, refill_rsp_valid;
    bus_req_t refill_request;
    bus_rsp_t refill_response;
    logic hit, hit_way, victim_way, way_q, discard_q, refill_started_q;
    logic evict, install, touch, update_way, request_fire;
    logic [SET_W-1:0] set_index;
    logic [TAG_W-1:0] tag_value;
    logic [31:0] ram_data [2];
    logic fill_start, fill_ready, fill_done, fill_installable, fill_write;
    logic [WORD_W-1:0] fill_word;
    logic [31:0] fill_data;
    bus_rsp_t fill_response;

    cache_port #(.ENABLE(ENABLE), .DDR_BYTES(DDR_BYTES), .LINE_BYTES(LINE_BYTES)) u_port (
        .clk, .rst, .invalidate, .maintenance_pending(1'b0), .maintenance_active(1'b0), .idle(), .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
        .cache_req_valid, .cache_req_ready, .cache_request, .cache_rsp_valid, .cache_rsp_ready, .cache_response,
        .refill_req_valid, .refill_req_ready, .refill_request, .refill_rsp_valid, .refill_response,
        .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready, .mem_response
    );

    // 请求接受沿读取两路数据；下一拍比较同一请求的 tag，再寄存可反压的响应。
    assign cache_req_ready = state_q == IDLE;
    assign request_fire = cache_req_valid && cache_req_ready;
    assign cache_rsp_valid = state_q == RESPOND;
    assign cache_response = response_q;
    assign set_index = request_q.addr[OFFSET_W +: SET_W];
    assign tag_value = request_q.addr[OFFSET_W+SET_W +: TAG_W];
    cache_data_array #(.CACHE_BYTES(CACHE_BYTES)) u_data (
        .clk, .read_enable(request_fire), .read_addr(cache_request.addr[2 +: DATA_W]),
        .read_data(ram_data), .write_enable(fill_write), .write_way(way_q),
        .write_addr({set_index, fill_word}), .write_data(fill_data), .write_mask('1)
    );

    // miss 先失效 victim；完整填行且未被 FENCE.I 作废时才安装，命中/安装后更新 LRU。
    assign evict = state_q == LOOKUP && (!hit || invalidate);
    assign install = state_q == FILL && fill_done && fill_installable && !discard_q && !invalidate;
    assign touch = (state_q == LOOKUP && hit && !invalidate) || install;
    assign update_way = state_q == LOOKUP ? (hit && !invalidate ? hit_way : victim_way) : way_q;
    cache_meta_array #(.SETS(SETS), .TAG_W(TAG_W)) u_meta (
        .clk, .rst, .invalidate, .lookup_set(set_index), .lookup_tag(tag_value),
        .hit, .hit_way, .victim_way, .evict, .install, .touch,
        .update_way, .update_set(set_index), .update_tag(tag_value)
    );

    // 已接受的填行即使遇到失效也继续排空，最终仍交付一次旧 CPU 响应供 IF kill 消费。
    assign fill_start = state_q == FILL && !refill_started_q;
    cache_refill #(.LINE_BYTES(LINE_BYTES)) u_refill (
        .clk, .rst, .fallback_enable(1'b1), .start_valid(fill_start), .start_ready(fill_ready), .request(request_q),
        .done_valid(fill_done), .done_ready(state_q == FILL), .installable(fill_installable),
        .response(fill_response), .write_valid(fill_write), .write_word(fill_word), .write_data(fill_data),
        .mem_req_valid(refill_req_valid), .mem_req_ready(refill_req_ready), .mem_request(refill_request),
        .mem_rsp_valid(refill_rsp_valid), .mem_response(refill_response)
    );

    // 控制与请求快照；失效是粘滞标记，不能只屏蔽 FENCE.I 出现的那一拍。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            request_q <= '0;
            response_q <= '0;
            way_q <= 1'b0;
            discard_q <= 1'b0;
            refill_started_q <= 1'b0;
        end else begin
            if (invalidate && state_q != IDLE) discard_q <= 1'b1;
            case (state_q)
                IDLE: if (request_fire) begin
                    request_q <= cache_request;
                    discard_q <= 1'b0;
                    refill_started_q <= 1'b0;
                    state_q <= LOOKUP;
                end
                LOOKUP: begin
                    if (hit && !invalidate) begin
                        response_q.error <= BUS_OK;
                        response_q.rdata <= xlen_t'(ram_data[hit_way]) <<
                                            (8 * request_q.addr[$clog2(DBUS_BYTES)-1:0]);
                        state_q <= RESPOND;
                    end else begin
                        way_q <= victim_way;
                        state_q <= FILL;
                    end
                end
                FILL: begin
                    if (fill_start && fill_ready) refill_started_q <= 1'b1;
                    if (fill_done) begin
                        response_q <= fill_response;
                        state_q <= RESPOND;
                    end
                end
                RESPOND: if (cache_rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (LINE_BYTES >= 8 && (LINE_BYTES & (LINE_BYTES-1)) == 0 &&
                SETS >= 2 && (SETS & (SETS-1)) == 0 && CACHE_BYTES == 2*SETS*LINE_BYTES)
            else $fatal(1, "I-cache requires power-of-two line and at least two sets");
    end
`endif
endmodule
