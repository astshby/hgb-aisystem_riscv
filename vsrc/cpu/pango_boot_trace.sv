// Module: pango_boot_trace
// Description: Board-side capture of the first fetch addresses, the first scalar commits with
//              successors, the first exception, and a back-end snapshot (allocation, issue,
//              completion, retirement, redirect counts, ROB occupancy and first fetch response)
//              reported as fixed-layout ASCII lines from an independent Core-domain UART.
module pango_boot_trace #(
    parameter int unsigned CLOCK_HZ = 83806818,
    parameter int unsigned BAUD = 115200,
    parameter int unsigned SLOTS = 4,
    parameter int unsigned PC_WIDTH = 32
) (
    input logic clk_core,
    input logic board_reset_n,
    input logic reset_async,
    input logic commit_valid,
    input logic commit_exception,
    input logic [PC_WIDTH-1:0] commit_pc,
    input logic [PC_WIDTH-1:0] commit_next_pc,
    input logic [31:0] commit_inst,
    input logic fetch_valid,
    input logic [PC_WIDTH-1:0] fetch_addr,
    input logic [1:0] dbg_alloc_fire, dbg_issue_fire, dbg_completion_valid, dbg_retire_fire,
    input logic dbg_redirect_valid,
    input logic [4:0] dbg_rob_occupancy,
    input logic [3:0] dbg_head_state, dbg_pipe_state,
    input logic [31:0] dbg_first_rsp,
    input logic dbg_first_rsp_error,
    input logic dbg_fetch_fire, dbg_rsp_fire, dbg_frontend_redirect, dbg_decode_valid,
    input logic [1:0] dbg_push_count, dbg_pop_count,
    input logic [7:0] dbg_queue_occupancy, dbg_iq_occupancy,
    output logic tx,
    output logic takeover
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam int unsigned SLOT_W = $clog2(SLOTS);
    localparam int unsigned BAUD_DIV = (CLOCK_HZ + BAUD / 2) / BAUD;
    localparam int unsigned DIV_W = $clog2(BAUD_DIV + 1);
    localparam int unsigned GAP_CYCLES = CLOCK_HZ / 50;
    localparam int unsigned GAP_W = $clog2(GAP_CYCLES + 1);
    // 行格式 Tn PC=xxxxxxxx NX=xxxxxxxx INST=xxxxxxxx E=d CRLF，共 46 字节。
    // F 行：PC 为取指地址；B 行：PC/NX/INST/E 为提交；S 行：三组 32 位计数/状态；
    // 最后一行 XE 为首异常快照。表内只打印 PC 低 32 位。
    localparam logic [5:0] CHAR_LAST = 6'd45;
    // 行序：F0..F3、B0..B3、S0..S5、XE，共 15 行；S 行由首异常快照填充。
    localparam logic [3:0] LINE_S0 = 4'(2 * SLOTS);
    localparam logic [3:0] LINE_S1 = 4'(2 * SLOTS + 1);
    localparam logic [3:0] LINE_S2 = 4'(2 * SLOTS + 2);
    localparam logic [3:0] LINE_S3 = 4'(2 * SLOTS + 3);
    localparam logic [3:0] LINE_S4 = 4'(2 * SLOTS + 4);
    localparam logic [3:0] LINE_S5 = 4'(2 * SLOTS + 5);
    localparam logic [3:0] LINE_LAST = 4'(2 * SLOTS + 6);
    localparam logic [7:0] CHAR_CR = 8'h0d, CHAR_LF = 8'h0a;

    wire event_reset = reset_async || !board_reset_n;

    // 取指前缀与提交前缀；异常不冻结记录。
    logic [15:0] count_q, fetch_count_q;
    logic prefix_done_q, fetch_done_q, exc_seen_q;
    logic [PC_WIDTH-1:0] slot_pc_q [SLOTS];
    logic [PC_WIDTH-1:0] slot_next_q [SLOTS];
    logic [31:0] slot_inst_q [SLOTS];
    logic slot_exc_q [SLOTS];
    logic [PC_WIDTH-1:0] fetch_addr_q [SLOTS];
    logic [PC_WIDTH-1:0] exc_pc_q, exc_next_q;
    logic [31:0] exc_inst_q;

    // 后端累计计数与首异常时刻快照；快照后帧内容保持不变。
    logic [31:0] alloc_cnt_q, issue_cnt_q, compl_cnt_q, retire_cnt_q, redirect_cnt_q, fetch_req_cnt_q;
    logic [4:0] max_rob_q;
    logic [31:0] snap_alloc_q, snap_issue_q, snap_compl_q, snap_retire_q, snap_redirect_q, snap_fetch_q;
    logic [31:0] snap_first_rsp_q;
    logic [4:0] snap_max_rob_q;
    logic [3:0] snap_head_q, snap_pipe_q;
    logic snap_first_rsp_error_q;

    // 取指段累计量：请求沿、应答沿、前端口重定向、译码有效拍、入队/出队条数与队列占用峰值。
    logic [31:0] fetch_fire_cnt_q, rsp_fire_cnt_q, front_redirect_cnt_q, decode_valid_cnt_q;
    logic [31:0] push_cnt_q, pop_cnt_q;
    logic [7:0] max_queue_q;
    logic [31:0] snap_fetch_fire_q, snap_rsp_fire_q, snap_front_redirect_q, snap_decode_valid_q;
    logic [31:0] snap_push_q, snap_pop_q;
    logic [7:0] snap_max_queue_q, snap_queue_q, snap_iq_q;

    always_ff @(posedge clk_core or posedge event_reset) begin
        if (event_reset) begin
            count_q <= '0;
            fetch_count_q <= '0;
            prefix_done_q <= 1'b0;
            fetch_done_q <= 1'b0;
            exc_seen_q <= 1'b0;
            for (int slot = 0; slot < SLOTS; slot++) begin
                slot_pc_q[slot] <= '0;
                slot_next_q[slot] <= '0;
                slot_inst_q[slot] <= '0;
                slot_exc_q[slot] <= 1'b0;
                fetch_addr_q[slot] <= '0;
            end
            exc_pc_q <= '0;
            exc_next_q <= '0;
            exc_inst_q <= '0;
            alloc_cnt_q <= '0;
            issue_cnt_q <= '0;
            compl_cnt_q <= '0;
            retire_cnt_q <= '0;
            redirect_cnt_q <= '0;
            fetch_req_cnt_q <= '0;
            max_rob_q <= '0;
            snap_alloc_q <= '0;
            snap_issue_q <= '0;
            snap_compl_q <= '0;
            snap_retire_q <= '0;
            snap_redirect_q <= '0;
            snap_fetch_q <= '0;
            snap_first_rsp_q <= '0;
            snap_max_rob_q <= '0;
            snap_head_q <= '0;
            snap_pipe_q <= '0;
            snap_first_rsp_error_q <= 1'b0;
            fetch_fire_cnt_q <= '0;
            rsp_fire_cnt_q <= '0;
            front_redirect_cnt_q <= '0;
            decode_valid_cnt_q <= '0;
            push_cnt_q <= '0;
            pop_cnt_q <= '0;
            max_queue_q <= '0;
            snap_fetch_fire_q <= '0;
            snap_rsp_fire_q <= '0;
            snap_front_redirect_q <= '0;
            snap_decode_valid_q <= '0;
            snap_push_q <= '0;
            snap_pop_q <= '0;
            snap_max_queue_q <= '0;
            snap_queue_q <= '0;
            snap_iq_q <= '0;
        end else begin
            // 计数在快照后继续累加，但帧只显示首异常时刻的值。
            alloc_cnt_q <= alloc_cnt_q + 32'(dbg_alloc_fire[0]) + 32'(dbg_alloc_fire[1]);
            issue_cnt_q <= issue_cnt_q + 32'(dbg_issue_fire[0]) + 32'(dbg_issue_fire[1]);
            compl_cnt_q <= compl_cnt_q + 32'(dbg_completion_valid[0]) + 32'(dbg_completion_valid[1]);
            retire_cnt_q <= retire_cnt_q + 32'(dbg_retire_fire[0]) + 32'(dbg_retire_fire[1]);
            redirect_cnt_q <= redirect_cnt_q + 32'(dbg_redirect_valid);
            if (fetch_valid) fetch_req_cnt_q <= fetch_req_cnt_q + 1'b1;
            if (dbg_rob_occupancy > max_rob_q) max_rob_q <= dbg_rob_occupancy;
            if (dbg_fetch_fire) fetch_fire_cnt_q <= fetch_fire_cnt_q + 1'b1;
            if (dbg_rsp_fire) rsp_fire_cnt_q <= rsp_fire_cnt_q + 1'b1;
            if (dbg_frontend_redirect) front_redirect_cnt_q <= front_redirect_cnt_q + 1'b1;
            if (dbg_decode_valid) decode_valid_cnt_q <= decode_valid_cnt_q + 1'b1;
            push_cnt_q <= push_cnt_q + 32'(dbg_push_count);
            pop_cnt_q <= pop_cnt_q + 32'(dbg_pop_count);
            if (dbg_queue_occupancy > max_queue_q) max_queue_q <= dbg_queue_occupancy;

            if (fetch_valid && !fetch_done_q) begin
                fetch_addr_q[fetch_count_q[SLOT_W-1:0]] <= fetch_addr;
                if (fetch_count_q == 16'(SLOTS - 1)) fetch_done_q <= 1'b1;
                else fetch_count_q <= fetch_count_q + 1'b1;
            end
            if (commit_valid) begin
                if (!prefix_done_q) begin
                    slot_pc_q[count_q[SLOT_W-1:0]] <= commit_pc;
                    slot_next_q[count_q[SLOT_W-1:0]] <= commit_next_pc;
                    slot_inst_q[count_q[SLOT_W-1:0]] <= commit_inst;
                    slot_exc_q[count_q[SLOT_W-1:0]] <= commit_exception;
                    if (count_q == 16'(SLOTS - 1)) prefix_done_q <= 1'b1;
                    else count_q <= count_q + 1'b1;
                end
                if (commit_exception && !exc_seen_q) begin
                    exc_pc_q <= commit_pc;
                    exc_next_q <= commit_next_pc;
                    exc_inst_q <= commit_inst;
                    exc_seen_q <= 1'b1;
                    snap_alloc_q <= alloc_cnt_q;
                    snap_issue_q <= issue_cnt_q;
                    snap_compl_q <= compl_cnt_q;
                    snap_retire_q <= retire_cnt_q;
                    snap_redirect_q <= redirect_cnt_q;
                    snap_fetch_q <= fetch_req_cnt_q;
                    snap_first_rsp_q <= dbg_first_rsp;
                    snap_max_rob_q <= (dbg_rob_occupancy > max_rob_q) ? dbg_rob_occupancy : max_rob_q;
                    snap_head_q <= dbg_head_state;
                    snap_pipe_q <= dbg_pipe_state;
                    snap_first_rsp_error_q <= dbg_first_rsp_error;
                    snap_fetch_fire_q <= fetch_fire_cnt_q + 32'(dbg_fetch_fire);
                    snap_rsp_fire_q <= rsp_fire_cnt_q + 32'(dbg_rsp_fire);
                    snap_front_redirect_q <= front_redirect_cnt_q + 32'(dbg_frontend_redirect);
                    snap_decode_valid_q <= decode_valid_cnt_q + 32'(dbg_decode_valid);
                    snap_push_q <= push_cnt_q + 32'(dbg_push_count);
                    snap_pop_q <= pop_cnt_q + 32'(dbg_pop_count);
                    snap_max_queue_q <= (dbg_queue_occupancy > max_queue_q) ? dbg_queue_occupancy : max_queue_q;
                    snap_queue_q <= dbg_queue_occupancy;
                    snap_iq_q <= dbg_iq_occupancy;
                end
            end
        end
    end

    // 接管条件与首异常绑定：启动正常时保持板级 UART 由应用固件驱动。
    assign takeover = exc_seen_q;

    logic [3:0] line_q, slot_idx;
    logic [5:0] char_q;
    logic [GAP_W-1:0] gap_q;
    logic takeover_q;
    logic [PC_WIDTH-1:0] line_pc, line_next;
    logic [31:0] line_inst;
    logic line_exc;
    logic [7:0] line_tag0, line_tag1;
    logic [7:0] frame_byte;

    function automatic logic [7:0] hex_ascii(input logic [3:0] value);
        return (value < 4'd10) ? (8'h30 + 8'(value)) : (8'h37 + 8'(value));
    endfunction

    // F0..F3、B0..B3、S0..S5，最后 XE。S 行字段含义：
    // S0 = {ALLOC, ISSUE, COMPLETE}，S1 = {RETIRE, REDIRECT, FETCH}，
    // S2 = {MAX_ROB, {HEAD_STATE, PIPE_STATE}, FIRST_RSP}，E 为首应答错误位；
    // S3 = {FETCH_FIRE, RSP_FIRE, FRONT_REDIRECT}，
    // S4 = {PUSH, POP, MAX_QUEUE_OCC}，S5 = {QUEUE_OCC, IQ_OCC, DECODE_VALID_CYCLES}。
    always_comb begin
        line_pc = '0;
        line_next = '0;
        line_inst = '0;
        line_exc = 1'b0;
        line_tag0 = 8'h30;
        line_tag1 = 8'h30;
        slot_idx = line_q - 4'(SLOTS);
        if (line_q < 4'(SLOTS)) begin
            line_pc = fetch_addr_q[line_q[SLOT_W-1:0]];
            line_tag0 = 8'h46;
            line_tag1 = 8'h30 + 8'(line_q);
        end else if (line_q < 4'(2 * SLOTS)) begin
            line_pc = slot_pc_q[slot_idx[SLOT_W-1:0]];
            line_next = slot_next_q[slot_idx[SLOT_W-1:0]];
            line_inst = slot_inst_q[slot_idx[SLOT_W-1:0]];
            line_exc = slot_exc_q[slot_idx[SLOT_W-1:0]];
            line_tag0 = 8'h42;
            line_tag1 = 8'h30 + 8'(slot_idx);
        end else if (line_q == LINE_S0) begin
            line_pc = snap_alloc_q;
            line_next = snap_issue_q;
            line_inst = snap_compl_q;
            line_tag0 = 8'h53;
            line_tag1 = 8'h30;
        end else if (line_q == LINE_S1) begin
            line_pc = snap_retire_q;
            line_next = snap_redirect_q;
            line_inst = snap_fetch_q;
            line_tag0 = 8'h53;
            line_tag1 = 8'h31;
        end else if (line_q == LINE_S2) begin
            line_pc = {27'b0, snap_max_rob_q};
            line_next = {24'b0, snap_head_q, snap_pipe_q};
            line_inst = snap_first_rsp_q;
            line_exc = snap_first_rsp_error_q;
            line_tag0 = 8'h53;
            line_tag1 = 8'h32;
        end else if (line_q == LINE_S3) begin
            line_pc = snap_fetch_fire_q;
            line_next = snap_rsp_fire_q;
            line_inst = snap_front_redirect_q;
            line_tag0 = 8'h53;
            line_tag1 = 8'h33;
        end else if (line_q == LINE_S4) begin
            line_pc = snap_push_q;
            line_next = snap_pop_q;
            line_inst = {24'b0, snap_max_queue_q};
            line_tag0 = 8'h53;
            line_tag1 = 8'h34;
        end else if (line_q == LINE_S5) begin
            line_pc = {24'b0, snap_queue_q};
            line_next = {24'b0, snap_iq_q};
            line_inst = snap_decode_valid_q;
            line_tag0 = 8'h53;
            line_tag1 = 8'h35;
        end else begin
            line_pc = exc_pc_q;
            line_next = exc_next_q;
            line_inst = exc_inst_q;
            line_exc = 1'b1;
            line_tag0 = 8'h58;
            line_tag1 = 8'h45;
        end
    end

    always_comb begin
        unique case (char_q)
            6'd0: frame_byte = line_tag0;
            6'd1: frame_byte = line_tag1;
            6'd2: frame_byte = 8'h20;
            6'd3: frame_byte = 8'h50;
            6'd4: frame_byte = 8'h43;
            6'd5: frame_byte = 8'h3d;
            6'd6:  frame_byte = hex_ascii(line_pc[28 +: 4]);
            6'd7:  frame_byte = hex_ascii(line_pc[24 +: 4]);
            6'd8:  frame_byte = hex_ascii(line_pc[20 +: 4]);
            6'd9:  frame_byte = hex_ascii(line_pc[16 +: 4]);
            6'd10: frame_byte = hex_ascii(line_pc[12 +: 4]);
            6'd11: frame_byte = hex_ascii(line_pc[8 +: 4]);
            6'd12: frame_byte = hex_ascii(line_pc[4 +: 4]);
            6'd13: frame_byte = hex_ascii(line_pc[0 +: 4]);
            6'd14: frame_byte = 8'h20;
            6'd15: frame_byte = 8'h4e;
            6'd16: frame_byte = 8'h58;
            6'd17: frame_byte = 8'h3d;
            6'd18: frame_byte = hex_ascii(line_next[28 +: 4]);
            6'd19: frame_byte = hex_ascii(line_next[24 +: 4]);
            6'd20: frame_byte = hex_ascii(line_next[20 +: 4]);
            6'd21: frame_byte = hex_ascii(line_next[16 +: 4]);
            6'd22: frame_byte = hex_ascii(line_next[12 +: 4]);
            6'd23: frame_byte = hex_ascii(line_next[8 +: 4]);
            6'd24: frame_byte = hex_ascii(line_next[4 +: 4]);
            6'd25: frame_byte = hex_ascii(line_next[0 +: 4]);
            6'd26: frame_byte = 8'h20;
            6'd27: frame_byte = 8'h49;
            6'd28: frame_byte = 8'h4e;
            6'd29: frame_byte = 8'h53;
            6'd30: frame_byte = 8'h54;
            6'd31: frame_byte = 8'h3d;
            6'd32: frame_byte = hex_ascii(line_inst[28 +: 4]);
            6'd33: frame_byte = hex_ascii(line_inst[24 +: 4]);
            6'd34: frame_byte = hex_ascii(line_inst[20 +: 4]);
            6'd35: frame_byte = hex_ascii(line_inst[16 +: 4]);
            6'd36: frame_byte = hex_ascii(line_inst[12 +: 4]);
            6'd37: frame_byte = hex_ascii(line_inst[8 +: 4]);
            6'd38: frame_byte = hex_ascii(line_inst[4 +: 4]);
            6'd39: frame_byte = hex_ascii(line_inst[0 +: 4]);
            6'd40: frame_byte = 8'h20;
            6'd41: frame_byte = 8'h45;
            6'd42: frame_byte = 8'h3d;
            6'd43: frame_byte = hex_ascii({3'b000, line_exc});
            6'd44: frame_byte = CHAR_CR;
            default: frame_byte = CHAR_LF;
        endcase
    end

    typedef enum logic [1:0] {TX_IDLE, TX_START, TX_DATA, TX_STOP} tx_state_e;
    tx_state_e tx_state_q;
    logic [DIV_W-1:0] div_q;
    logic [2:0] bit_q;
    logic [7:0] shifter_q;
    logic tx_bit_q;
    logic tx_ready, tx_start;

    assign tx_ready = tx_state_q == TX_IDLE;
    // takeover_q 为低时 gap_q 尚未装载预间隔，此时禁止起发，避免首帧丢失第一个间隔。
    assign tx_start = takeover && takeover_q && gap_q == '0 && tx_ready;
    assign tx = tx_bit_q;

    always_ff @(posedge clk_core or posedge event_reset) begin
        if (event_reset) begin
            tx_state_q <= TX_IDLE;
            div_q <= '0;
            bit_q <= '0;
            shifter_q <= 8'hff;
            tx_bit_q <= 1'b1;
        end else begin
            unique case (tx_state_q)
                TX_IDLE: begin
                    tx_bit_q <= 1'b1;
                    if (tx_start) begin
                        shifter_q <= frame_byte;
                        div_q <= '0;
                        tx_state_q <= TX_START;
                    end
                end
                TX_START: begin
                    tx_bit_q <= 1'b0;
                    if (div_q >= DIV_W'(BAUD_DIV - 1)) begin
                        div_q <= '0;
                        bit_q <= '0;
                        tx_state_q <= TX_DATA;
                    end else div_q <= div_q + 1'b1;
                end
                TX_DATA: begin
                    tx_bit_q <= shifter_q[bit_q];
                    if (div_q >= DIV_W'(BAUD_DIV - 1)) begin
                        div_q <= '0;
                        if (bit_q == 3'd7) tx_state_q <= TX_STOP;
                        else bit_q <= bit_q + 1'b1;
                    end else div_q <= div_q + 1'b1;
                end
                TX_STOP: begin
                    tx_bit_q <= 1'b1;
                    if (div_q >= DIV_W'(BAUD_DIV - 1)) begin
                        div_q <= '0;
                        tx_state_q <= TX_IDLE;
                    end else div_q <= div_q + 1'b1;
                end
            endcase
        end
    end

    // 每帧发送完一轮后在空闲间隔处重新开始，主机可在任意时刻连接并收到完整帧。
    always_ff @(posedge clk_core or posedge event_reset) begin
        if (event_reset) begin
            line_q <= '0;
            char_q <= '0;
            gap_q <= '0;
            takeover_q <= 1'b0;
        end else begin
            takeover_q <= takeover;
            if (!takeover) begin
                line_q <= '0;
                char_q <= '0;
                gap_q <= '0;
            end else if (!takeover_q) begin
                gap_q <= 1;
            end else if (tx_start) begin
                if (char_q == CHAR_LAST) begin
                    char_q <= '0;
                    if (line_q == LINE_LAST) begin
                        line_q <= '0;
                        gap_q <= 1;
                    end else line_q <= line_q + 1'b1;
                end else char_q <= char_q + 1'b1;
            end else if (gap_q != '0) begin
                if (gap_q == GAP_W'(GAP_CYCLES)) gap_q <= '0;
                else gap_q <= gap_q + 1'b1;
            end
        end
    end
endmodule
