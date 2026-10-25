// Module: tb_scoreboard_issue_merge
// Description: Compares fixed-candidate split issue against the prior sequential merge for real bank traffic.
module tb_scoreboard_issue_merge #(
    parameter bit LIMITED_OOO = 1
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot = '0;
    logic [1:0] push_count, push_memory, push_capacity, pop_count, operands_ready;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [2];
    logic [$clog2(8+4+1)-1:0] occupancy;
    int checks = 0, scenarios = 0, same_cycle_wakes = 0;
    int selected_patterns [4];
    logic [31:0] random_state = 32'h79b31d42;
    split_scoreboard_queue #(.INTEGER_DEPTH(8), .MEMORY_DEPTH(4),
        .LIMITED_OOO(LIMITED_OOO)) dut (.*);
    always #5 clk = ~clk;

    function automatic logic [31:0] random_word();
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction
    function automatic retire_id_t tag(input int age, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(int'(head_slot)+age), generation:RETIRE_GEN_W'(generation)};
    endfunction
    task automatic idle();
        push_count = 0; pop_count = 0; push_memory = 0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) begin
            push_packet[lane] = '0;
            broadcast[lane] = '0;
        end
    endtask

    // 参考保留原来的顺序合并算法，只读两个 bank 候选与独立的最老标签。
    // 不读取候选 RTL 的选择掩码和 first_is_oldest，逐项比较完整宽包、ready 和消费路由。
    task automatic check_merge();
        int next_index [2];
        int bank, index, boundary;
        bit first_consumes_oldest, memory_eligible;
        d2_ex_t expected_packet [2];
        logic [1:0] expected_ready, expected_pop [2];
        bit selected_memory [2];
        next_index[0] = 0; next_index[1] = 0;
        expected_ready = 0; first_consumes_oldest = 0;
        for (int lane = 0; lane < 2; lane++) begin
            expected_packet[lane] = '0;
            selected_memory[lane] = 0;
            boundary = first_consumes_oldest ? 1 : 0;
            memory_eligible = dut.memory_issue[next_index[1]].valid &&
                (!LIMITED_OOO || (dut.bank_ready[1][next_index[1]] &&
                 (!dut.oldest_integer_pending[boundary] || !younger_than(
                    dut.memory_issue[next_index[1]].retire_id, dut.oldest_integer_id[boundary], head_slot)) &&
                 (!dut.serial_pending || !younger_than(
                    dut.memory_issue[next_index[1]].retire_id, dut.serial_id, head_slot))));
            if (dut.bank_issue[0][next_index[0]].valid || memory_eligible) begin
                bank = !dut.bank_issue[0][next_index[0]].valid ||
                    (memory_eligible && younger_than(dut.bank_issue[0][next_index[0]].retire_id,
                        dut.memory_issue[next_index[1]].retire_id, head_slot)) ? 1 : 0;
                index = next_index[bank];
                selected_memory[lane] = 1'(bank);
                expected_packet[lane] = dut.bank_issue[bank][index];
                expected_ready[lane] = dut.bank_ready[bank][index];
                next_index[bank]++;
                if (lane == 0 && bank == 0 && dut.oldest_integer_pending[0] &&
                    expected_packet[0].retire_id == dut.oldest_integer_id[0]) first_consumes_oldest = 1;
            end
        end
        expected_pop[0] = 0; expected_pop[1] = 0;
        for (int lane = 0; lane < 2; lane++) begin
            if (lane < int'(pop_count)) expected_pop[selected_memory[lane]]++;
            assert (issue_packet[lane] === expected_packet[lane])
                else $fatal(1, "merge packet scenario=%0d check=%0d lane=%0d", scenarios, checks, lane);
            assert (dut.selected_memory[lane] == selected_memory[lane])
                else $fatal(1, "merge bank scenario=%0d lane=%0d", scenarios, lane);
        end
        assert (operands_ready == expected_ready && dut.bank_pop_count[0] == expected_pop[0] &&
                dut.bank_pop_count[1] == expected_pop[1])
            else $fatal(1, "merge ready/pop scenario=%0d check=%0d", scenarios, checks);
        if (&operands_ready) selected_patterns[{selected_memory[1], selected_memory[0]}]++;
        checks++;
    endtask
    task automatic tick();
        #1; check_merge();
        @(posedge clk); #1; check_merge();
        @(negedge clk); idle();
    endtask

    initial begin
        logic [31:0] sample;
        bit memory_kind [6];
        int memories;
        idle(); foreach (selected_patterns[i]) selected_patterns[i] = 0;
        foreach (producers[i]) producers[i] = '0;
        @(negedge clk); tick(); rst = 0;
        for (int trial = 0; trial < 2048; trial++) begin
            flush = 1; tick(); flush = 0;
            head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-3+trial);
            memories = 0;
            for (int age = 0; age < 6; age++) begin
                sample = random_word();
                memory_kind[age] = sample[0] && memories < 4;
                if (memory_kind[age]) memories++;
            end
            for (int first = 0; first < 6; first += 2) begin
                for (int lane = 0; lane < 2; lane++) begin
                    int age;
                    age = first+lane; sample = random_word();
                    push_packet[lane] = '0;
                    push_packet[lane].valid = 1; push_packet[lane].retire_id = tag(age);
                    push_packet[lane].pc = xlen_t'(64'h8000 + 64'(age*4));
                    push_packet[lane].seq_pc = push_packet[lane].pc + xlen_t'(4);
                    push_packet[lane].imm = xlen_t'({sample, ~sample});
                    push_packet[lane].rs1_data = xlen_t'({sample, sample ^ 32'hf18c7302});
                    push_packet[lane].rs2_data = ~push_packet[lane].rs1_data;
                    push_packet[lane].rs1_dependency = '{pending:sample[3], id:tag(age+12, 3)};
                    push_packet[lane].rs2_dependency = '{pending:sample[4], id:tag(age+12, 3)};
                    push_memory[lane] = memory_kind[age];
                    if (memory_kind[age]) push_packet[lane].uop.mem_read = 1;
                    else begin
                        unique case (sample[2:1])
                            1: push_packet[lane].uop.fu = FU_MULDIV;
                            2: push_packet[lane].uop.branch_op = BR_EQ;
                            3: push_packet[lane].uop.csr_valid = 1;
                            default: ;
                        endcase
                    end
                end
                #1; assert (push_capacity == 2) else $fatal(1, "merge test allocation capacity");
                push_count = 2; tick();
            end
            for (int step = 0; step < 8; step++) begin
                sample = random_word(); mdu_available = sample[7];
                for (int portno = 0; portno < 2; portno++) begin
                    broadcast[portno] = '{valid:sample[portno], id:tag((step+portno)%6+12, 3),
                        data:xlen_t'({sample, sample ^ (32'h16409abc+32'(portno))})};
                    // 错代次不得唤醒；正确广播在同拍直接参与参考合并。
                    if (sample[portno+10]) broadcast[portno].id.generation++;
                    if (broadcast[portno].valid) same_cycle_wakes++;
                end
                #1; check_merge();
                if (step == 4 && sample[8]) recovery = '{valid:1, id:tag(2), pc:'0};
                else if (operands_ready[0] && sample[5])
                    pop_count = operands_ready[1] && sample[6] ? 2 : 1;
                tick();
            end
            scenarios++;
        end
        assert (same_cycle_wakes > 1000 && selected_patterns[0] > 0 && selected_patterns[1] > 0 &&
                selected_patterns[2] > 0 && selected_patterns[3] > 0) else $fatal(1, "merge coverage");
        $display("PASS tb_scoreboard_issue_merge XLEN=%0d limited_ooo=%0d scenarios=%0d checks=%0d wake=%0d pairs_ii=%0d mi=%0d im=%0d mm=%0d",
            XLEN, LIMITED_OOO, scenarios, checks, same_cycle_wakes, selected_patterns[0],
            selected_patterns[1], selected_patterns[2], selected_patterns[3]);
        $finish;
    end
    initial begin #1000000; $fatal(1, "merge watchdog"); end
endmodule
