// Module: fetch_queue
// Description: Stores ordered fixed-width instruction packets with prefix 0/1/2 enqueue and dequeue.
module fetch_queue #(
    parameter int unsigned DEPTH = 8
) (
    input logic clk, rst, flush,
    input pipeline_pkg::if_d1_t push_packet, push_packet_1,
    input logic [1:0] push_count,
    output logic push_ready,
    output pipeline_pkg::if_d1_t out_packet, out_packet_1,
    input logic [1:0] pop_count,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    import pipeline_pkg::*;
    localparam int unsigned PTR_W = $clog2(DEPTH);
    localparam int unsigned COUNT_W = $clog2(DEPTH+1);
    if_d1_t entries_q [DEPTH];
    logic [PTR_W-1:0] head_q, tail_q;
    logic [COUNT_W-1:0] count_q;
    logic [1:0] accepted;
    logic [PTR_W-1:0] second_head, second_tail;

    // 一份FIFO保存每条PC、异常和预测快照；第二条未消费时仍是下一拍的最老条目。
    assign second_head = head_q + PTR_W'(1);
    assign second_tail = tail_q + PTR_W'(1);
    assign occupancy = count_q;
    assign push_ready = !rst && !flush &&
                        (count_q + COUNT_W'(2) <= COUNT_W'(DEPTH) + COUNT_W'(pop_count));
    assign accepted = push_ready ? push_count : 2'd0;
    always_comb begin
        out_packet = entries_q[head_q];
        out_packet_1 = entries_q[second_head];
        out_packet.valid = !rst && !flush && count_q != 0;
        out_packet_1.valid = !rst && !flush && count_q >= 2;
    end

    // 满队列双弹双入允许同沿换槽；只更新元数据有效数量，不复位宽数据阵列。
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
        end else begin
            head_q <= head_q + PTR_W'(pop_count);
            tail_q <= tail_q + PTR_W'(accepted);
            count_q <= count_q + COUNT_W'(accepted) - COUNT_W'(pop_count);
            if (accepted != 0) entries_q[tail_q] <= push_packet;
            if (accepted == 2) entries_q[second_tail] <= push_packet_1;
        end
    end

`ifndef SYNTHESIS
    initial assert (DEPTH >= 2 && (DEPTH & (DEPTH-1)) == 0)
        else $fatal(1, "fetch_queue requires power-of-two depth >= 2");
    always_ff @(posedge clk) if (!rst && !flush) begin
        assert (push_count <= 2 && pop_count <= 2 && pop_count <= count_q)
            else $fatal(1, "fetch_queue invalid prefix transfer");
    end
`endif
endmodule
