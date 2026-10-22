// Module: tb_scoreboard_integer_select
// Description: Sweeps ready masks and shuffled slot ages against an ordered scheduling reference.
module tb_scoreboard_integer_select;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1, memory_pending = 0;
    retire_id_t memory_id = '0, serial_id, oldest_id [2];
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic [1:0] push_count, push_capacity, pop_count, operands_ready, oldest_pending;
    logic serial_pending;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [2];
    logic [3:0] occupancy;
    int order [8], expected [2], cases = 0;
    logic [31:0] random_state = 32'h3947a251;
    integer_issue_queue #(.DEPTH(8), .BROADCAST_PORTS(2)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int age, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(int'(head_slot)+age), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic int unsigned random_word;
        random_state ^= random_state << 13; random_state ^= random_state >> 17; random_state ^= random_state << 5;
        return random_state;
    endfunction
    task automatic idle;
        push_count = 0; pop_count = 0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) begin push_packet[lane] = '0; broadcast[lane] = '0; end
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    initial begin
        idle(); for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        tick(); rst = 0;
        for (int phase = 0; phase < 3; phase++) begin
            for (int shuffle = 0; shuffle < 8; shuffle++) begin
                for (int age = 0; age < 8; age++) order[age] = age;
                for (int last = 7; last > 0; last--) begin
                    int other, temporary;
                    other = int'(random_word() % (32'(last)+1));
                    temporary = order[last]; order[last] = order[other]; order[other] = temporary;
                end
                for (int mask = 0; mask < 256; mask++) begin
                    head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-4+shuffle);
                    for (int first = 0; first < 8; first += 2) begin
                        for (int lane = 0; lane < 2; lane++) begin
                            int age;
                            age = order[first+lane];
                            push_packet[lane] = '0; push_packet[lane].valid = 1;
                            push_packet[lane].retire_id = tag(age);
                            push_packet[lane].rs1_data = xlen_t'(age*11);
                            push_packet[lane].rs1_dependency = '{pending:!1'(mask >> age), id:tag(RETIRE_ENTRIES-1, 3)};
                            if (phase == 1 && age % 3 == 0) push_packet[lane].uop.fu = FU_MULDIV;
                            if (phase == 2 && age % 3 == 1) push_packet[lane].uop.branch_op = BR_EQ;
                        end
                        push_count = 2; tick();
                    end
                    expected[0] = -1; expected[1] = -1;
                    // 参考按程序年龄扫描，MDU 资源和未发射老项的边界独立判断。
                    for (int age = 0; age < 8; age++) begin
                        if (1'(mask >> age) &&
                            !(phase == 2 && age % 3 == 1 && !(age == 1 && 1'(mask)))) begin
                            if (expected[0] < 0) expected[0] = age;
                            else if (expected[1] < 0 &&
                                     !(phase == 1 && expected[0] % 3 == 0 && age % 3 == 0)) expected[1] = age;
                        end
                    end
                    #1;
                    assert (occupancy == 8 && oldest_pending == 3 && oldest_id[0] == tag(0) &&
                            oldest_id[1] == tag(1) && !serial_pending) else $fatal(1, "static age rank");
                    for (int lane = 0; lane < 2; lane++) begin
                        assert (operands_ready[lane] == (expected[lane] >= 0)) else $fatal(1, "ready mask phase=%0d mask=%h lane=%0d", phase, mask, lane);
                        if (expected[lane] >= 0)
                            assert (issue_packet[lane].retire_id == tag(expected[lane]) &&
                                    issue_packet[lane].rs1_data == xlen_t'(expected[lane]*11))
                                else $fatal(1, "age/data phase=%0d mask=%h lane=%0d expected=%0d", phase, mask, lane, expected[lane]);
                    end
                    pop_count = expected[1] >= 0 ? 2 : (expected[0] >= 0 ? 1 : 0); tick();
                    #1; assert (occupancy == 8 - int'(expected[0] >= 0) - int'(expected[1] >= 0)) else $fatal(1, "onehot pop");
                    flush = 1; tick(); flush = 0; cases++;
                end
            end
        end
        assert (cases == 6144) else $fatal;
        $display("PASS tb_scoreboard_integer_select XLEN=%0d cases=%0d ready_masks slot_ages wrap MDU branch onehot_pop", XLEN, cases);
        $finish;
    end
endmodule
