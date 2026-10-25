// Module: dma_block_engine
// Description: Two bounded DDR blocks overlap one read and one ordered write with exact narrow fallback and completion prefix.
module dma_block_engine #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit WIDE_ENABLE = 1'b0,
    parameter bit UNIFIED_BUS = 1'b0,
    parameter int unsigned FLASH_BYTES = 0
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
    output logic blk_rd_cmd_valid,
    input logic blk_rd_cmd_ready,
    output block_types_pkg::block_cmd_t blk_rd_cmd,
    input logic blk_rd_valid,
    output logic blk_rd_ready,
    input block_types_pkg::block_r_t blk_rd_data,
    output logic blk_wr_cmd_valid,
    input logic blk_wr_cmd_ready,
    output block_types_pkg::block_cmd_t blk_wr_cmd,
    output logic blk_wr_valid,
    input logic blk_wr_ready,
    output block_types_pkg::block_w_t blk_wr_data,
    input logic blk_wr_rsp_valid,
    output logic blk_wr_rsp_ready,
    input block_types_pkg::block_b_t blk_wr_rsp
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import soc_addr_pkg::*;
    import soc_config_pkg::*;
    typedef enum logic [1:0] {R_IDLE, R_OFFER, R_DATA} read_state_e;
    typedef enum logic [1:0] {W_IDLE, W_OFFER, W_DATA, W_RESPONSE} write_state_e;
    typedef enum logic [2:0] {N_IDLE, N_READ_REQUEST, N_READ_RESPONSE,
                              N_WRITE_REQUEST, N_WRITE_RESPONSE} narrow_state_e;
    read_state_e read_state_q;
    write_state_e write_state_q;
    narrow_state_e narrow_state_q;
    logic active_q;
    logic [31:0] src_q, dst_q, length_q, reserved_q, confirmed_q;
    logic [1:0] slot_valid_q, slot_ready_q;
    logic [31:0] slot_offset_q [2];
    logic [2:0] slot_beats_q [2];
    logic [DDR_DATA_W-1:0] data_q [2][BLOCK_MAX_BEATS];
    logic allocate_slot_q, retire_slot_q, read_slot_q, write_slot_q;
    logic [2:0] read_beat_q, write_beat_q;
    logic [31:0] narrow_bytes_q;
    logic error_q, error_next, error_event;
    logic [31:0] error_offset_q, error_offset_next, error_addr_q, error_addr_next;
    logic [2:0] error_code_q, error_code_next;
    logic [32:0] src_end, dst_end;
    logic src_allowed, dst_allowed, config_valid;
    logic [31:0] plan_src, plan_dst, plan_remaining, plan_beats, plan_bytes;
    logic wide_plan, narrow_word, idle_channels;
    logic read_command_fire, read_data_fire, write_command_fire, write_data_fire, write_response_fire;
    logic narrow_request_fire, narrow_response_fire, bad_read_frame;

    // 与旧引擎同样先验证整个区间；预读不能扩大范围或引入MMIO副作用。
    always_comb begin
        src_end = {1'b0, start_src} + {1'b0, start_length};
        dst_end = {1'b0, start_dst} + {1'b0, start_length};
        src_allowed = (start_src >= ITCM_BASE && src_end <= 33'(ITCM_BASE) + ITCM_BYTES) ||
                      (start_src >= DTCM_BASE && src_end <= 33'(DTCM_BASE) + DTCM_BYTES) ||
                      (DDR_BYTES != 0 && start_src >= DDR_BASE && src_end <= 33'(DDR_BASE) + DDR_BYTES) ||
                      (UNIFIED_BUS && FLASH_BYTES != 0 && start_src >= 32'h30000000 &&
                       src_end <= 33'h030000000 + 33'(FLASH_BYTES));
        dst_allowed = (start_dst >= ITCM_BASE && dst_end <= 33'(ITCM_BASE) + ITCM_BYTES) ||
                      (start_dst >= DTCM_BASE && dst_end <= 33'(DTCM_BASE) + DTCM_BYTES) ||
                      (DDR_BYTES != 0 && start_dst >= DDR_BASE && dst_end <= 33'(DDR_BASE) + DDR_BYTES);
        config_valid = start_length != 0 && src_allowed && dst_allowed &&
                       (src_end <= {1'b0, start_dst} || dst_end <= {1'b0, start_src});
    end

    // reserved仅用于预约下一块，confirmed仅随按序成功写完成推进，不能混成同一游标。
    // 源/目的页界都限制块长；不同余数以及TCM/尾部仍使用原XLEN/byte事务。
    always_comb begin
        plan_src = src_q + reserved_q;
        plan_dst = dst_q + reserved_q;
        plan_remaining = length_q - reserved_q;
        // 统一总线已验证整个源/目的区间；TCM、Flash 和 DDR 都可使用相同块命令。
        // 旧实例保持原 DDR-only 选择，历史验证入口仍可重放。
        wide_plan = WIDE_ENABLE && plan_remaining >= 32 && plan_src[4:0] == 0 && plan_dst[4:0] == 0 &&
                    (UNIFIED_BUS || (DDR_BYTES != 0 && plan_src >= DDR_BASE && plan_dst >= DDR_BASE &&
                     33'(plan_src) + 33'd32 <= 33'(DDR_BASE) + DDR_BYTES &&
                     33'(plan_dst) + 33'd32 <= 33'(DDR_BASE) + DDR_BYTES));
        plan_beats = plan_remaining >> 5;
        if (plan_beats > BLOCK_MAX_BEATS) plan_beats = BLOCK_MAX_BEATS;
        if (plan_beats > ((32'd4096 - 32'(plan_src[11:0])) >> 5))
            plan_beats = (32'd4096 - 32'(plan_src[11:0])) >> 5;
        if (plan_beats > ((32'd4096 - 32'(plan_dst[11:0])) >> 5))
            plan_beats = (32'd4096 - 32'(plan_dst[11:0])) >> 5;
        plan_bytes = plan_beats << 5;
        narrow_word = narrow_bytes_q == DBUS_BYTES;
        idle_channels = read_state_q == R_IDLE && write_state_q == W_IDLE && narrow_state_q == N_IDLE;
    end

    // 展示后的命令只受自己的握手/协调reset控制；另一方向报错不组合撤销valid。
    assign blk_rd_cmd_valid = !rst && read_state_q == R_OFFER;
    assign blk_rd_cmd = '{addr:xlen_t'(32'(src_q + slot_offset_q[read_slot_q])),
        len:8'(slot_beats_q[read_slot_q])-8'd1, size:3'd5, execute:1'b0};
    assign blk_rd_ready = !rst && read_state_q == R_DATA;
    assign blk_wr_cmd_valid = !rst && write_state_q == W_OFFER;
    assign blk_wr_cmd = '{addr:xlen_t'(32'(dst_q + slot_offset_q[write_slot_q])),
        len:8'(slot_beats_q[write_slot_q])-8'd1, size:3'd5, execute:1'b0};
    assign blk_wr_valid = !rst && write_state_q == W_DATA;
    assign blk_wr_data = '{data:data_q[write_slot_q][write_beat_q[1:0]], strb:'1,
        last:write_beat_q == slot_beats_q[write_slot_q]-3'd1};
    assign blk_wr_rsp_ready = !rst && write_state_q == W_RESPONSE;
    assign read_command_fire = blk_rd_cmd_valid && blk_rd_cmd_ready;
    assign read_data_fire = blk_rd_valid && blk_rd_ready;
    assign write_command_fire = blk_wr_cmd_valid && blk_wr_cmd_ready;
    assign write_data_fire = blk_wr_valid && blk_wr_ready;
    assign write_response_fire = blk_wr_rsp_valid && blk_wr_rsp_ready;
    assign bad_read_frame = blk_rd_data.last != (read_beat_q == slot_beats_q[read_slot_q]-3'd1);

    // 窄事务只在块所有者全空时进入，复用slot0首拍；无第三份读数据槽。
    always_comb begin
        request = '0;
        request.addr = xlen_t'(32'((narrow_state_q == N_WRITE_REQUEST ? dst_q : src_q) + confirmed_q));
        request.size = narrow_word ? mem_size_e'($clog2(DBUS_BYTES)) : MEM_BYTE;
        if (narrow_state_q == N_WRITE_REQUEST) begin
            request.write = 1'b1;
            request.wdata = narrow_word ? xlen_t'(data_q[0][0]) :
                (xlen_t'(8'(data_q[0][0])) << (8 * (request.addr & xlen_t'(32'(DBUS_BYTES-1)))));
            request.wstrb = narrow_word ? '1 : DBUS_BYTES'(1 << (request.addr & xlen_t'(32'(DBUS_BYTES-1))));
        end
    end
    assign req_valid = !rst && (narrow_state_q == N_READ_REQUEST || narrow_state_q == N_WRITE_REQUEST);
    assign rsp_ready = !rst && (narrow_state_q == N_READ_RESPONSE || narrow_state_q == N_WRITE_RESPONSE);
    assign narrow_request_fire = req_valid && req_ready;
    assign narrow_response_fire = rsp_valid && rsp_ready;
    assign busy = active_q || finish_valid;

    // 最老offset获错误归属；年轻预读先错、旧B后错或同沿双错均不依赖响应先后覆盖。
    // error_event只阻止本沿预约新offer，不撤销任何已经展示/接受的协议义务。
    always_comb begin
        error_next = error_q;
        error_offset_next = error_offset_q;
        error_addr_next = error_addr_q;
        error_code_next = error_code_q;
        error_event = 1'b0;
        if (read_data_fire && (blk_rd_data.error != BUS_OK || bad_read_frame)) begin
            error_event = 1'b1;
            if (!error_next || slot_offset_q[read_slot_q] < error_offset_next) begin
                error_next = 1'b1;
                error_offset_next = slot_offset_q[read_slot_q];
                error_addr_next = src_q + slot_offset_q[read_slot_q];
                error_code_next = blk_rd_data.error == BUS_DECERR ? 3'd2 : 3'd3;
            end
        end
        if (write_response_fire && blk_wr_rsp.error != BUS_OK) begin
            error_event = 1'b1;
            if (!error_next || slot_offset_q[write_slot_q] < error_offset_next) begin
                error_next = 1'b1;
                error_offset_next = slot_offset_q[write_slot_q];
                error_addr_next = dst_q + slot_offset_q[write_slot_q];
                error_code_next = blk_wr_rsp.error == BUS_DECERR ? 3'd4 : 3'd5;
            end
        end
        if (narrow_response_fire && response.error != BUS_OK) begin
            error_event = 1'b1;
            error_next = 1'b1;
            error_offset_next = confirmed_q;
            error_addr_next = (narrow_state_q == N_WRITE_RESPONSE ? dst_q : src_q) + confirmed_q;
            if (narrow_state_q == N_WRITE_RESPONSE)
                error_code_next = response.error == BUS_DECERR ? 3'd4 : 3'd5;
            else error_code_next = response.error == BUS_DECERR ? 3'd2 : 3'd3;
        end
    end

    // 两槽预约与有序回收；每方向只持一份owner，写必须等完整读块就绪。
    always_ff @(posedge clk) begin
        if (rst) begin
            active_q <= 1'b0;
            src_q <= '0; dst_q <= '0; length_q <= '0;
            reserved_q <= '0; confirmed_q <= '0;
            slot_valid_q <= '0; slot_ready_q <= '0;
            allocate_slot_q <= 1'b0; retire_slot_q <= 1'b0;
            read_slot_q <= 1'b0; write_slot_q <= 1'b0;
            read_beat_q <= '0; write_beat_q <= '0; narrow_bytes_q <= '0;
            read_state_q <= R_IDLE; write_state_q <= W_IDLE; narrow_state_q <= N_IDLE;
            error_q <= 1'b0; error_offset_q <= '0; error_addr_q <= '0; error_code_q <= '0;
            finish_valid <= 1'b0; finish_error <= 1'b0; finish_code <= '0;
            finish_bytes <= '0; finish_addr <= '0;
            for (int slot = 0; slot < 2; slot++) begin
                slot_offset_q[slot] <= '0;
                slot_beats_q[slot] <= '0;
            end
        end else begin
            finish_valid <= 1'b0;
            error_q <= error_next;
            error_offset_q <= error_offset_next;
            error_addr_q <= error_addr_next;
            error_code_q <= error_code_next;
            if (!active_q && !finish_valid && start_valid) begin
                src_q <= start_src; dst_q <= start_dst; length_q <= start_length;
                reserved_q <= '0; confirmed_q <= '0;
                slot_valid_q <= '0; slot_ready_q <= '0;
                allocate_slot_q <= 1'b0; retire_slot_q <= 1'b0;
                error_q <= 1'b0; error_code_q <= '0; error_addr_q <= '0; error_offset_q <= '0;
                finish_error <= 1'b0; finish_code <= '0; finish_bytes <= '0; finish_addr <= '0;
                if (config_valid) active_q <= 1'b1;
                else begin
                    finish_valid <= 1'b1;
                    finish_error <= 1'b1;
                    finish_code <= 3'd1;
                    finish_addr <= !src_allowed ? start_src : start_dst;
                end
            end
            if (active_q && !error_q && !error_event && narrow_state_q == N_IDLE) begin
                if (write_state_q == W_IDLE && slot_ready_q[retire_slot_q]) begin
                    write_slot_q <= retire_slot_q;
                    write_beat_q <= '0;
                    write_state_q <= W_OFFER;
                    slot_ready_q[retire_slot_q] <= 1'b0;
                end
                if (read_state_q == R_IDLE && !slot_valid_q[allocate_slot_q] && reserved_q < length_q) begin
                    if (wide_plan) begin
                        slot_valid_q[allocate_slot_q] <= 1'b1;
                        slot_ready_q[allocate_slot_q] <= 1'b0;
                        slot_offset_q[allocate_slot_q] <= reserved_q;
                        slot_beats_q[allocate_slot_q] <= 3'(plan_beats);
                        read_slot_q <= allocate_slot_q;
                        allocate_slot_q <= !allocate_slot_q;
                        reserved_q <= reserved_q + plan_bytes;
                        read_beat_q <= '0;
                        read_state_q <= R_OFFER;
                    end else if (idle_channels && slot_valid_q == 0 && reserved_q == confirmed_q) begin
                        narrow_bytes_q <= ((plan_src & (DBUS_BYTES-1)) == 0 &&
                                           (plan_dst & (DBUS_BYTES-1)) == 0 && plan_remaining >= DBUS_BYTES) ?
                                           32'(DBUS_BYTES) : 32'd1;
                        narrow_state_q <= N_READ_REQUEST;
                    end
                end
            end
            if (read_command_fire) read_state_q <= R_DATA;
            if (read_data_fire) begin
                if (read_beat_q < 3'(BLOCK_MAX_BEATS)) data_q[read_slot_q][read_beat_q[1:0]] <= blk_rd_data.data;
                if (blk_rd_data.last) begin
                    read_state_q <= R_IDLE;
                    if (!error_q && !error_event) slot_ready_q[read_slot_q] <= 1'b1;
                    else slot_valid_q[read_slot_q] <= 1'b0;
                end else if (read_beat_q < 3'(BLOCK_MAX_BEATS)) read_beat_q <= read_beat_q + 3'd1;
            end
            if (write_command_fire) write_state_q <= W_DATA;
            if (write_data_fire) begin
                if (blk_wr_data.last) write_state_q <= W_RESPONSE;
                else write_beat_q <= write_beat_q + 3'd1;
            end
            if (write_response_fire) begin
                write_state_q <= W_IDLE;
                slot_valid_q[write_slot_q] <= 1'b0;
                retire_slot_q <= !retire_slot_q;
                if (blk_wr_rsp.error == BUS_OK)
                    confirmed_q <= confirmed_q + (32'(slot_beats_q[write_slot_q]) << 5);
            end
            unique case (narrow_state_q)
                N_READ_REQUEST: if (narrow_request_fire) narrow_state_q <= N_READ_RESPONSE;
                N_READ_RESPONSE: if (narrow_response_fire) begin
                    if (response.error != BUS_OK) narrow_state_q <= N_IDLE;
                    else begin
                        data_q[0][0] <= DDR_DATA_W'(narrow_word ? response.rdata :
                            xlen_t'(8'(response.rdata >> (8 * ((src_q + confirmed_q) & (DBUS_BYTES-1))))));
                        narrow_state_q <= N_WRITE_REQUEST;
                    end
                end
                N_WRITE_REQUEST: if (narrow_request_fire) narrow_state_q <= N_WRITE_RESPONSE;
                N_WRITE_RESPONSE: if (narrow_response_fire) begin
                    narrow_state_q <= N_IDLE;
                    if (response.error == BUS_OK) begin
                        confirmed_q <= confirmed_q + narrow_bytes_q;
                        reserved_q <= reserved_q + narrow_bytes_q;
                    end
                end
                default: ;
            endcase
            // error以后只排空已展示/接受的事务；未展示的年轻READY槽随finish清理。
            if (active_q && idle_channels && (error_q || confirmed_q == length_q)) begin
                active_q <= 1'b0;
                slot_valid_q <= '0; slot_ready_q <= '0;
                finish_valid <= 1'b1;
                finish_error <= error_q;
                finish_code <= error_q ? error_code_q : 3'd0;
                finish_addr <= error_q ? error_addr_q : 32'd0;
                finish_bytes <= confirmed_q;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && active_q) begin
        assert (confirmed_q <= reserved_q && reserved_q <= length_q)
            else $fatal(1, "DMA confirmed/reserved prefix ordering");
        assert (read_state_q == R_IDLE || write_state_q == W_IDLE || read_slot_q != write_slot_q)
            else $fatal(1, "DMA read/write owners overlap one buffer");
        if (write_response_fire)
            assert (slot_offset_q[write_slot_q] == confirmed_q)
                else $fatal(1, "DMA write completed outside ordered prefix");
        if (narrow_state_q != N_IDLE)
            assert (slot_valid_q == 0 && read_state_q == R_IDLE && write_state_q == W_IDLE)
                else $fatal(1, "DMA narrow fallback crossed active block owner");
    end
`endif
endmodule
