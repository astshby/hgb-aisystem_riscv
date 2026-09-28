// Module: dcache
// Description: Blocking two-way DDR data cache with write-through, no-write-allocate and explicit invalidate.
module dcache #(
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
    localparam int BYTE_W = $clog2(DBUS_BYTES), WORD_W = OFFSET_W-BYTE_W;
    localparam int TAG_W = 32-SET_W-OFFSET_W, DATA_W = SET_W+WORD_W;
    typedef enum logic [2:0] {IDLE, LOOKUP, FILL, STORE_SEND, STORE_WAIT, RESPOND} state_e;
    state_e state_q;
    logic cache_req_valid, cache_req_ready, cache_rsp_valid, cache_rsp_ready;
    bus_req_t cache_request, request_q;
    bus_rsp_t cache_response, response_q;
    logic lower_valid, lower_ready, lower_rsp_valid;
    bus_req_t lower_request;
    bus_rsp_t lower_response;
    logic hit, hit_way, victim_way, way_q, store_hit_q, discard_q, refill_started_q;
    logic evict, install, touch, update_way, request_fire, store_done, store_update;
    logic [SET_W-1:0] set_index;
    logic [TAG_W-1:0] tag_value;
    xlen_t ram_data [2];
    logic fill_start, fill_ready, fill_done, fill_installable, fill_write;
    logic fill_req_valid, fill_req_ready;
    logic [WORD_W-1:0] fill_word;
    xlen_t fill_data;
    bus_req_t fill_request;
    bus_rsp_t fill_response;

    // TCM/MMIO 不经过 LOOKUP；共享端口模块保持原地址校验与一次请求一次响应。
    cache_port #(.ENABLE(ENABLE), .INSTRUCTION(1'b0), .DDR_BYTES(DDR_BYTES), .LINE_BYTES(LINE_BYTES)) u_port (
        .clk, .rst, .invalidate, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
        .cache_req_valid, .cache_req_ready, .cache_request, .cache_rsp_valid, .cache_rsp_ready, .cache_response,
        .refill_req_valid(lower_valid), .refill_req_ready(lower_ready), .refill_request(lower_request),
        .refill_rsp_valid(lower_rsp_valid), .refill_response(lower_response),
        .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready, .mem_response
    );
    assign cache_req_ready = state_q == IDLE;
    assign request_fire = cache_req_valid && cache_req_ready;
    assign cache_rsp_valid = state_q == RESPOND;
    assign cache_response = response_q;
    assign set_index = request_q.addr[OFFSET_W +: SET_W];
    assign tag_value = request_q.addr[OFFSET_W+SET_W +: TAG_W];

    // 写命中只在下层确认成功后按 byte strobe 更新；写错误或维护不能留下有效旧副本。
    assign store_done = state_q == STORE_WAIT && lower_rsp_valid;
    assign store_update = store_done && lower_response.error == BUS_OK &&
                          store_hit_q && !discard_q && !invalidate;
    cache_data_array #(.CACHE_BYTES(CACHE_BYTES), .WORD_BYTES(DBUS_BYTES)) u_data (
        .clk, .read_enable(request_fire), .read_addr(cache_request.addr[BYTE_W +: DATA_W]),
        .read_data(ram_data), .write_enable(fill_write || store_update), .write_way(way_q),
        .write_addr(store_update ? request_q.addr[BYTE_W +: DATA_W] : {set_index, fill_word}),
        .write_data(store_update ? request_q.wdata : fill_data),
        .write_mask(store_update ? request_q.wstrb : {DBUS_BYTES{1'b1}})
    );

    // Store miss 不替换、不读填行；只有 Load miss 才先失效 victim 再安装整行。
    assign evict = (state_q == LOOKUP && !request_q.write && (!hit || invalidate)) ||
                   (store_done && store_hit_q && lower_response.error != BUS_OK);
    assign install = state_q == FILL && fill_done && fill_installable && !discard_q && !invalidate;
    assign touch = (state_q == LOOKUP && !request_q.write && hit && !invalidate) || install || store_update;
    assign update_way = state_q == LOOKUP ? (hit && !invalidate ? hit_way : victim_way) : way_q;
    cache_meta_array #(.SETS(SETS), .TAG_W(TAG_W)) u_meta (
        .clk, .rst, .invalidate, .lookup_set(set_index), .lookup_tag(tag_value),
        .hit, .hit_way, .victim_way, .evict, .install, .touch,
        .update_way, .update_set(set_index), .update_tag(tag_value)
    );

    // 读填行按 XLEN；原始窄读保存在 refill 中，错误回退绝不沿用扩宽后的 size。
    assign fill_start = state_q == FILL && !refill_started_q;
    cache_refill #(.LINE_BYTES(LINE_BYTES), .WORD_BYTES(DBUS_BYTES)) u_refill (
        .clk, .rst, .start_valid(fill_start), .start_ready(fill_ready), .request(request_q),
        .done_valid(fill_done), .done_ready(state_q == FILL), .installable(fill_installable),
        .response(fill_response), .write_valid(fill_write), .write_word(fill_word), .write_data(fill_data),
        .mem_req_valid(fill_req_valid), .mem_req_ready(fill_req_ready), .mem_request(fill_request),
        .mem_rsp_valid(lower_rsp_valid && state_q == FILL), .mem_response(lower_response)
    );
    assign lower_valid = state_q == STORE_SEND ? 1'b1 : fill_req_valid;
    assign lower_request = state_q == STORE_SEND ? request_q : fill_request;
    assign fill_req_ready = state_q == FILL && lower_ready;

    // 请求与完成包分开保存，不能把请求接受或 AXI AW/W 接受误当成写完成。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            request_q <= '0;
            response_q <= '0;
            way_q <= 0;
            store_hit_q <= 0;
            discard_q <= 0;
            refill_started_q <= 0;
        end else begin
            if (invalidate && state_q != IDLE) discard_q <= 1;
            case (state_q)
                IDLE: if (request_fire) begin
                    request_q <= cache_request;
                    discard_q <= 0;
                    refill_started_q <= 0;
                    state_q <= LOOKUP;
                end
                LOOKUP: begin
                    way_q <= hit && !invalidate ? hit_way : victim_way;
                    if (request_q.write) begin
                        store_hit_q <= hit && !invalidate;
                        state_q <= STORE_SEND;
                    end else if (hit && !invalidate) begin
                        response_q <= '{rdata:ram_data[hit_way], error:BUS_OK};
                        state_q <= RESPOND;
                    end else state_q <= FILL;
                end
                FILL: begin
                    if (fill_start && fill_ready) refill_started_q <= 1;
                    if (fill_done) begin
                        response_q <= fill_response;
                        state_q <= RESPOND;
                    end
                end
                STORE_SEND: if (lower_ready) state_q <= STORE_WAIT;
                STORE_WAIT: if (lower_rsp_valid) begin
                    response_q <= lower_response;
                    state_q <= RESPOND;
                end
                RESPOND: if (cache_rsp_ready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (LINE_BYTES >= 2*DBUS_BYTES && (LINE_BYTES & (LINE_BYTES-1)) == 0 &&
                SETS >= 2 && (SETS & (SETS-1)) == 0 && CACHE_BYTES == 2*SETS*LINE_BYTES)
            else $fatal(1, "D-cache requires power-of-two line and at least two sets");
    end
`endif
endmodule
