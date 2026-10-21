// Module: store_result_monitor
// Description: Decodes test results only after a tagged Store response and successful retirement.
module store_result_monitor #(
    parameter int unsigned RESULT_BYTES = 4
) (
    input logic clk, rst,
    input core_types_pkg::xlen_t result_addr,
    input logic dmem_store_fire,
    input core_types_pkg::xlen_t dmem_store_addr, dmem_store_data,
    input logic [core_config_pkg::DBUS_BYTES-1:0] dmem_store_strb,
    input pipeline_pkg::retire_id_t store_request_id,
    input logic store_response_fire, store_response_error,
    input pipeline_pkg::retire_id_t store_response_id,
    input logic store_retire_fire, store_retire_error,
    input pipeline_pkg::retire_id_t store_retire_id,
    input logic cancel,
    output logic test_done, test_pass,
    output logic [31:0] test_code
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    localparam logic [7:0] RESULT_MASK = RESULT_BYTES == 8 ? 8'hff : 8'h0f;
    typedef struct packed {
        logic valid;
        retire_id_t id;
        logic response_seen, response_error;
        logic [63:0] data;
        logic [7:0] mask;
    } pending_store_t;
    typedef enum logic [3:0] {
        MON_OK, REQ_BUSY, RSP_ORPHAN, RSP_ID, RSP_DUPLICATE,
        RETIRE_ORPHAN, RETIRE_ID, RETIRE_BEFORE_RSP, RETIRE_AFTER_ERROR, REQ_CANCEL
    } monitor_error_e;
    pending_store_t pending_q, pending_d, request;
    logic [63:0] result_q, result_d;
    logic [7:0] valid_bytes_q, valid_bytes_d;
    logic done_d, pass_d;
    logic [31:0] code_d;
    monitor_error_e protocol_error;
    xlen_t lane_addr;
    int unsigned result_lane;

    initial begin
        assert (RESULT_BYTES == 4 || RESULT_BYTES == 8)
            else $fatal(1, "STORE_MONITOR_RESULT_BYTES must be 4 or 8");
    end

    // 写数据/strb 属于对齐后的总线字；地址本身可以指向 RV64 的高半字或单字节。
    // 请求只留下候选字节，不更新结果。普通非 tohost Store 也跟踪响应与退休所有权。
    always_comb begin
        request = '0;
        request.valid = 1'b1;
        request.id = store_request_id;
        lane_addr = '0;
        result_lane = 0;
        for (int lane = 0; lane < DBUS_BYTES; lane++) begin
            lane_addr = (dmem_store_addr & ~xlen_t'(DBUS_BYTES-1)) + xlen_t'(lane);
            if (dmem_store_strb[lane] && lane_addr >= result_addr &&
                (lane_addr - result_addr) < xlen_t'(RESULT_BYTES)) begin
                result_lane = int'(lane_addr - result_addr);
                request.mask[result_lane] = 1'b1;
                request.data[result_lane*8 +: 8] = dmem_store_data[lane*8 +: 8];
            end
        end
    end

    // 目前 Core 的单 LSU 请求先于响应至少一沿。响应与退休按完整 ID 关联，
    // 退休同沿可接纳下一笔请求；完成与退休之间可以任意等待，不丢掉旧 data/strb。
    always_comb begin
        pending_d = pending_q;
        result_d = result_q;
        valid_bytes_d = valid_bytes_q;
        done_d = test_done;
        pass_d = test_pass;
        code_d = test_code;
        protocol_error = MON_OK;

        if (store_response_fire) begin
            if (!pending_d.valid) protocol_error = RSP_ORPHAN;
            else if (store_response_id != pending_d.id) protocol_error = RSP_ID;
            else if (pending_d.response_seen) protocol_error = RSP_DUPLICATE;
            else begin
                pending_d.response_seen = 1'b1;
                pending_d.response_error = store_response_error;
            end
        end

        if (store_retire_fire && protocol_error == MON_OK) begin
            // EX 对齐异常可能没有外发 Store；这种异常退休不是丢失了一个总线响应。
            if (!pending_d.valid) begin
                if (!store_retire_error) protocol_error = RETIRE_ORPHAN;
            end else if (store_retire_id != pending_d.id) protocol_error = RETIRE_ID;
            else if (!pending_d.response_seen) protocol_error = RETIRE_BEFORE_RSP;
            else if (pending_d.response_error && !store_retire_error) protocol_error = RETIRE_AFTER_ERROR;
            else begin
                if (store_retire_error) begin
                    // 失败的结果写不能留下可与后续半字拼成 PASS 的残片；要求重新完整报告。
                    if (|pending_d.mask) begin
                        result_d = '0;
                        valid_bytes_d = '0;
                    end
                end else if (!cancel && !test_done) begin
                    for (int byte_idx = 0; byte_idx < RESULT_BYTES; byte_idx++) begin
                        if (pending_d.mask[byte_idx]) begin
                            result_d[byte_idx*8 +: 8] = pending_d.data[byte_idx*8 +: 8];
                            valid_bytes_d[byte_idx] = 1'b1;
                        end
                    end
                    // 每次完整覆盖形成一帧。零帧不报告，但清掉有效掩码，
                    // 后一帧不能借用旧零高半，在新的高半 Store 退休前提前 PASS。
                    if ((valid_bytes_d & RESULT_MASK) == RESULT_MASK) begin
                        if (result_d != 0) begin
                            done_d = 1'b1;
                            pass_d = result_d == 64'd1;
                            code_d = result_d[31:0];
                        end else valid_bytes_d = '0;
                    end
                end
                pending_d = '0;
            end
        end

        if (cancel) begin
            // 无在途结果写的普通全局重定向，不抹掉已经退休的部分字节。
            if (pending_q.valid && |pending_q.mask) begin
                result_d = '0;
                valid_bytes_d = '0;
            end
            pending_d = '0;
        end

        if (dmem_store_fire && protocol_error == MON_OK) begin
            if (cancel) protocol_error = REQ_CANCEL;
            else if (pending_d.valid) protocol_error = REQ_BUSY;
            else pending_d = request;
        end
    end

    // 只在时钟沿检查协议；负向 TB 必须匹配具体错误，不能把任意仿真崩溃算作通过。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= '0;
            result_q <= '0;
            valid_bytes_q <= '0;
            test_done <= 1'b0;
            test_pass <= 1'b0;
            test_code <= '0;
        end else begin
            unique case (protocol_error)
                MON_OK: begin end
                REQ_BUSY: $fatal(1, "STORE_MONITOR_REQ_BUSY");
                RSP_ORPHAN: $fatal(1, "STORE_MONITOR_RSP_ORPHAN");
                RSP_ID: $fatal(1, "STORE_MONITOR_RSP_ID");
                RSP_DUPLICATE: $fatal(1, "STORE_MONITOR_RSP_DUPLICATE");
                RETIRE_ORPHAN: $fatal(1, "STORE_MONITOR_RETIRE_ORPHAN");
                RETIRE_ID: $fatal(1, "STORE_MONITOR_RETIRE_ID");
                RETIRE_BEFORE_RSP: $fatal(1, "STORE_MONITOR_RETIRE_BEFORE_RSP");
                RETIRE_AFTER_ERROR: $fatal(1, "STORE_MONITOR_RETIRE_AFTER_ERROR");
                REQ_CANCEL: $fatal(1, "STORE_MONITOR_REQ_CANCEL");
                default: $fatal(1, "STORE_MONITOR_UNKNOWN_ERROR");
            endcase
            pending_q <= pending_d;
            result_q <= result_d;
            valid_bytes_q <= valid_bytes_d;
            test_done <= done_d;
            test_pass <= pass_d;
            test_code <= code_d;
        end
    end
endmodule
