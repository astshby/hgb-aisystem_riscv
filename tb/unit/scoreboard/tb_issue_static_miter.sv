// Module: tb_issue_static_miter
// Description: Checks every two-slot routing case and random cycles against the frozen issue queue.
module tb_issue_static_miter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    always #5 clk = ~clk;
    branch_recovery_t recovery = '0;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic [1:0] push_count = 0, pop_count = 0, mark_reported = 0;
    d2_ex_t push_packet [2];
    branch_result_t push_branch [2];
    d2_ex_t reference_issue [2], default_issue [2], static_issue [2];
    d2_ex_t reference_raw [2], default_raw [2], static_raw [2];
    branch_result_t reference_branch [2], default_branch [2], static_branch [2];
    logic [1:0] reference_capacity, default_capacity, static_capacity;
    logic [1:0] reference_present, default_present, static_present;
    logic [1:0] reference_occupancy, default_occupancy, static_occupancy;
    logic reference_busy, default_busy, static_busy;
    logic [31:0] random_state = 32'h72fca163;
    int cycles = 0, transitions = 0, cancelled = 0, resets = 0, flushes = 0;
    int routing [3][3][3];
    int kill_masks [4];
    issue_queue_reference reference_dut (.clk, .rst, .flush, .recovery, .head_slot,
        .push_count, .push_packet, .push_branch, .mark_reported, .pop_count,
        .push_capacity(reference_capacity), .issue_packet(reference_issue), .raw_packet(reference_raw),
        .issue_branch(reference_branch), .present(reference_present), .occupancy(reference_occupancy),
        .busy(reference_busy));
    issue_queue default_dut (.clk, .rst, .flush, .recovery, .head_slot,
        .push_count, .push_packet, .push_branch, .mark_reported, .pop_count,
        .push_capacity(default_capacity), .issue_packet(default_issue), .raw_packet(default_raw),
        .issue_branch(default_branch), .present(default_present), .occupancy(default_occupancy),
        .busy(default_busy));
    issue_queue #(.STATIC_SELECT(1'b1)) static_dut (.clk, .rst, .flush, .recovery, .head_slot,
        .push_count, .push_packet, .push_branch, .mark_reported, .pop_count,
        .push_capacity(static_capacity), .issue_packet(static_issue), .raw_packet(static_raw),
        .issue_branch(static_branch), .present(static_present), .occupancy(static_occupancy),
        .busy(static_busy));

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction
    function automatic d2_ex_t packet(input int slot);
        d2_ex_t value;
        value = '0;
        for (int chunk = 0; chunk < ($bits(d2_ex_t)+31)/32; chunk++)
            value = d2_ex_t'({value, random_word()});
        value.valid = 1;
        value.retire_id = '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(0)};
        value.rs1_dependency.pending = 0;
        value.rs2_dependency.pending = 0;
        return value;
    endfunction
    task automatic offer(input int count, input int mask);
        push_count = 2'(count);
        for (int lane = 0; lane < 2; lane++) begin
            push_packet[lane] = packet((mask & (1 << lane)) != 0 ? 6 : 2);
            push_branch[lane] = '{taken:1'(random_word()), target:xlen_t'({random_word(), random_word()})};
        end
    endtask
    task automatic compare(input logic check_next);
        assert ({reference_capacity, reference_present, reference_occupancy, reference_busy} ===
                {static_capacity, static_present, static_occupancy, static_busy} &&
                {reference_capacity, reference_present, reference_occupancy, reference_busy} ===
                {default_capacity, default_present, default_occupancy, default_busy})
            else $fatal(1, "ISS control mismatch cycle=%0d", cycles);
        // 无效槽与复位/flush期间也逐位对照，不能只比较 valid 后的可见载荷。
        for (int lane = 0; lane < 2; lane++) begin
            assert (reference_issue[lane] === static_issue[lane] && reference_raw[lane] === static_raw[lane] &&
                    reference_branch[lane] === static_branch[lane] &&
                    reference_issue[lane] === default_issue[lane] && reference_raw[lane] === default_raw[lane] &&
                    reference_branch[lane] === default_branch[lane])
                else $fatal(1, "ISS payload mismatch cycle=%0d lane=%0d", cycles, lane);
            if (check_next)
                assert (reference_dut.packet_d[lane] === static_dut.packet_d[lane] &&
                        reference_dut.branch_d[lane] === static_dut.branch_d[lane])
                    else $fatal(1, "ISS next payload mismatch cycle=%0d lane=%0d", cycles, lane);
        end
        if (check_next)
            assert (reference_dut.count_d === static_dut.count_d) else $fatal(1, "ISS next count mismatch");
    endtask
    task automatic tick;
        #1; compare(1'b1);
        if (rst) resets++;
        else if (flush) flushes++;
        else if (recovery.valid) begin
            kill_masks[reference_dut.killed]++;
            cancelled += int'(reference_dut.killed[0] && reference_occupancy != 0) +
                         int'(reference_dut.killed[1] && reference_occupancy == 2);
        end else routing[reference_occupancy][pop_count][push_count]++;
        // 沿后仍是上一拍控制；它们可能超出更新后容量，只核已登记状态和输出。
        @(posedge clk); #1; compare(1'b0);
        @(negedge clk); cycles++;
        push_count = 0; pop_count = 0; mark_reported = 0; recovery = '0; flush = 0;
    endtask
    initial begin
        offer(0, 0);
        @(negedge clk); tick(); rst = 0;
        // 每个合法占用/出队/入队组合均覆盖四种上报位；恢复覆盖四种保留掩码。
        for (int seed = 0; seed < 16; seed++) begin
            for (int count = 0; count <= 2; count++) begin
                for (int pops = 0; pops <= count; pops++) begin
                    for (int pushes = 0; pushes <= 2-count+pops; pushes++) begin
                        for (int marks = 0; marks < 4; marks++) begin
                            flush = 1; tick();
                            offer(count, seed & 3); tick();
                            pop_count = 2'(pops); offer(pushes, (seed+1) & 3);
                            mark_reported = 2'(marks); tick(); transitions++;
                        end
                    end
                end
                for (int mask = 0; mask < 4; mask++) begin
                    for (int marks = 0; marks < 4; marks++) begin
                        flush = 1; tick(); offer(count, mask); tick();
                        recovery = '{valid:1, id:'{slot:RETIRE_IDX_W'(4), generation:RETIRE_GEN_W'(0)}, pc:'0};
                        mark_reported = 2'(marks); tick(); transitions++;
                    end
                end
            end
        end
        // 长随机序列覆盖连续双进双出、部分pop、恢复重用、标记及中途复位。
        for (int sample = 0; sample < 20000; sample++) begin
            if (sample % 113 == 0) rst = 1;
            else if (sample % 71 == 0) flush = 1;
            else if (sample % 17 == 0)
                recovery = '{valid:1, id:'{slot:RETIRE_IDX_W'(4), generation:RETIRE_GEN_W'(0)}, pc:'0};
            else begin
                pop_count = 2'(random_word() % (int'(reference_occupancy)+1));
                offer(int'(random_word() % (3-int'(reference_occupancy)+int'(pop_count))), int'(random_word() & 3));
            end
            mark_reported = 2'(random_word());
            tick(); rst = 0;
        end
        assert (transitions == 1664 && cancelled > 100 && resets > 100 && flushes > 100)
            else $fatal(1, "ISS coverage incomplete");
        for (int mask = 0; mask < 4; mask++)
            assert (kill_masks[mask] > 0) else $fatal(1, "ISS recovery mask missing");
        $display("PASS tb_issue_static_miter RV%0d cycles=%0d exhaustive=%0d random=20000 cancelled=%0d resets=%0d flushes=%0d packet_bits=%0d",
                 XLEN, cycles, transitions, cancelled, resets, flushes, $bits(d2_ex_t));
        $finish;
    end
endmodule
