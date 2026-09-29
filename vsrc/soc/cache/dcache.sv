// Module: dcache
// Description: Blocking two-way writeback/write-allocate cache with recoverable eviction errors and maintenance.
module dcache #(
    parameter bit ENABLE = 1'b1,
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned CACHE_BYTES = 4096,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic clk, rst,
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
    input bus_types_pkg::bus_rsp_t mem_response,
    input logic maint_req_valid,
    output logic maint_req_ready,
    input cache_pkg::cache_maint_op_e maint_op,
    output logic maint_rsp_valid,
    input logic maint_rsp_ready,
    output cache_pkg::cache_maint_error_e maint_error,
    output core_types_pkg::xlen_t maint_fault_addr,
    output logic fault_valid,
    output cache_pkg::cache_maint_error_e fault_code,
    output core_types_pkg::xlen_t fault_addr
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import cache_pkg::*;
    localparam int SETS = CACHE_BYTES / (2*LINE_BYTES);
    localparam int SET_W = $clog2(SETS), OFFSET_W = $clog2(LINE_BYTES);
    localparam int BYTE_W = $clog2(DBUS_BYTES), WORD_W = OFFSET_W-BYTE_W;
    localparam int TAG_W = 32-SET_W-OFFSET_W, DATA_W = SET_W+WORD_W;
    typedef enum logic [3:0] {
        IDLE, LOOKUP, MISS_CHECK, WRITEBACK, FILL, STORE_APPLY,
        STORE_SEND, STORE_WAIT, RESPOND, SCAN, SCAN_NEXT, MAINT_DONE
    } state_e;
    state_e state_q;
    logic cache_req_valid, cache_req_ready, cache_rsp_ready, port_idle, request_fire;
    bus_req_t cache_request, request_q;
    bus_rsp_t response_q;
    logic lower_valid, lower_ready, lower_rsp_valid;
    bus_req_t lower_request;
    bus_rsp_t lower_response;
    logic hit, hit_way, victim_way, way_q, probe_way, probe_valid, probe_dirty;
    logic [TAG_W-1:0] probe_tag;
    logic [SET_W-1:0] meta_set, scan_set_q;
    logic maintenance_q, fill_started_q, wb_started_q;
    cache_maint_op_e operation_q;
    logic install, touch, invalidate_entry, mark_clean, mark_dirty, update_way;
    xlen_t ram_data [2], probe_base;
    logic fill_ready, fill_done, fill_installable, fill_write, fill_req_valid, fill_req_ready;
    logic [WORD_W-1:0] fill_word;
    xlen_t fill_data;
    bus_req_t fill_request, fill_original;
    bus_rsp_t fill_response;
    logic wb_ready, wb_done, wb_read, wb_req_valid, wb_req_ready;
    logic [WORD_W-1:0] wb_word;
    bus_req_t wb_request;
    bus_error_e wb_error;
    xlen_t wb_fault_addr;

    // 维护只能在原 CPU 响应排空后夺取 D 主端口；pending 先阻止新请求插队。
    assign maint_req_ready = state_q == IDLE && port_idle && !rst;
    cache_port #(.ENABLE(ENABLE), .INSTRUCTION(1'b0), .DDR_BYTES(DDR_BYTES), .LINE_BYTES(LINE_BYTES)) u_port (
        .clk, .rst, .invalidate(1'b0), .maintenance_active(maintenance_q),
        .maintenance_pending(maint_req_valid), .idle(port_idle),
        .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
        .cache_req_valid, .cache_req_ready, .cache_request,
        .cache_rsp_valid(state_q == RESPOND), .cache_rsp_ready, .cache_response(response_q),
        .refill_req_valid(lower_valid), .refill_req_ready(lower_ready), .refill_request(lower_request),
        .refill_rsp_valid(lower_rsp_valid), .refill_response(lower_response),
        .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready, .mem_response
    );
    assign cache_req_ready = state_q == IDLE && !maint_req_valid;
    assign request_fire = cache_req_valid && cache_req_ready;
    assign maint_rsp_valid = state_q == MAINT_DONE;
    assign meta_set = maintenance_q ? scan_set_q : request_q.addr[OFFSET_W +: SET_W];
    assign probe_way = state_q == LOOKUP ? victim_way : way_q;
    assign probe_base = xlen_t'({probe_tag, meta_set, {OFFSET_W{1'b0}}});

    // 写命中及写分配完成后按原 strobe 合并，退休承诺的是本 Cache 持有的脏数据。
    assign install = state_q == FILL && fill_done && fill_installable;
    assign mark_dirty = state_q == STORE_APPLY && |request_q.wstrb;
    assign mark_clean = state_q == WRITEBACK && wb_done && wb_error == BUS_OK;
    assign touch = (state_q == LOOKUP && hit && !request_q.write) || install || mark_dirty;
    assign update_way = state_q == LOOKUP ? hit_way : way_q;
    assign invalidate_entry =
        (state_q == MISS_CHECK && !probe_dirty) ||
        (mark_clean && (!maintenance_q || operation_q == CACHE_FLUSH)) ||
        (state_q == SCAN && probe_valid && !probe_dirty &&
         (operation_q == CACHE_INVALIDATE || operation_q == CACHE_FLUSH));
    dcache_meta_array #(.SETS(SETS), .TAG_W(TAG_W)) u_meta (
        .clk, .rst, .lookup_set(meta_set), .lookup_tag(request_q.addr[OFFSET_W+SET_W +: TAG_W]),
        .hit, .hit_way, .victim_way, .probe_way, .probe_valid, .probe_dirty, .probe_tag,
        .invalidate_entry, .install, .touch, .mark_dirty, .mark_clean, .update_way,
        .install_tag(request_q.addr[OFFSET_W+SET_W +: TAG_W])
    );
    cache_data_array #(.CACHE_BYTES(CACHE_BYTES), .WORD_BYTES(DBUS_BYTES)) u_data (
        .clk, .read_enable(request_fire || wb_read),
        .read_addr(wb_read ? {meta_set, wb_word} : cache_request.addr[BYTE_W +: DATA_W]),
        .read_data(ram_data), .write_enable(fill_write || mark_dirty), .write_way(way_q),
        .write_addr(mark_dirty ? request_q.addr[BYTE_W +: DATA_W] : {meta_set, fill_word}),
        .write_data(mark_dirty ? request_q.wdata : fill_data),
        .write_mask(mark_dirty ? request_q.wstrb : {DBUS_BYTES{1'b1}})
    );

    // 写分配先读整行；读填行失败后只下传一次原 Store，不能把填行本身变成写。
    always_comb begin
        fill_original = request_q;
        if (request_q.write) begin
            fill_original.write = 0;
            fill_original.size = mem_size_e'(BYTE_W);
            fill_original.addr = request_q.addr & ~xlen_t'(DBUS_BYTES-1);
            fill_original.wdata = '0;
            fill_original.wstrb = '0;
        end
    end
    cache_refill #(.LINE_BYTES(LINE_BYTES), .WORD_BYTES(DBUS_BYTES)) u_refill (
        .clk, .rst, .start_valid(state_q == FILL && !fill_started_q),
        .fallback_enable(!request_q.write), .start_ready(fill_ready), .request(fill_original),
        .done_valid(fill_done), .done_ready(state_q == FILL), .installable(fill_installable),
        .response(fill_response), .write_valid(fill_write), .write_word(fill_word), .write_data(fill_data),
        .mem_req_valid(fill_req_valid), .mem_req_ready(fill_req_ready), .mem_request(fill_request),
        .mem_rsp_valid(lower_rsp_valid && state_q == FILL), .mem_response(lower_response)
    );
    cache_writeback #(.LINE_BYTES(LINE_BYTES)) u_writeback (
        .clk, .rst, .start_valid(state_q == WRITEBACK && !wb_started_q), .start_ready(wb_ready),
        .line_addr(probe_base), .read_enable(wb_read), .read_word(wb_word), .read_data(ram_data[way_q]),
        .done_valid(wb_done), .done_ready(state_q == WRITEBACK), .error(wb_error), .fault_addr(wb_fault_addr),
        .req_valid(wb_req_valid), .req_ready(wb_req_ready), .request(wb_request),
        .rsp_valid(lower_rsp_valid && state_q == WRITEBACK), .response(lower_response)
    );
    assign lower_valid = !rst && (state_q == WRITEBACK ? wb_req_valid :
                                 state_q == STORE_SEND ? 1'b1 : fill_req_valid);
    assign lower_request = state_q == WRITEBACK ? wb_request :
                           state_q == STORE_SEND ? request_q : fill_request;
    assign wb_req_ready = state_q == WRITEBACK && lower_ready;
    assign fill_req_ready = state_q == FILL && lower_ready;

    // 普通请求状态：脏 victim 全部写成功后才允许替换，失败则原 valid/dirty/data 都保留。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            request_q <= '0; response_q <= '0;
            way_q <= 0; scan_set_q <= '0;
            maintenance_q <= 0; operation_q <= CACHE_NONE;
            fill_started_q <= 0; wb_started_q <= 0;
            maint_error <= CACHE_OK; maint_fault_addr <= '0;
            fault_valid <= 0; fault_code <= CACHE_OK; fault_addr <= '0;
        end else begin
            fault_valid <= 0;
            case (state_q)
                IDLE: begin
                    if (maint_req_valid && maint_req_ready) begin
                        maintenance_q <= 1;
                        operation_q <= maint_op;
                        scan_set_q <= '0; way_q <= 0;
                        maint_error <= CACHE_OK; maint_fault_addr <= '0;
                        state_q <= ENABLE && DDR_BYTES != 0 && maint_op != CACHE_NONE ? SCAN : MAINT_DONE;
                    end else if (request_fire) begin
                        request_q <= cache_request;
                        fill_started_q <= 0;
                        state_q <= LOOKUP;
                    end
                end
                LOOKUP: begin
                    way_q <= hit ? hit_way : victim_way;
                    if (request_q.write && request_q.wstrb == '0) begin
                        response_q <= '0; state_q <= RESPOND;
                    end else if (hit) begin
                        if (request_q.write) state_q <= STORE_APPLY;
                        else begin response_q <= '{rdata:ram_data[hit_way], error:BUS_OK}; state_q <= RESPOND; end
                    end else state_q <= MISS_CHECK;
                end
                MISS_CHECK: begin
                    wb_started_q <= 0;
                    state_q <= probe_dirty ? WRITEBACK : FILL;
                end
                WRITEBACK: begin
                    if (!wb_started_q && wb_ready) wb_started_q <= 1;
                    if (wb_done) begin
                        if (wb_error != BUS_OK) begin
                            fault_valid <= 1; fault_code <= CACHE_WRITEBACK_ERROR; fault_addr <= wb_fault_addr;
                            if (maintenance_q) begin
                                maint_error <= CACHE_WRITEBACK_ERROR; maint_fault_addr <= wb_fault_addr;
                                state_q <= MAINT_DONE;
                            end else begin
                                response_q <= '{rdata:'0, error:wb_error};
                                state_q <= RESPOND;
                            end
                        end else state_q <= maintenance_q ? SCAN_NEXT : FILL;
                    end
                end
                FILL: begin
                    if (!fill_started_q && fill_ready) fill_started_q <= 1;
                    if (fill_done) begin
                        if (request_q.write) state_q <= fill_installable ? STORE_APPLY : STORE_SEND;
                        else begin response_q <= fill_response; state_q <= RESPOND; end
                    end
                end
                STORE_APPLY: begin response_q <= '0; state_q <= RESPOND; end
                STORE_SEND: if (lower_ready) state_q <= STORE_WAIT;
                STORE_WAIT: if (lower_rsp_valid) begin response_q <= lower_response; state_q <= RESPOND; end
                RESPOND: if (cache_rsp_ready) state_q <= IDLE;

                // 维护逐项扫描；invalidate 拒绝丢弃脏行，不悄悄写回覆盖 DMA 新数据。
                SCAN: begin
                    wb_started_q <= 0;
                    if (probe_dirty && operation_q == CACHE_INVALIDATE) begin
                        maint_error <= CACHE_DIRTY_ERROR; maint_fault_addr <= probe_base;
                        fault_valid <= 1; fault_code <= CACHE_DIRTY_ERROR; fault_addr <= probe_base;
                        state_q <= MAINT_DONE;
                    end else state_q <= probe_dirty ? WRITEBACK : SCAN_NEXT;
                end
                SCAN_NEXT: begin
                    if (!way_q) begin way_q <= 1; state_q <= SCAN; end
                    else if (scan_set_q == SET_W'(SETS-1)) state_q <= MAINT_DONE;
                    else begin scan_set_q <= scan_set_q + 1'b1; way_q <= 0; state_q <= SCAN; end
                end
                MAINT_DONE: if (maint_rsp_ready) begin maintenance_q <= 0; state_q <= IDLE; end
                default: state_q <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial assert (LINE_BYTES >= 2*DBUS_BYTES && (LINE_BYTES & (LINE_BYTES-1)) == 0 &&
                    SETS >= 2 && (SETS & (SETS-1)) == 0 && CACHE_BYTES == 2*SETS*LINE_BYTES)
        else $fatal(1, "D-cache requires power-of-two line and at least two sets");
`endif
endmodule
