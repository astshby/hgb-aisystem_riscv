// Module: fetch_pair_stage
// Description: Fetches aligned instruction pairs, preserves per-word context and drains killed responses.
module fetch_pair_stage (
    input logic clk, rst, fetch_request_enable, flush,
    input pipeline_pkg::redirect_t redirect,
    input pipeline_pkg::pred_info_t prediction, prediction_1,
    output core_types_pkg::xlen_t lookup_pc, lookup_pc_1,
    output logic fetch_fire, fetch_second,
    output pipeline_pkg::if_d1_t out_packet, out_packet_1,
    input logic [1:0] pop_count,
    output logic imem_req_valid,
    output core_types_pkg::xlen_t imem_req_addr,
    input logic imem_req_ready, imem_rsp_valid,
    input logic [63:0] imem_rsp_data,
    input logic imem_rsp_error, imem_rsp_error_1,
    output logic imem_rsp_ready,
    output logic busy
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    xlen_t pc_q, sequential_pc;
    if_d1_t request_q, request_1_q, response_packet, response_packet_1;
    logic killed_q, high_word_q, request_second, response_fire, kill_now, push_ready;
    logic [1:0] push_count;
    logic [$clog2(FETCH_QUEUE_DEPTH+1)-1:0] occupancy;

    // 请求地址按8字节对齐，实际指令PC独立保存；跳至高word时只消费该word。
    assign lookup_pc = pc_q;
    assign lookup_pc_1 = pc_q + xlen_t'(4);
    assign sequential_pc = (pc_q & ~xlen_t'(7)) + xlen_t'(8);
    assign request_second = !pc_q[2] && !prediction.taken;
    assign kill_now = redirect.valid || flush;
    assign imem_req_addr = pc_q & ~xlen_t'(7);
    assign imem_rsp_ready = request_q.valid && (killed_q || kill_now || push_ready);
    assign response_fire = imem_rsp_valid && imem_rsp_ready;
    assign imem_req_valid = !rst && fetch_request_enable && !kill_now &&
                            (!request_q.valid || response_fire);
    assign fetch_fire = imem_req_valid && imem_req_ready;
    assign fetch_second = request_second;
    assign busy = request_q.valid || occupancy != 0;

    // 每word保留自己的错误归属；低word故障不再提供其后指令，高word故障不污染低word。
    always_comb begin
        response_packet = request_q;
        response_packet_1 = request_1_q;
        response_packet.inst = high_word_q ? imem_rsp_data[63:32] : imem_rsp_data[31:0];
        response_packet.exc = '0;
        response_packet.exc.valid = high_word_q ? imem_rsp_error_1 : imem_rsp_error;
        if (response_packet.exc.valid) begin
            response_packet.exc.cause = riscv_priv_pkg::EXC_INST_ACCESS_FAULT;
            response_packet.exc.tval = request_q.pc;
        end
        response_packet_1.inst = imem_rsp_data[63:32];
        response_packet_1.exc = '0;
        response_packet_1.exc.valid = imem_rsp_error_1;
        if (response_packet_1.exc.valid) begin
            response_packet_1.exc.cause = riscv_priv_pkg::EXC_INST_ACCESS_FAULT;
            response_packet_1.exc.tval = request_1_q.pc;
        end
        push_count = 0;
        if (response_fire && !kill_now && !killed_q) begin
            push_count = request_1_q.valid && !response_packet.exc.valid ? 2'd2 : 2'd1;
        end
    end
    fetch_queue #(.DEPTH(FETCH_QUEUE_DEPTH)) u_queue (
        .clk, .rst, .flush(kill_now), .push_packet(response_packet),
        .push_packet_1(response_packet_1), .push_count, .push_ready,
        .out_packet, .out_packet_1, .pop_count, .occupancy
    );

    // 单请求owner仅在真实接受沿更换；废弃响应仍排空，不靠清valid撤销外部事务。
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_q <= RESET_VECTOR;
            request_q <= '0;
            request_1_q <= '0;
            killed_q <= 1'b0;
            high_word_q <= 1'b0;
        end else begin
            if (redirect.valid) pc_q <= redirect.pc;
            else if (fetch_fire)
                pc_q <= prediction.taken ? prediction.target :
                    (request_second && prediction_1.taken ? prediction_1.target : sequential_pc);
            if (kill_now) begin
                if (request_q.valid && !response_fire) killed_q <= 1'b1;
                else begin request_q.valid <= 1'b0; request_1_q.valid <= 1'b0; killed_q <= 1'b0; end
            end else begin
                if (response_fire) begin
                    request_q.valid <= 1'b0;
                    request_1_q.valid <= 1'b0;
                    killed_q <= 1'b0;
                end
                if (fetch_fire) begin
                    request_q <= '{valid:1'b1, pc:pc_q, seq_pc:pc_q+xlen_t'(4),
                                   inst:'0, pred:prediction, exc:'0};
                    request_1_q <= '{valid:request_second, pc:pc_q+xlen_t'(4), seq_pc:pc_q+xlen_t'(8),
                                     inst:'0, pred:prediction_1, exc:'0};
                    high_word_q <= pc_q[2];
                    killed_q <= 1'b0;
                end
            end
        end
    end
endmodule
