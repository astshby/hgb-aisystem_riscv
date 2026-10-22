// Module: integer_issue_queue
// Description: Tagged operand slots with parallel age ranks, ready selection and precise recovery.
module integer_issue_queue #(
    parameter int unsigned DEPTH = core_config_pkg::ISSUE_QUEUE_ENTRIES,
    parameter int unsigned BROADCAST_PORTS = 2,
    parameter bit CAPTURE_PUSH_OPERANDS = 1
) (
    input logic clk, rst, flush, mdu_available,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic memory_pending,
    input pipeline_pkg::retire_id_t memory_id,
    input logic [1:0] push_count,
    input pipeline_pkg::d2_ex_t push_packet [2],
    output logic [1:0] push_capacity,
    input pipeline_pkg::retire_gpr_entry_t producers [core_config_pkg::RETIRE_ENTRIES],
    input pipeline_pkg::retire_gpr_forward_t broadcast [BROADCAST_PORTS],
    output pipeline_pkg::d2_ex_t issue_packet [2],
    output logic [1:0] operands_ready,
    input logic [1:0] pop_count,
    output logic [$clog2(DEPTH+1)-1:0] occupancy,
    output logic serial_pending,
    output pipeline_pkg::retire_id_t serial_id,
    output logic [1:0] oldest_pending,
    output pipeline_pkg::retire_id_t oldest_id [2]
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    localparam int SLOT_W = $clog2(DEPTH);
    typedef enum logic [1:0] {RANK_ZERO, RANK_ONE, RANK_MANY} rank_e;
    d2_ex_t packet_q [DEPTH], operand_view [DEPTH], operand_d [DEPTH], captured [2];
    logic [DEPTH-1:0] valid_q, eligible, base_ready, serial_mask;
    logic [DEPTH-1:0] oldest_mask [2], selected_mask [2];
    logic [DEPTH-1:0] older [DEPTH], older_valid [DEPTH], older_ready [DEPTH];
    logic [DEPTH-1:0] older_serial [DEPTH], older_non_mdu [DEPTH];
    logic [RETIRE_IDX_W:0] age_key [DEPTH];
    rank_e valid_rank [DEPTH], ready_rank [DEPTH];
    schedule_class_e class_q [DEPTH];
    logic first_is_mdu, oldest_ready;
    logic [SLOT_W-1:0] free_slot [2];
    logic [1:0] free_count;
    integer used;

    // 选择只区分零个、一个和多个老项，树中每层做饱和合并，不串联宽包比较。
    function automatic rank_e rank_add(input rank_e a, b);
        if (a == RANK_ZERO) return b;
        else if (b == RANK_ZERO) return a;
        else return RANK_MANY;
    endfunction

    // 归并中间节点留在函数内，根输出只依赖输入掩码，避免整棵数组被工具视为自反馈。
    function automatic rank_e count_older(input logic [DEPTH-1:0] mask);
        rank_e nodes [2*DEPTH];
        nodes[0] = RANK_ZERO;
        for (int leaf = 0; leaf < DEPTH; leaf++) nodes[DEPTH+leaf] = mask[leaf] ? RANK_ONE : RANK_ZERO;
        for (int node = DEPTH-1; node > 0; node--)
            nodes[node] = rank_add(nodes[2*node], nodes[2*node+1]);
        return nodes[1];
    endfunction

    for (genvar slot = 0; slot < DEPTH; slot++) begin : g_age_rank
        assign age_key[slot] = {packet_q[slot].retire_id.slot < head_slot, packet_q[slot].retire_id.slot};
        assign class_q[slot] = schedule_class(packet_q[slot]);
        for (genvar other = 0; other < DEPTH; other++) begin : g_compare
            assign older[slot][other] = age_key[other] < age_key[slot];
            assign older_serial[slot][other] = older[slot][other] && valid_q[other] && class_q[other] == SCHED_SERIAL;
            assign older_non_mdu[slot][other] = older[slot][other] && eligible[other] && class_q[other] != SCHED_MDU;
            assign older_valid[slot][other] = older[slot][other] && valid_q[other];
            assign older_ready[slot][other] = older[slot][other] && eligible[other];
        end
        assign valid_rank[slot] = count_older(older_valid[slot]);
        assign ready_rank[slot] = count_older(older_ready[slot]);
        assign oldest_mask[0][slot] = valid_q[slot] && valid_rank[slot] == RANK_ZERO;
        assign oldest_mask[1][slot] = valid_q[slot] && valid_rank[slot] == RANK_ONE;
        assign serial_mask[slot] = valid_q[slot] && class_q[slot] == SCHED_SERIAL && !(|older_serial[slot]);
        assign selected_mask[0][slot] = eligible[slot] && ready_rank[slot] == RANK_ZERO;
        assign selected_mask[1][slot] = eligible[slot] && (first_is_mdu ?
            (class_q[slot] != SCHED_MDU && !(|older_non_mdu[slot])) : ready_rank[slot] == RANK_ONE);
    end
    assign oldest_ready = |(oldest_mask[0] & base_ready);

    // 标签含代次。已捕获的值不再查询复用后的 ROB 槽。
    function automatic d2_ex_t capture(input d2_ex_t packet, input logic probe_rob, input logic issue_view);
        d2_ex_t value;
        retire_gpr_entry_t p1, p2;
        value = packet;
        p1 = producers[packet.rs1_dependency.id.slot];
        p2 = producers[packet.rs2_dependency.id.slot];
        if (probe_rob && packet.rs1_dependency.pending && p1.valid && p1.ready &&
            p1.id == packet.rs1_dependency.id) begin
            value.rs1_data = p1.data;
            value.rs1_dependency.pending = 0;
        end
        if (probe_rob && packet.rs2_dependency.pending && p2.valid && p2.ready &&
            p2.id == packet.rs2_dependency.id) begin
            value.rs2_data = p2.data;
            value.rs2_dependency.pending = 0;
        end
        for (int portno = 0; portno < BROADCAST_PORTS; portno++) begin
            if (broadcast[portno].valid && operand_forward_enabled(packet, portno, issue_view)) begin
                if (packet.rs1_dependency.pending && broadcast[portno].id == packet.rs1_dependency.id) begin
                    value.rs1_data = broadcast[portno].data;
                    value.rs1_dependency.pending = 0;
                end
                if (packet.rs2_dependency.pending && broadcast[portno].id == packet.rs2_dependency.id) begin
                    value.rs2_data = broadcast[portno].data;
                    value.rs2_dependency.pending = 0;
                end
            end
        end
        return value;
    endfunction

    // 空槽分配只看寄存有效位，未将当拍消费反馈到译码容量。
    always_comb begin
        free_count = 0;
        free_slot[0] = 0;
        free_slot[1] = 0;
        used = 0;
        for (int slot = 0; slot < DEPTH; slot++) begin
            if (valid_q[slot]) used++;
            else if (free_count < 2) begin
                free_slot[free_count[0]] = SLOT_W'(slot);
                free_count++;
            end
        end
        occupancy = $clog2(DEPTH+1)'(used);
        push_capacity = rst || flush || recovery.valid ? 0 : free_count;
    end

    // 串行项进入 ISS 前保持屏障，防止年轻访存先占用 LSU 并阻塞队头 FENCE。
    always_comb begin
        serial_pending = 0;
        serial_id = '0;
        for (int slot = 0; slot < DEPTH; slot++) begin
            serial_pending |= serial_mask[slot];
            serial_id |= packet_q[slot].retire_id & {$bits(retire_id_t){serial_mask[slot]}};
        end
        oldest_pending = 0;
        for (int lane = 0; lane < 2; lane++) begin
            oldest_id[lane] = '0;
            for (int slot = 0; slot < DEPTH; slot++) begin
                oldest_pending[lane] |= oldest_mask[lane][slot];
                oldest_id[lane] |= packet_q[slot].retire_id & {$bits(retire_id_t){oldest_mask[lane][slot]}};
            end
        end
    end

    always_comb begin
        for (int slot = 0; slot < DEPTH; slot++) begin
            // 捕获视图与发射视图分开，寄存提示模式不把晚到的 LSU 资格送入当拍选择。
            operand_view[slot] = capture(packet_q[slot], 0, 1);
            operand_d[slot] = capture(packet_q[slot], 0, 0);
            base_ready[slot] = valid_q[slot] && !rst && !flush && !recovery.valid &&
                !operand_view[slot].rs1_dependency.pending && !operand_view[slot].rs2_dependency.pending &&
                (class_q[slot] != SCHED_MDU || mdu_available);
        end
    end

    always_comb begin
        for (int slot = 0; slot < DEPTH; slot++) begin
            eligible[slot] = base_ready[slot] &&
                (!serial_pending || !younger_than(packet_q[slot].retire_id, serial_id, head_slot)) &&
                (class_q[slot] != SCHED_SERIAL || packet_q[slot].retire_id.slot == head_slot) &&
                // 分支可能在 EX 才形成异常，不能先占 ISS 再等待仍在 IQ 的老项。
                (!(class_q[slot] inside {SCHED_BRANCH, SCHED_SERIAL}) ||
                 ((oldest_mask[0][slot] || (oldest_mask[1][slot] && oldest_ready)) &&
                  (!memory_pending || !younger_than(packet_q[slot].retire_id, memory_id, head_slot))));
        end
    end

    always_comb begin
        // 分离 IQ 的共同分配口已完成捕获；直接入槽不再叠加一层 ROB/广播选择。
        for (int lane = 0; lane < 2; lane++)
            captured[lane] = CAPTURE_PUSH_OPERANDS ? capture(push_packet[lane], 1, 0) : push_packet[lane];
    end

    // 只搬运被选中的操作数；每个物理槽独立有效，消费不压缩整个宽包数组。
    // 每个槽并行算年龄序位，再以独热向量选数据，避免最小值反馈经过八个宽包多路器。
    always_comb begin
        first_is_mdu = 0;
        for (int slot = 0; slot < DEPTH; slot++)
            first_is_mdu |= eligible[slot] && ready_rank[slot] == RANK_ZERO && class_q[slot] == SCHED_MDU;
    end
    always_comb begin
        operands_ready = 0;
        for (int lane = 0; lane < 2; lane++) begin
            issue_packet[lane] = '0;
            for (int slot = 0; slot < DEPTH; slot++)
                issue_packet[lane] |= operand_view[slot] & {$bits(d2_ex_t){selected_mask[lane][slot]}};
            issue_packet[lane].valid = |selected_mask[lane];
            operands_ready[lane] = issue_packet[lane].valid;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) valid_q <= '0;
        else begin
            for (int slot = 0; slot < DEPTH; slot++) begin
                packet_q[slot].rs1_data <= operand_d[slot].rs1_data;
                packet_q[slot].rs2_data <= operand_d[slot].rs2_data;
                packet_q[slot].rs1_dependency <= operand_d[slot].rs1_dependency;
                packet_q[slot].rs2_dependency <= operand_d[slot].rs2_dependency;
                if (recovery.valid && younger_than(packet_q[slot].retire_id, recovery.id, head_slot))
                    valid_q[slot] <= 0;
                if (!recovery.valid && ((pop_count != 0 && selected_mask[0][slot]) ||
                                       (pop_count == 2 && selected_mask[1][slot]))) valid_q[slot] <= 0;
            end
            if (!recovery.valid) begin
                for (int lane = 0; lane < 2; lane++) begin
                    if (lane < int'(push_count)) begin
                        valid_q[free_slot[lane]] <= 1;
                        packet_q[free_slot[lane]] <= captured[lane];
                    end
                end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (DEPTH >= 2 && (DEPTH & (DEPTH-1)) == 0) else $fatal(1, "integer IQ depth");
    always_ff @(posedge clk) if (!rst && !flush) begin
        assert (push_count <= push_capacity && pop_count <= 2 &&
                (pop_count == 0 || operands_ready[0]) && (pop_count != 2 || operands_ready[1]))
            else $fatal(1, "integer IQ transfer");
        assert (!recovery.valid || (push_count == 0 && pop_count == 0)) else $fatal(1, "integer IQ recovery transfer");
        assert ($onehot0(selected_mask[0]) && $onehot0(selected_mask[1]) &&
                !(|(selected_mask[0] & selected_mask[1]))) else $fatal(1, "integer IQ selection exclusivity");
    end
`endif
endmodule
