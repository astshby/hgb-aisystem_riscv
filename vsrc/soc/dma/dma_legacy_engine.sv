// Module: dma_legacy_engine
// Description: Single-channel memory copy master with exact read/write completion.
module dma_legacy_engine #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit WIDE_ENABLE = 1'b0
) (
    input logic clk, rst,
    input logic start_valid,
    input logic [31:0] start_src, start_dst, start_length,
    output logic busy,
    output logic finish_valid, finish_error,
    output logic [2:0] finish_code,
    output logic [31:0] finish_bytes, finish_addr,
    output logic req_valid,
    input logic req_ready,
    output bus_types_pkg::bus_req_t request,
    input logic rsp_valid,
    output logic rsp_ready,
    input bus_types_pkg::bus_rsp_t response,
    output logic wide_req_valid,
    input logic wide_req_ready,
    output bus_types_pkg::ddr_req_t wide_request,
    input logic wide_rsp_valid,
    output logic wide_rsp_ready,
    input bus_types_pkg::ddr_rsp_t wide_response
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    import soc_config_pkg::*;
    typedef enum logic [2:0] {IDLE, READ_REQUEST, READ_RESPONSE,
                              WRITE_REQUEST, WRITE_RESPONSE} state_e;
    state_e state_q;
    logic [31:0] src_q, dst_q, length_q, bytes_q;
    logic [32:0] src_end, dst_end;
    logic src_allowed, dst_allowed, config_valid;
    logic [31:0] read_addr, write_addr, remaining;
    logic full_beat, wide_beat;
    logic [31:0] beat_bytes;
    logic [DDR_DATA_W-1:0] data_q;
    logic read_request_fire, write_request_fire, response_fire;
    bus_error_e response_error;

    // 入口先检查整个范围；拒绝 MMIO、ROM、越界和重叠，不允许部分复制后才发现格式错误。
    always_comb begin
        src_end = {1'b0, start_src} + {1'b0, start_length};
        dst_end = {1'b0, start_dst} + {1'b0, start_length};
        src_allowed = (start_src >= ITCM_BASE && src_end <= 33'(ITCM_BASE) + ITCM_BYTES) ||
                      (start_src >= DTCM_BASE && src_end <= 33'(DTCM_BASE) + DTCM_BYTES) ||
                      (DDR_BYTES != 0 && start_src >= DDR_BASE &&
                       src_end <= 33'(DDR_BASE) + DDR_BYTES);
        dst_allowed = (start_dst >= ITCM_BASE && dst_end <= 33'(ITCM_BASE) + ITCM_BYTES) ||
                      (start_dst >= DTCM_BASE && dst_end <= 33'(DTCM_BASE) + DTCM_BYTES) ||
                      (DDR_BYTES != 0 && start_dst >= DDR_BASE &&
                       dst_end <= 33'(DDR_BASE) + DDR_BYTES);
        config_valid = start_length != 0 && src_allowed && dst_allowed &&
                       (src_end <= {1'b0, start_dst} || dst_end <= {1'b0, start_src});
    end

    // 只有 DDR→DDR 的完整对齐段走真实 256-bit 端口；TCM 不扩宽，头尾仍走原窄接口。
    // bytes_q 只在成功写响应后改变，因此一次读写配对期间宽度、地址与掩码保持不变。
    always_comb begin
        read_addr = src_q + bytes_q;
        write_addr = dst_q + bytes_q;
        remaining = length_q - bytes_q;
        full_beat = ((read_addr & (DBUS_BYTES-1)) == 0) &&
                    ((write_addr & (DBUS_BYTES-1)) == 0) && remaining >= DBUS_BYTES;
        wide_beat = WIDE_ENABLE && DDR_BYTES != 0 &&
                    read_addr >= DDR_BASE && write_addr >= DDR_BASE &&
                    33'(read_addr) + DDR_BEAT_BYTES <= 33'(DDR_BASE) + DDR_BYTES &&
                    33'(write_addr) + DDR_BEAT_BYTES <= 33'(DDR_BASE) + DDR_BYTES &&
                    read_addr[4:0] == 0 && write_addr[4:0] == 0 && remaining >= DDR_BEAT_BYTES;
        beat_bytes = wide_beat ? 32'(DDR_BEAT_BYTES) : (full_beat ? 32'(DBUS_BYTES) : 32'd1);
        request = '0;
        request.addr = state_q == WRITE_REQUEST ? xlen_t'(write_addr) : xlen_t'(read_addr);
        request.size = full_beat ? mem_size_e'($clog2(DBUS_BYTES)) : MEM_BYTE;
        if (state_q == WRITE_REQUEST) begin
            request.write = 1'b1;
            request.wdata = full_beat ? xlen_t'(data_q) :
                            (xlen_t'(8'(data_q)) << (8 * (write_addr & (DBUS_BYTES-1))));
            request.wstrb = full_beat ? '1 :
                            DBUS_BYTES'(1 << (write_addr & (DBUS_BYTES-1)));
        end
        wide_request = '0;
        wide_request.addr = state_q == WRITE_REQUEST ? xlen_t'(write_addr) : xlen_t'(read_addr);
        wide_request.size = 3'd5;
        wide_request.write = state_q == WRITE_REQUEST;
        wide_request.wdata = data_q;
        wide_request.wstrb = '1;
    end
    assign req_valid = !rst && !wide_beat && (state_q == READ_REQUEST || state_q == WRITE_REQUEST);
    assign rsp_ready = !rst && !wide_beat && (state_q == READ_RESPONSE || state_q == WRITE_RESPONSE);
    assign wide_req_valid = !rst && wide_beat && (state_q == READ_REQUEST || state_q == WRITE_REQUEST);
    assign wide_rsp_ready = !rst && wide_beat && (state_q == READ_RESPONSE || state_q == WRITE_RESPONSE);
    assign read_request_fire = state_q == READ_REQUEST &&
                              ((req_valid && req_ready) || (wide_req_valid && wide_req_ready));
    assign write_request_fire = state_q == WRITE_REQUEST &&
                               ((req_valid && req_ready) || (wide_req_valid && wide_req_ready));
    assign response_fire = (rsp_valid && rsp_ready) || (wide_rsp_valid && wide_rsp_ready);
    assign response_error = wide_beat ? wide_response.error : response.error;
    assign busy = (state_q != IDLE) || finish_valid;

    // 一份 256-bit 数据槽保存宽/窄读结果；不是用多个 XLEN 请求模拟宽 DDR beat。
    // 每笔读响应先进入 data_q，再发一笔写；只有写响应成功才增加已完成字节数。
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE;
            src_q <= '0;
            dst_q <= '0;
            length_q <= '0;
            bytes_q <= '0;
            data_q <= '0;
            finish_valid <= 1'b0;
            finish_error <= 1'b0;
            finish_code <= '0;
            finish_bytes <= '0;
            finish_addr <= '0;
        end else begin
            finish_valid <= 1'b0;
            case (state_q)
                IDLE: if (start_valid && !finish_valid) begin
                    src_q <= start_src;
                    dst_q <= start_dst;
                    length_q <= start_length;
                    bytes_q <= '0;
                    finish_error <= 1'b0;
                    finish_code <= '0;
                    finish_bytes <= '0;
                    finish_addr <= '0;
                    if (config_valid) state_q <= READ_REQUEST;
                    else begin
                        finish_valid <= 1'b1;
                        finish_error <= 1'b1;
                        finish_code <= 3'd1;
                        finish_addr <= !src_allowed ? start_src : start_dst;
                    end
                end
                READ_REQUEST: if (read_request_fire) state_q <= READ_RESPONSE;
                READ_RESPONSE: if (response_fire) begin
                    if (response_error != BUS_OK) begin
                        finish_valid <= 1'b1;
                        finish_error <= 1'b1;
                        finish_code <= response_error == BUS_DECERR ? 3'd2 : 3'd3;
                        finish_bytes <= bytes_q;
                        finish_addr <= read_addr;
                        state_q <= IDLE;
                    end else begin
                        data_q <= wide_beat ? wide_response.rdata :
                                  DDR_DATA_W'(full_beat ? response.rdata :
                                  xlen_t'(8'(response.rdata >>
                                            (8 * (read_addr & (DBUS_BYTES-1))))));
                        state_q <= WRITE_REQUEST;
                    end
                end
                WRITE_REQUEST: if (write_request_fire) state_q <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (response_fire) begin
                    if (response_error != BUS_OK) begin
                        finish_valid <= 1'b1;
                        finish_error <= 1'b1;
                        finish_code <= response_error == BUS_DECERR ? 3'd4 : 3'd5;
                        finish_bytes <= bytes_q;
                        finish_addr <= write_addr;
                        state_q <= IDLE;
                    end else begin
                        bytes_q <= bytes_q + beat_bytes;
                        if (bytes_q + beat_bytes == length_q) begin
                            finish_valid <= 1'b1;
                            finish_error <= 1'b0;
                            finish_code <= '0;
                            finish_bytes <= length_q;
                            finish_addr <= '0;
                            state_q <= IDLE;
                        end else state_q <= READ_REQUEST;
                    end
                end
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
