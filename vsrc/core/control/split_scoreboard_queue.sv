// Module: split_scoreboard_queue
// Description: Independent operand banks with ordered or limited oldest-ready integer issue.
module split_scoreboard_queue #(
    parameter int unsigned INTEGER_DEPTH = core_config_pkg::ISSUE_QUEUE_ENTRIES,
    parameter int unsigned MEMORY_DEPTH = core_config_pkg::MEMORY_QUEUE_ENTRIES,
    parameter int unsigned BROADCAST_PORTS = 2,
    parameter bit LIMITED_OOO = core_config_pkg::LIMITED_INTEGER_OOO
) (
    input logic clk, rst, flush, mdu_available,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic [1:0] push_count,
    input logic [1:0] push_memory,
    input pipeline_pkg::d2_ex_t push_packet [2],
    output logic [1:0] push_capacity,
    input pipeline_pkg::retire_gpr_entry_t producers [core_config_pkg::RETIRE_ENTRIES],
    input pipeline_pkg::retire_gpr_forward_t broadcast [BROADCAST_PORTS],
    output pipeline_pkg::d2_ex_t issue_packet [2],
    output logic [1:0] operands_ready,
    input logic [1:0] pop_count,
    output logic [$clog2(INTEGER_DEPTH+MEMORY_DEPTH+1)-1:0] occupancy
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    d2_ex_t bank_push [2][2], bank_issue [2][2], memory_issue [2], dispatch_captured [2];
    logic [1:0] bank_push_count [2], bank_capacity [2], bank_pop_count [2], bank_ready [2];
    logic [$clog2(INTEGER_DEPTH+1)-1:0] integer_occupancy;
    logic [$clog2(MEMORY_DEPTH+1)-1:0] memory_occupancy;
    logic selected_memory [2];
    integer demand [2], next_index [2];
    integer bank, index;
    logic serial_pending;
    logic [1:0] oldest_integer_pending;
    retire_id_t serial_id, oldest_integer_id [2];
    logic memory_eligible, first_consumes_oldest_integer;
    integer integer_boundary;
    assign bank_issue[1] = memory_issue;

    // ROB 数据读取与当拍广播先于类型分流，只实例化两条分配指令的四个源读口。
    // bank 只保存已捕获包；未就绪标签和各槽后续广播捕获仍由 bank 自己持有。
    function automatic d2_ex_t capture_dispatch(input d2_ex_t packet);
        d2_ex_t value;
        retire_gpr_entry_t p1, p2;
        value = packet;
        p1 = producers[packet.rs1_dependency.id.slot];
        p2 = producers[packet.rs2_dependency.id.slot];
        if (packet.rs1_dependency.pending && p1.valid && p1.ready && p1.id == packet.rs1_dependency.id) begin
            value.rs1_data = p1.data;
            value.rs1_dependency.pending = 0;
        end
        if (packet.rs2_dependency.pending && p2.valid && p2.ready && p2.id == packet.rs2_dependency.id) begin
            value.rs2_data = p2.data;
            value.rs2_dependency.pending = 0;
        end
        for (int portno = 0; portno < BROADCAST_PORTS; portno++) begin
            if (broadcast[portno].valid && operand_forward_enabled(packet, portno, 0)) begin
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
    always_comb begin
        for (int lane = 0; lane < 2; lane++) dispatch_captured[lane] = capture_dispatch(push_packet[lane]);
    end

    if (LIMITED_OOO) begin : g_ready_integer
        integer_issue_queue #(.DEPTH(INTEGER_DEPTH), .BROADCAST_PORTS(BROADCAST_PORTS), .CAPTURE_PUSH_OPERANDS(0)) u_integer (
            .clk, .rst, .flush, .recovery, .head_slot, .mdu_available,
            .memory_pending(memory_issue[0].valid), .memory_id(memory_issue[0].retire_id),
            .push_count(bank_push_count[0]), .push_packet(bank_push[0]), .push_capacity(bank_capacity[0]),
            .producers, .broadcast, .issue_packet(bank_issue[0]), .operands_ready(bank_ready[0]),
            .pop_count(bank_pop_count[0]), .occupancy(integer_occupancy), .serial_pending, .serial_id,
            .oldest_pending(oldest_integer_pending), .oldest_id(oldest_integer_id)
        );
    end else begin : g_ordered_integer
        assign serial_pending = 0;
        assign serial_id = '0;
        assign oldest_integer_pending = 0;
        assign oldest_integer_id[0] = '0;
        assign oldest_integer_id[1] = '0;
        scoreboard_queue #(.DEPTH(INTEGER_DEPTH), .BROADCAST_PORTS(BROADCAST_PORTS), .ISSUE_BYPASS(1), .CAPTURE_PUSH_OPERANDS(0)) u_integer (
            .clk, .rst, .flush, .recovery, .head_slot,
            .push_count(bank_push_count[0]), .push_packet(bank_push[0]), .push_capacity(bank_capacity[0]),
            .producers, .broadcast, .issue_packet(bank_issue[0]), .operands_ready(bank_ready[0]),
            .pop_count(bank_pop_count[0]), .occupancy(integer_occupancy)
        );
    end
    scoreboard_queue #(.DEPTH(MEMORY_DEPTH), .BROADCAST_PORTS(BROADCAST_PORTS), .ISSUE_BYPASS(1), .CAPTURE_PUSH_OPERANDS(0)) u_memory (
        .clk, .rst, .flush, .recovery, .head_slot,
        .push_count(bank_push_count[1]), .push_packet(bank_push[1]), .push_capacity(bank_capacity[1]),
        .producers, .broadcast, .issue_packet(memory_issue), .operands_ready(bank_ready[1]),
        .pop_count(bank_pop_count[1]), .occupancy(memory_occupancy)
    );

    assign occupancy = $clog2(INTEGER_DEPTH+MEMORY_DEPTH+1)'(integer_occupancy) +
                       $clog2(INTEGER_DEPTH+MEMORY_DEPTH+1)'(memory_occupancy);
    // 容量检查译码组的类型前缀，不依赖 alloc_fire，也不借用当拍 pop 容量。
    always_comb begin
        demand[0] = 0;
        demand[1] = 0;
        push_capacity = 0;
        for (int lane = 0; lane < 2; lane++) begin
            demand[push_memory[lane]]++;
            if (demand[0] <= int'(bank_capacity[0]) && demand[1] <= int'(bank_capacity[1]) &&
                (lane == 0 || push_capacity == 1))
                push_capacity = 2'(lane + 1);
        end
    end

    // 实际分配与容量判断分块，避免 alloc_fire 经组合块返回容量输出。
    always_comb begin
        for (int b = 0; b < 2; b++) begin
            bank_push_count[b] = 0;
            for (int lane = 0; lane < 2; lane++) bank_push[b][lane] = '0;
        end
        for (int lane = 0; lane < 2; lane++) begin
            if (lane < int'(push_count)) begin
                bank_push[push_memory[lane]][bank_push_count[push_memory[lane]]] = dispatch_captured[lane];
                bank_push_count[push_memory[lane]]++;
            end
        end
    end

    // ALU/MDU 可越过等待项；访存与分支保留全局接纳顺序，避免晚异常堵住老项。
    // 内存仍只消费 FIFO 的连续就绪前缀，不越过尚在整数 IQ 中的老项。
    always_comb begin
        next_index[0] = 0;
        next_index[1] = 0;
        operands_ready = 0;
        bank = 0;
        index = 0;
        first_consumes_oldest_integer = 0;
        integer_boundary = 0;
        memory_eligible = 0;
        for (int lane = 0; lane < 2; lane++) begin
            selected_memory[lane] = 0;
            issue_packet[lane] = '0;
            integer_boundary = first_consumes_oldest_integer ? 1 : 0;
            memory_eligible = memory_issue[next_index[1]].valid &&
                (!LIMITED_OOO || (bank_ready[1][next_index[1]] &&
                 (!oldest_integer_pending[integer_boundary] ||
                  !younger_than(memory_issue[next_index[1]].retire_id, oldest_integer_id[integer_boundary], head_slot)) &&
                 (!serial_pending || !younger_than(memory_issue[next_index[1]].retire_id, serial_id, head_slot))));
            if (bank_issue[0][next_index[0]].valid || memory_eligible) begin
                bank = !bank_issue[0][next_index[0]].valid ||
                    (memory_eligible && younger_than(
                        bank_issue[0][next_index[0]].retire_id,
                        bank_issue[1][next_index[1]].retire_id, head_slot)) ? 1 : 0;
                index = next_index[bank];
                selected_memory[lane] = 1'(bank);
                issue_packet[lane] = bank_issue[bank][index];
                operands_ready[lane] = bank_ready[bank][index];
                next_index[bank]++;
                if (lane == 0 && bank == 0 && oldest_integer_pending[0] &&
                    issue_packet[lane].retire_id == oldest_integer_id[0])
                    first_consumes_oldest_integer = 1;
            end
        end
    end

    // 消费反馈只更新各队列的沿后状态，不进入当拍候选与就绪选择。
    always_comb begin
        bank_pop_count[0] = 0;
        bank_pop_count[1] = 0;
        for (int lane = 0; lane < 2; lane++)
            if (lane < int'(pop_count)) bank_pop_count[selected_memory[lane]]++;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && !flush) begin
        assert (push_count <= push_capacity) else $fatal(1, "split IQ allocation overflow");
        for (int lane = 0; lane < 2; lane++)
            if (lane < int'(push_count))
                assert (push_memory[lane] == (schedule_class(push_packet[lane]) == SCHED_MEMORY))
                    else $fatal(1, "split IQ decode/renamed class mismatch");
        assert (pop_count <= 2 && (pop_count == 0 || operands_ready[0]) &&
                (pop_count != 2 || operands_ready[1])) else $fatal(1, "split IQ invalid consumption");
        assert (!issue_packet[1].valid || (issue_packet[0].valid &&
                younger_than(issue_packet[1].retire_id, issue_packet[0].retire_id, head_slot)))
            else $fatal(1, "split IQ issue age order");
    end
`endif
endmodule
