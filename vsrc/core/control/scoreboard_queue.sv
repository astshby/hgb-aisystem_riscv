// Module: scoreboard_queue
// Description: Captures tagged operands and supplies an in-order ready prefix to execution.
module scoreboard_queue #(
    parameter int unsigned DEPTH = core_config_pkg::ISSUE_QUEUE_ENTRIES,
    parameter int unsigned BROADCAST_PORTS = 2,
    parameter bit ISSUE_BYPASS = 0
) (
    input logic clk, rst, flush,
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
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    localparam int PTR_W = $clog2(DEPTH);
    localparam int COUNT_W = $clog2(DEPTH+1);
    d2_ex_t packet_q [DEPTH], packet_d [DEPTH];
    d2_ex_t captured [2];
    logic [PTR_W-1:0] read_q, write_q, second_read, second_write;
    logic [COUNT_W-1:0] count_q, survivors;
    integer available;

    // 按完整标签捕获数据，生产者退休或槽复用之后仍使用保存的值。
    function automatic d2_ex_t capture(input d2_ex_t packet, input logic probe_rob);
        d2_ex_t value;
        retire_gpr_entry_t rs1_producer, rs2_producer;
        value = packet;
        rs1_producer = producers[packet.rs1_dependency.id.slot];
        rs2_producer = producers[packet.rs2_dependency.id.slot];
        if (probe_rob && packet.rs1_dependency.pending && rs1_producer.valid &&
            rs1_producer.ready && rs1_producer.id == packet.rs1_dependency.id) begin
            value.rs1_data = rs1_producer.data;
            value.rs1_dependency.pending = 1'b0;
        end
        if (probe_rob && packet.rs2_dependency.pending && rs2_producer.valid &&
            rs2_producer.ready && rs2_producer.id == packet.rs2_dependency.id) begin
            value.rs2_data = rs2_producer.data;
            value.rs2_dependency.pending = 1'b0;
        end
        for (int portno = 0; portno < BROADCAST_PORTS; portno++) begin
            if (broadcast[portno].valid) begin
                if (packet.rs1_dependency.pending && broadcast[portno].id == packet.rs1_dependency.id) begin
                    value.rs1_data = broadcast[portno].data;
                    value.rs1_dependency.pending = 1'b0;
                end
                if (packet.rs2_dependency.pending && broadcast[portno].id == packet.rs2_dependency.id) begin
                    value.rs2_data = broadcast[portno].data;
                    value.rs2_dependency.pending = 1'b0;
                end
            end
        end
        return value;
    endfunction

    assign second_read = read_q + PTR_W'(1);
    assign second_write = write_q + PTR_W'(1);
    assign occupancy = count_q;
    // 容量只由已寄存占用确定，切断执行 ready 到双分配的组合链；队列吸收短暂反压。
    always_comb begin
        available = DEPTH - int'(count_q);
        push_capacity = 0;
        if (!rst && !flush && !recovery.valid)
            push_capacity = available >= 2 ? 2'd2 : 2'(available);
        // ISSUE_BYPASS 仅供后接寄存 ISS 的实例：当拍结果在进入 ISS 的沿捕获。
        issue_packet[0] = ISSUE_BYPASS ? capture(packet_q[read_q], 1'b0) : packet_q[read_q];
        issue_packet[1] = ISSUE_BYPASS ? capture(packet_q[second_read], 1'b0) : packet_q[second_read];
        issue_packet[0].valid = count_q != 0 && !rst && !flush && !recovery.valid;
        issue_packet[1].valid = count_q >= 2 && !rst && !flush && !recovery.valid;
        for (int lane = 0; lane < 2; lane++) begin
            operands_ready[lane] = issue_packet[lane].valid &&
                (!issue_packet[lane].rs1_dependency.pending && !issue_packet[lane].rs2_dependency.pending);
            captured[lane] = capture(push_packet[lane], 1'b1);
        end
        for (int slot = 0; slot < DEPTH; slot++)
            packet_d[slot] = capture(packet_q[slot], 1'b0);
        survivors = '0;
        for (int age = 0; age < DEPTH; age++) begin
            if (age < int'(count_q) &&
                !younger_than(packet_q[PTR_W'(read_q + PTR_W'(age))].retire_id, recovery.id, head_slot))
                survivors = survivors + COUNT_W'(1);
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            read_q <= '0;
            write_q <= '0;
            count_q <= '0;
        end else begin
            for (int slot = 0; slot < DEPTH; slot++) begin
                // 仅写操作数状态，保持静态包，综合不生成每拍重写整个宽队列的使能。
                packet_q[slot].rs1_data <= packet_d[slot].rs1_data;
                packet_q[slot].rs2_data <= packet_d[slot].rs2_data;
                packet_q[slot].rs1_dependency <= packet_d[slot].rs1_dependency;
                packet_q[slot].rs2_dependency <= packet_d[slot].rs2_dependency;
            end
            if (recovery.valid) begin
                count_q <= survivors;
                write_q <= read_q + PTR_W'(survivors);
            end else begin
                read_q <= read_q + PTR_W'(pop_count);
                write_q <= write_q + PTR_W'(push_count);
                count_q <= count_q + COUNT_W'(push_count) - COUNT_W'(pop_count);
                if (push_count != 0) packet_q[write_q] <= captured[0];
                if (push_count == 2) packet_q[second_write] <= captured[1];
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (DEPTH >= 2 && (DEPTH & (DEPTH - 1)) == 0)
        else $fatal(1, "scoreboard depth must be a power of two");
    always_ff @(posedge clk) if (!rst && !flush) begin
        assert (push_count <= push_capacity && int'(pop_count) <= int'(count_q) && pop_count <= 2)
            else $fatal(1, "scoreboard queue overflow/underflow");
        assert (pop_count == 0 || operands_ready[0]) else $fatal(1, "unready first issue");
        assert (pop_count != 2 || operands_ready[1]) else $fatal(1, "unready second issue");
        assert (!recovery.valid || (push_count == 0 && pop_count == 0))
            else $fatal(1, "scoreboard transfer during recovery");
    end
`endif
endmodule
