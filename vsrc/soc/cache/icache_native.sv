// Module: icache_native
// Description: Native aligned IF64 cache with one-cycle synchronous hits and per-word uncached error fallback.
module icache_native #(
    parameter bit ENABLE = 1,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned CACHE_BYTES = 4096,
    parameter int unsigned LINE_BYTES = 32,
    parameter bit BLOCK_ENABLE = 0
) (
    input logic clk, rst, invalidate,
    input logic req_valid,
    output logic req_ready,
    input core_types_pkg::xlen_t req_addr,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic [63:0] rsp_data,
    output logic [1:0] rsp_error,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output bus_types_pkg::bus_req_t mem_request,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
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
    localparam int SETS = CACHE_BYTES/(2*LINE_BYTES);
    localparam int SET_W = $clog2(SETS), OFFSET_W = $clog2(LINE_BYTES);
    localparam int TAG_W = 32-SET_W-OFFSET_W, DATA_W = $clog2(CACHE_BYTES/16);
    localparam int WORD_W = $clog2(LINE_BYTES/4);
    typedef enum logic [2:0] {IDLE, FILL_START, FILL_WAIT, BYPASS_SEND, BYPASS_WAIT} state_e;
    state_e state_q;
    bus_req_t incoming, request_q, refill_request;
    bus_rsp_t fill_response;
    bus_target_e target;
    bus_error_e access_error;
    logic cacheable, request_fire, hit, hit_way, victim_way, way_q, discard_q;
    logic hit_response_q, valid_q, response_way_q, bypass_word_q;
    logic [63:0] response_q, fill_pair_q, ram_data [2];
    logic [1:0] error_q;
    logic evict, install, touch, update_way;
    logic [SET_W-1:0] update_set;
    logic [TAG_W-1:0] update_tag;
    logic fill_ready, fill_done, fill_installable, fill_write;
    logic [WORD_W-1:0] fill_word;
    logic [31:0] fill_data;
    logic refill_req_valid, refill_req_ready;
    logic [63:0] fill_ram_data;
    logic [7:0] fill_ram_mask;
    logic [DATA_W-1:0] fill_ram_addr;

    always_comb begin
        incoming = '0; incoming.addr = req_addr; incoming.execute = 1; incoming.size = MEM_WORD;
    end
    address_decode #(.DDR_BYTES(DDR_BYTES)) u_decode (.request(incoming), .target, .error(access_error));
    assign cacheable = ENABLE && target == TARGET_DDR && access_error == BUS_OK &&
        ((65'(req_addr) & ~65'(LINE_BYTES-1)) + 65'(LINE_BYTES) <=
         65'(soc_addr_pkg::DDR_BASE) + 65'(DDR_BYTES));
    assign req_ready = !rst && !invalidate && state_q == IDLE && (!valid_q || rsp_ready);
    assign request_fire = req_valid && req_ready;
    assign rsp_valid = valid_q;
    assign rsp_data = hit_response_q ? ram_data[response_way_q] : response_q;
    assign rsp_error = error_q;

    // 命中在接受沿选中 way 并同步读 64 位，下拍可消费旧响应和接纳下一对指令。
    assign evict = request_fire && cacheable && !hit;
    assign install = state_q == FILL_WAIT && fill_done && fill_installable && !discard_q && !invalidate;
    assign touch = (request_fire && cacheable && hit) || install;
    assign update_way = install ? way_q : (hit ? hit_way : victim_way);
    assign update_set = install ? request_q.addr[OFFSET_W +: SET_W] : req_addr[OFFSET_W +: SET_W];
    assign update_tag = install ? request_q.addr[OFFSET_W+SET_W +: TAG_W] : req_addr[OFFSET_W+SET_W +: TAG_W];
    cache_meta_array #(.SETS(SETS), .TAG_W(TAG_W)) u_meta (
        .clk, .rst, .invalidate, .lookup_set(req_addr[OFFSET_W +: SET_W]),
        .lookup_tag(req_addr[OFFSET_W+SET_W +: TAG_W]), .hit, .hit_way, .victim_way,
        .evict, .install, .touch, .update_way, .update_set, .update_tag
    );
    assign fill_ram_addr = DATA_W'({request_q.addr[OFFSET_W +: SET_W], fill_word} >> 1);
    assign fill_ram_data = {fill_data, fill_data};
    assign fill_ram_mask = fill_word[0] ? 8'hf0 : 8'h0f;
    cache_data_array #(.CACHE_BYTES(CACHE_BYTES), .WORD_BYTES(8)) u_data (
        .clk, .read_enable(request_fire && cacheable && hit), .read_addr(req_addr[3 +: DATA_W]),
        .read_data(ram_data), .write_enable(fill_write), .write_way(way_q),
        .write_addr(fill_ram_addr), .write_data(fill_ram_data), .write_mask(fill_ram_mask)
    );
    cache_refill #(.LINE_BYTES(LINE_BYTES), .BLOCK_ENABLE(BLOCK_ENABLE)) u_refill (
        .clk, .rst, .fallback_enable(1'b0), .start_valid(state_q == FILL_START), .start_ready(fill_ready),
        .request(request_q), .done_valid(fill_done), .done_ready(state_q == FILL_WAIT),
        .installable(fill_installable), .response(fill_response), .write_valid(fill_write),
        .write_word(fill_word), .write_data(fill_data),
        .mem_req_valid(refill_req_valid), .mem_req_ready(refill_req_ready), .mem_request(refill_request),
        .mem_rsp_valid(mem_rsp_valid && state_q == FILL_WAIT), .mem_response,
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data
    );

    // 填行失败不把邻居错误归给原指令；改为两个独立 MEM_WORD，保留各 word 的错误。
    assign refill_req_ready = mem_req_ready && (state_q == FILL_START || state_q == FILL_WAIT);
    assign mem_rsp_ready = !rst && (state_q == FILL_WAIT || state_q == BYPASS_WAIT);
    always_comb begin
        mem_request = request_q;
        mem_request.addr = request_q.addr + (bypass_word_q ? xlen_t'(4) : '0);
        mem_req_valid = !rst && state_q == BYPASS_SEND;
        if (state_q == FILL_START || state_q == FILL_WAIT) begin
            mem_request = refill_request;
            mem_req_valid = refill_req_valid;
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE; valid_q <= 0; hit_response_q <= 0; response_way_q <= 0;
            request_q <= '0; way_q <= 0; discard_q <= 0; bypass_word_q <= 0;
            response_q <= 0; fill_pair_q <= 0; error_q <= 0;
        end else begin
            if (valid_q && rsp_ready) valid_q <= 0;
            if (invalidate && state_q != IDLE) discard_q <= 1;
            if (fill_write && (fill_word >> 1) == (request_q.addr[2 +: WORD_W] >> 1))
                fill_pair_q[32*int'(fill_word[0]) +: 32] <= fill_data;
            unique case (state_q)
                IDLE: if (request_fire) begin
                    request_q <= incoming; discard_q <= 0; error_q <= 0;
                    if (cacheable && hit) begin
                        valid_q <= 1; hit_response_q <= 1; response_way_q <= hit_way;
                    end else begin
                        hit_response_q <= 0; bypass_word_q <= 0;
                        way_q <= victim_way; fill_pair_q <= 0;
                        state_q <= cacheable ? FILL_START : BYPASS_SEND;
                    end
                end
                FILL_START: if (fill_ready) state_q <= FILL_WAIT;
                FILL_WAIT: if (fill_done) begin
                    if (fill_installable) begin
                        response_q <= fill_pair_q; error_q <= 0; valid_q <= 1; state_q <= IDLE;
                    end else begin bypass_word_q <= 0; state_q <= BYPASS_SEND; end
                end
                BYPASS_SEND: if (mem_req_valid && mem_req_ready) state_q <= BYPASS_WAIT;
                BYPASS_WAIT: if (mem_rsp_valid && mem_rsp_ready) begin
                    response_q[32*int'(bypass_word_q) +: 32] <=
                        32'(mem_response.rdata >> (XLEN == 64 && bypass_word_q ? 32 : 0));
                    error_q[bypass_word_q] <= mem_response.error != BUS_OK;
                    if (bypass_word_q) begin valid_q <= 1; state_q <= IDLE; end
                    else begin bypass_word_q <= 1; state_q <= BYPASS_SEND; end
                end
                default: state_q <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial assert (LINE_BYTES >= 8 && SETS >= 2 &&
                    (LINE_BYTES & (LINE_BYTES-1)) == 0 && (SETS & (SETS-1)) == 0)
        else $fatal(1, "native I-cache geometry");
    always_ff @(posedge clk) if (request_fire)
        assert (req_addr[2:0] == 0) else $fatal(1, "native IF64 must be aligned");
`endif
endmodule
