// Module: integer_issue_queue
// Description: Tagged operand slots with oldest-ready selection and precise recovery.
module integer_issue_queue #(
    parameter int unsigned DEPTH = core_config_pkg::ISSUE_QUEUE_ENTRIES,
    parameter int unsigned BROADCAST_PORTS = 2
) (
    input logic clk, rst, flush, mdu_available,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
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
    output pipeline_pkg::retire_id_t serial_id
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    localparam int SLOT_W = $clog2(DEPTH);
    d2_ex_t packet_q [DEPTH], operand_view [DEPTH], captured [2];
    logic [DEPTH-1:0] valid_q, eligible;
    logic [SLOT_W-1:0] selected [2], free_slot [2];
    logic [1:0] free_count;
    integer used;

    // 标签含代次。已捕获的值不再查询复用后的 ROB 槽。
    function automatic d2_ex_t capture(input d2_ex_t packet, input logic probe_rob);
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
            if (broadcast[portno].valid) begin
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
            if (valid_q[slot] && schedule_class(packet_q[slot]) == SCHED_SERIAL &&
                (!serial_pending || younger_than(serial_id, packet_q[slot].retire_id, head_slot))) begin
                serial_pending = 1;
                serial_id = packet_q[slot].retire_id;
            end
        end
    end

    always_comb begin
        for (int slot = 0; slot < DEPTH; slot++) begin
            operand_view[slot] = capture(packet_q[slot], 0);
            eligible[slot] = valid_q[slot] && !rst && !flush && !recovery.valid &&
                !operand_view[slot].rs1_dependency.pending && !operand_view[slot].rs2_dependency.pending &&
                (!serial_pending || !younger_than(packet_q[slot].retire_id, serial_id, head_slot)) &&
                (schedule_class(packet_q[slot]) != SCHED_SERIAL || packet_q[slot].retire_id.slot == head_slot) &&
                (schedule_class(packet_q[slot]) != SCHED_MDU || mdu_available);
        end
    end

    always_comb begin
        for (int lane = 0; lane < 2; lane++) captured[lane] = capture(push_packet[lane], 1);
    end

    // 只搬运被选中的操作数；每个物理槽独立有效，消费不压缩整个宽包数组。
    always_comb begin
        operands_ready = 0;
        for (int lane = 0; lane < 2; lane++) begin
            selected[lane] = 0;
            issue_packet[lane] = '0;
            for (int slot = 0; slot < DEPTH; slot++) begin
                if (eligible[slot] && (lane == 0 || (SLOT_W'(slot) != selected[0] &&
                    !(schedule_class(issue_packet[0]) == SCHED_MDU && schedule_class(packet_q[slot]) == SCHED_MDU))) &&
                    (!issue_packet[lane].valid || younger_than(issue_packet[lane].retire_id,
                                                             packet_q[slot].retire_id, head_slot))) begin
                    selected[lane] = SLOT_W'(slot);
                    issue_packet[lane] = operand_view[slot];
                    issue_packet[lane].valid = 1;
                end
            end
            operands_ready[lane] = issue_packet[lane].valid;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) valid_q <= '0;
        else begin
            for (int slot = 0; slot < DEPTH; slot++) begin
                packet_q[slot].rs1_data <= operand_view[slot].rs1_data;
                packet_q[slot].rs2_data <= operand_view[slot].rs2_data;
                packet_q[slot].rs1_dependency <= operand_view[slot].rs1_dependency;
                packet_q[slot].rs2_dependency <= operand_view[slot].rs2_dependency;
                if (recovery.valid && younger_than(packet_q[slot].retire_id, recovery.id, head_slot))
                    valid_q[slot] <= 0;
            end
            if (!recovery.valid) begin
                for (int lane = 0; lane < 2; lane++) begin
                    if (lane < int'(pop_count)) valid_q[selected[lane]] <= 0;
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
    end
`endif
endmodule
