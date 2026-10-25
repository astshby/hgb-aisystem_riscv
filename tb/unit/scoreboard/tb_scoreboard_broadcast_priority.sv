// Module: tb_scoreboard_broadcast_priority
// Description: Compares parameterized-port dispatch, held-operand and issue-view capture against the original serial priority contract.
module tb_scoreboard_broadcast_priority #(
    parameter bit SPLIT = 0,
    parameter int unsigned BROADCAST_PORTS = 9
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1;
    branch_recovery_t recovery = '0;
    logic [RETIRE_IDX_W-1:0] head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-2);
    logic [1:0] push_count = 0, push_memory = 0, push_capacity, pop_count = 0, operands_ready;
    d2_ex_t push_packet [2], issue_packet [2], expected [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [BROADCAST_PORTS];
    logic [3:0] occupancy;
    int checks = 0, cases = 0;
    always #5 clk = !clk;

    if (SPLIT) begin : g_split
        split_scoreboard_queue #(.INTEGER_DEPTH(8), .MEMORY_DEPTH(4),
            .BROADCAST_PORTS(BROADCAST_PORTS), .LIMITED_OOO(0)) dut (.*);
    end else begin : g_flat
        scoreboard_queue #(.DEPTH(8), .BROADCAST_PORTS(BROADCAST_PORTS), .ISSUE_BYPASS(1)) dut (
            .clk, .rst, .flush, .recovery, .head_slot, .push_count, .push_packet,
            .push_capacity, .producers, .broadcast, .issue_packet, .operands_ready,
            .pop_count, .occupancy
        );
    end

    function automatic retire_id_t tag(input int age, generation = 1);
        return '{slot:RETIRE_IDX_W'(int'(head_slot)+age), generation:RETIRE_GEN_W'(generation)};
    endfunction

    // 保留优化前的覆盖顺序作参考：原始 pending 决定资格，ROB 优先于旧值，后广播口覆盖前口。
    function automatic d2_ex_t reference_capture(input d2_ex_t packet, input bit read_rob, issue_view);
        d2_ex_t value;
        retire_gpr_entry_t producer;
        value = packet;
        for (int source_no = 0; source_no < 2; source_no++) begin
            if (source_no == 0) begin
                producer = producers[packet.rs1_dependency.id.slot];
                if (read_rob && packet.rs1_dependency.pending && producer.valid && producer.ready &&
                    producer.id == packet.rs1_dependency.id) begin
                    value.rs1_data = producer.data;
                    value.rs1_dependency.pending = 0;
                end
            end else begin
                producer = producers[packet.rs2_dependency.id.slot];
                if (read_rob && packet.rs2_dependency.pending && producer.valid && producer.ready &&
                    producer.id == packet.rs2_dependency.id) begin
                    value.rs2_data = producer.data;
                    value.rs2_dependency.pending = 0;
                end
            end
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

    task automatic clear_broadcast;
        for (int portno = 0; portno < BROADCAST_PORTS; portno++) broadcast[portno] = '0;
    endtask
    task automatic check_packets(input bit issue_view, input int survivors = 2);
        d2_ex_t view;
        #1;
        assert (occupancy == 4'(survivors)) else $fatal(1, "broadcast test occupancy");
        for (int lane = 0; lane < survivors; lane++) begin
            view = issue_view ? reference_capture(expected[lane], 0, 1) : expected[lane];
            assert (issue_packet[lane] === view) else $fatal(1,
                "capture mismatch split=%0d case=%0d lane=%0d rs1=%h/%h rs2=%h/%h pending=%b%b/%b%b",
                SPLIT, cases, lane, issue_packet[lane].rs1_data, view.rs1_data,
                issue_packet[lane].rs2_data, view.rs2_data,
                issue_packet[lane].rs1_dependency.pending, issue_packet[lane].rs2_dependency.pending,
                view.rs1_dependency.pending, view.rs2_dependency.pending);
            assert (operands_ready[lane] == (!view.rs1_dependency.pending && !view.rs2_dependency.pending))
                else $fatal(1, "operand ready mismatch");
            checks++;
        end
        if (survivors == 1) assert (!issue_packet[1].valid) else $fatal(1, "recovered packet remained valid");
    endtask

    initial begin
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        for (int lane = 0; lane < 2; lane++) push_packet[lane] = '0;
        clear_broadcast();
        repeat (2) @(negedge clk);
        rst = 0;
        for (int phase = 0; phase < 2; phase++) begin
            for (int kind = 0; kind < 3; kind++) begin
                for (int tag_pattern = 0; tag_pattern < 3; tag_pattern++) begin
                    for (int mask = 0; mask < (1 << BROADCAST_PORTS); mask++) begin
                        flush = 1;
                        @(negedge clk); flush = 0;
                        clear_broadcast();
                        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
                        for (int source_no = 0; source_no < 2; source_no++) begin
                            producers[tag(source_no).slot] = '{valid:1, ready:1'(mask >> source_no),
                                id:tag(source_no, (mask & 4) ? 2 : 1), data:xlen_t'(100+source_no),
                                kind:RET_EXEC, default:'0};
                        end
                        for (int lane = 0; lane < 2; lane++) begin
                            push_packet[lane] = '0;
                            push_packet[lane].valid = 1;
                            push_packet[lane].retire_id = tag(2+lane);
                            push_packet[lane].rs1_data = xlen_t'(300+lane);
                            push_packet[lane].rs2_data = xlen_t'(400+lane);
                            push_packet[lane].rs1_dependency = '{pending:!(mask & 8), id:tag(0)};
                            push_packet[lane].rs2_dependency = '{pending:!(mask & 16), id:tag(1)};
                            push_packet[lane].uop.mem_read = kind == 1;
                            push_packet[lane].uop.branch_op = kind == 2 ? BR_EQ : BR_NONE;
                            push_memory[lane] = kind == 1;
                        end
                        if (phase == 1) begin
                            for (int lane = 0; lane < 2; lane++) expected[lane] = reference_capture(push_packet[lane], 1, 0);
                            push_count = 2;
                            @(negedge clk); push_count = 0;
                            check_packets(0);
                        end
                        for (int portno = 0; portno < BROADCAST_PORTS; portno++) begin
                            broadcast[portno] = '{valid:1'(mask >> portno),
                                id:tag(tag_pattern == 2 ? portno%2 : tag_pattern,
                                       ((mask & 32) && portno%3 == 0) ? 2 : 1),
                                data:xlen_t'(64'hc031700000000000 + 64'(mask*32+portno+1))};
                        end
                        if (phase == 0) begin
                            for (int lane = 0; lane < 2; lane++) expected[lane] = reference_capture(push_packet[lane], 1, 0);
                            push_count = 2;
                        end else begin
                            check_packets(1);
                            for (int lane = 0; lane < 2; lane++) expected[lane] = reference_capture(expected[lane], 0, 0);
                        end
                        @(negedge clk); push_count = 0; clear_broadcast();
                        check_packets(0);
                        // 捕获后 ROB 复用、不同代次广播不得改写已得到的操作数。
                        for (int portno = 0; portno < BROADCAST_PORTS; portno++)
                            broadcast[portno] = '{valid:1, id:tag(portno%2, 3), data:'1};
                        recovery = '{valid:1, id:tag(2), pc:'0};
                        @(negedge clk); recovery = '0; clear_broadcast();
                        check_packets(0, 1);
                        cases++;
                    end
                end
            end
        end
        $display("PASS tb_scoreboard_broadcast_priority XLEN=%0d split=%0d ports=%0d cases=%0d checks=%0d priority rob_overlap generation dispatch hold issue recovery", XLEN, SPLIT, BROADCAST_PORTS, cases, checks);
        $finish;
    end
    initial begin #8ms; $fatal(1, "broadcast priority timeout"); end
endmodule
