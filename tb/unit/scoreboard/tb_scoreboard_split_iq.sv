// Module: tb_scoreboard_split_iq
// Description: Checks split-bank capacity, global ordering, partial consumption, wrap and recovery.
module tb_scoreboard_split_iq #(
    parameter int unsigned INTEGER_DEPTH = 8,
    parameter int unsigned MEMORY_DEPTH = 4
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    logic mdu_available = 1;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic [1:0] push_count, push_capacity, pop_count, operands_ready;
    logic [1:0] push_memory;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [2];
    logic [$clog2(INTEGER_DEPTH+MEMORY_DEPTH+1)-1:0] occupancy;
    split_scoreboard_queue #(.INTEGER_DEPTH(INTEGER_DEPTH), .MEMORY_DEPTH(MEMORY_DEPTH), .LIMITED_OOO(0)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int age, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(int'(head_slot) + age), generation:RETIRE_GEN_W'(generation)};
    endfunction
    task automatic idle;
        push_count = 0; pop_count = 0; recovery = '0; push_memory = 0;
        for (int lane = 0; lane < 2; lane++) begin
            push_packet[lane] = '0;
            broadcast[lane] = '0;
        end
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic offer(input int lane, age, input bit memory_op, pending = 0);
        push_packet[lane] = '0;
        push_packet[lane].valid = 1;
        push_packet[lane].retire_id = tag(age);
        push_packet[lane].uop.mem_read = memory_op;
        push_memory[lane] = memory_op;
        push_packet[lane].rs1_dependency = '{pending:pending, id:tag(RETIRE_ENTRIES-1)};
    endtask
    task automatic clear;
        flush = 1; tick(); flush = 0;
    endtask
    initial begin
        idle(); head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES - 2);
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        tick(); rst = 0;
        // 内存头项未就绪时，年轻整数仍显示在第二槽，但不能越过头项消费。
        offer(0, 0, 1, 1); offer(1, 1, 0); push_count = 2; tick();
        #1; assert (occupancy == 2 && operands_ready == 2'b10 &&
                    issue_packet[0].retire_id == tag(0) && issue_packet[1].retire_id == tag(1))
            else $fatal(1, "split IQ skipped blocked memory head");
        broadcast[0] = '{valid:1, id:tag(RETIRE_ENTRIES-1, 2), data:xlen_t'(99)}; tick();
        #1; assert (!operands_ready[0]) else $fatal(1, "wrong generation wakeup");
        broadcast[0] = '{valid:1, id:tag(RETIRE_ENTRIES-1), data:xlen_t'(42)};
        #1; assert (operands_ready == 3 && issue_packet[0].rs1_data == 42) else $fatal;
        pop_count = 1; tick();
        #1; assert (occupancy == 1 && issue_packet[0].retire_id == tag(1)) else $fatal;
        pop_count = 1; tick();
        // Memory 满不影响 Integer 接纳；同类双分配只能使用该类的容量。
        for (int first = 0; first < MEMORY_DEPTH; first += 2) begin
            offer(0, first, 1); offer(1, first+1, 1); push_count = 2; tick();
        end
        offer(0, MEMORY_DEPTH, 1); offer(1, MEMORY_DEPTH+1, 0);
        #1; assert (push_capacity == 0) else $fatal(1, "full memory bank accepted first packet");
        offer(0, MEMORY_DEPTH, 0); offer(1, MEMORY_DEPTH+1, 1);
        #1; assert (push_capacity == 1) else $fatal(1, "cross-bank partial capacity");
        push_count = 1; tick();
        for (int first = 1; first < INTEGER_DEPTH; first += 2) begin
            offer(0, MEMORY_DEPTH+first, 0);
            if (first+1 < INTEGER_DEPTH) offer(1, MEMORY_DEPTH+first+1, 0);
            #1; assert (push_capacity == (first+1 < INTEGER_DEPTH ? 2 : 1)) else $fatal;
            push_count = first+1 < INTEGER_DEPTH ? 2 : 1; tick();
        end
        #1; assert (occupancy == INTEGER_DEPTH+MEMORY_DEPTH && push_capacity == 0) else $fatal;
        for (int age = 0; age < INTEGER_DEPTH+MEMORY_DEPTH; age++) begin
            #1; assert (issue_packet[0].valid && issue_packet[0].retire_id == tag(age))
                else $fatal(1, "global order age=%0d", age);
            pop_count = 1; tick();
        end
        #1; assert (occupancy == 0) else $fatal;
        // 两个环形队列跨越尾指针后再次混合，恢复只留下截止 ID 及更老项。
        offer(0, 0, 0); offer(1, 1, 1); push_count = 2; tick();
        offer(0, 2, 1); offer(1, 3, 0); push_count = 2; tick();
        recovery = '{valid:1, id:tag(1), pc:'0}; tick();
        #1; assert (occupancy == 2 && issue_packet[0].retire_id == tag(0) &&
                    issue_packet[1].retire_id == tag(1)) else $fatal(1, "cross-bank recovery");
        pop_count = 2; tick();
        // 两个同类项和异类项分别能形成双消费，且复用槽保持新包。
        offer(0, 2, 0); offer(1, 3, 0); push_count = 2; tick();
        #1; assert (operands_ready == 3 && issue_packet[1].retire_id == tag(3)) else $fatal;
        pop_count = 2; tick();
        offer(0, 4, 1); offer(1, 5, 0); push_count = 2; tick();
        clear();
        #1; assert (occupancy == 0 && !issue_packet[0].valid && !issue_packet[1].valid) else $fatal;
        $display("PASS tb_scoreboard_split_iq XLEN=%0d ROB=%0d int=%0d mem=%0d order capacity partial wrap recovery", XLEN, RETIRE_ENTRIES, INTEGER_DEPTH, MEMORY_DEPTH);
        $finish;
    end
endmodule
