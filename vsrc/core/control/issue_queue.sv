// Module: issue_queue
// Description: Registers two selected ready instructions and retains their admission order under backpressure.
module issue_queue (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic [1:0] push_count,
    input pipeline_pkg::d2_ex_t push_packet [2],
    input pipeline_pkg::branch_result_t push_branch [2],
    // 对当前槽内分支置位；标记随包压缩/弹出移动。
    input logic [1:0] mark_reported,
    output logic [1:0] push_capacity,
    input logic [1:0] pop_count,
    output pipeline_pkg::d2_ex_t issue_packet [2],
    // 不经当拍 flush/recovery 门控的寄存包视图，只供分支判定读取。
    output pipeline_pkg::d2_ex_t raw_packet [2],
    output pipeline_pkg::branch_result_t issue_branch [2],
    output logic [1:0] present,
    output logic [1:0] occupancy,
    output logic busy
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    d2_ex_t packet_q [2], packet_d [2], marked_q [2];
    branch_result_t branch_q [2], branch_d [2];
    logic [1:0] count_q, count_d;
    logic [1:0] killed;

    for (genvar slot = 0; slot < 2; slot++) begin : g_cancel
        assign killed[slot] = recovery.valid && younger_than(packet_q[slot].retire_id, recovery.id, head_slot);
    end
    assign occupancy = count_q;
    assign busy = count_q != 0;
    for (genvar slot = 0; slot < 2; slot++) assign raw_packet[slot] = packet_q[slot];
    // 包存在性与 flush/recovery 无关；分支判定读取寄存包，不受当拍取消门控。
    for (genvar slot = 0; slot < 2; slot++)
        assign present[slot] = !rst && slot < int'(count_q);
    // 输出从寄存包取得；允许双出双入和仅消费第一条，保持每拍最多两条的稳态吞吐。
    always_comb begin
        push_capacity = 0;
        if (!rst && !flush && !recovery.valid)
            push_capacity = 2'd2 - count_q + pop_count;
        for (int slot = 0; slot < 2; slot++) begin
            issue_packet[slot] = packet_q[slot];
            issue_branch[slot] = branch_q[slot];
            issue_packet[slot].valid = slot < int'(count_q) && !rst && !flush && !recovery.valid;
        end
        for (int slot = 0; slot < 2; slot++) begin
            marked_q[slot] = packet_q[slot];
            if (mark_reported[slot]) marked_q[slot].branch_reported = 1'b1;
        end
        packet_d = marked_q;
        branch_d = branch_q;
        count_d = 0;
        for (int slot = 0; slot < 2; slot++) begin
            if (slot < int'(count_q) && slot >= int'(pop_count) && !killed[slot]) begin
                packet_d[count_d[0]] = marked_q[slot];
                branch_d[count_d[0]] = branch_q[slot];
                count_d = count_d + 1'b1;
            end
        end
        for (int lane = 0; lane < 2; lane++) begin
            if (lane < int'(push_count)) begin
                packet_d[count_d[0]] = push_packet[lane];
                branch_d[count_d[0]] = push_branch[lane];
                count_d = count_d + 1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (rst || flush) count_q <= 0;
        else begin
            count_q <= count_d;
            packet_q <= packet_d;
            branch_q <= branch_d;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst) begin
        assert (count_q <= 2 && count_d <= 2 && push_count <= push_capacity && pop_count <= count_q)
            else $fatal(1, "ISS overflow/underflow");
        assert (!(flush || recovery.valid) || (push_count == 0 && pop_count == 0))
            else $fatal(1, "ISS transfer during recovery");
        for (int lane = 0; lane < 2; lane++) if (lane < int'(push_count)) begin
            assert (push_packet[lane].valid && !push_packet[lane].rs1_dependency.pending &&
                    !push_packet[lane].rs2_dependency.pending)
                else $fatal(1, "ISS admitted unready operands");
        end
    end
`endif
endmodule
