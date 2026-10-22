// Module: tb_scoreboard_integer_ooo
// Description: Checks ready bypass, full tags, operand preservation, memory order and serial barriers.
module tb_scoreboard_integer_ooo;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic [1:0] push_count, push_memory, push_capacity, pop_count, operands_ready;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [2];
    logic [$clog2(8+4+1)-1:0] occupancy;
    split_scoreboard_queue #(.INTEGER_DEPTH(8), .MEMORY_DEPTH(4), .LIMITED_OOO(1)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int age, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(int'(head_slot)+age), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic retire_id_t dependency;
        return '{slot:RETIRE_IDX_W'(RETIRE_ENTRIES-3), generation:RETIRE_GEN_W'(7)};
    endfunction
    task automatic idle;
        push_count = 0; pop_count = 0; push_memory = 0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) begin push_packet[lane] = '0; broadcast[lane] = '0; end
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic clear;
        flush = 1; tick(); flush = 0;
        head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-2); mdu_available = 1;
    endtask
    task automatic offer(input int lane, age, input bit memory_op = 0, pending = 0);
        push_packet[lane] = '0;
        push_packet[lane].valid = 1; push_packet[lane].retire_id = tag(age);
        push_packet[lane].uop.mem_read = memory_op; push_memory[lane] = memory_op;
        push_packet[lane].rs1_dependency = '{pending:pending, id:dependency()};
    endtask
    task automatic wake;
        broadcast[0] = '{valid:1, id:dependency(), data:xlen_t'(42)};
    endtask
    task automatic expect_first(input int age);
        #1; assert (operands_ready[0] && issue_packet[0].retire_id == tag(age))
            else $fatal(1, "ready selection expected age=%0d got=%0d ready=%b", age,
                        issue_packet[0].retire_id.slot, operands_ready);
    endtask
    initial begin
        idle(); head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-2);
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        tick(); rst = 0;
        // 年轻同名写者及旧值使用者越过阻塞整数项，标签 RAW 仍保留。
        offer(0, 0, 0, 1); offer(1, 1); push_count = 2;
        push_packet[0].rd = 5; push_packet[1].rd = 5; tick();
        offer(0, 2); push_packet[0].rs1_data = 91; push_count = 1; tick();
        expect_first(1); assert (issue_packet[1].retire_id == tag(2) && issue_packet[1].rs1_data == 91) else $fatal;
        pop_count = 1; tick();
        broadcast[0] = '{valid:1, id:dependency(), data:xlen_t'(99)};
        broadcast[0].id.generation++; tick();
        expect_first(2); assert (!issue_packet[1].valid) else $fatal(1, "stale generation woke RAW");
        wake(); expect_first(0);
        assert (issue_packet[0].rs1_data == 42 && issue_packet[1].rs1_data == 91) else $fatal(1, "RAW/WAR data");
        pop_count = 2; tick(); assert (occupancy == 0) else $fatal;
        // 等待 Load 的整数可以被旁路，内存 FIFO 的年轻项仍等待头项地址。
        offer(0, 0, 1, 1); offer(1, 1); push_count = 2; tick();
        offer(0, 2, 1); push_count = 1; tick();
        expect_first(1); assert (!issue_packet[1].valid) else $fatal(1, "memory head bypass");
        pop_count = 1; tick();
        #1; assert (operands_ready == 0) else $fatal;
        wake(); expect_first(0); assert (issue_packet[1].retire_id == tag(2)) else $fatal;
        pop_count = 2; tick();
        // 未对齐异常到 EX 才形成，年轻访存不得先于仍在 IQ 的老整数进入 ISS。
        offer(0, 0, 0, 1); offer(1, 1, 1); push_count = 2; tick();
        offer(0, 2); push_count = 1; tick(); expect_first(2);
        assert (!issue_packet[1].valid) else $fatal(1, "memory crossed waiting integer");
        pop_count = 1; tick(); wake(); expect_first(0);
        assert (issue_packet[1].retire_id == tag(1)) else $fatal(1, "ordered ALU/memory pair missing");
        pop_count = 2; tick();
        // 分支也可能形成晚异常；只允许纯整数运算越过等待分支或访存。
        offer(0, 0, 0, 1); push_packet[0].uop.branch_op = BR_EQ;
        offer(1, 1, 1); push_count = 2; tick();
        offer(0, 2); push_count = 1; tick(); expect_first(2); pop_count = 1; tick();
        wake(); expect_first(0); assert (issue_packet[1].retire_id == tag(1)) else $fatal(1, "ordered branch/memory pair missing");
        pop_count = 2; tick();
        offer(0, 0, 1, 1); offer(1, 1); push_packet[1].uop.branch_op = BR_EQ;
        push_count = 2; tick();
        offer(0, 2); push_count = 1; tick(); expect_first(2); pop_count = 1; tick();
        wake(); expect_first(0); assert (!issue_packet[1].valid) else $fatal(1, "branch crossed memory");
        pop_count = 1; tick(); expect_first(1); pop_count = 1; tick();
        // Store 地址未知时后续 Load 保持顺序。
        offer(0, 0, 1, 1); push_packet[0].uop.mem_read = 0; push_packet[0].uop.mem_write = 1;
        offer(1, 1, 1); push_count = 2; tick();
        offer(0, 2); push_count = 1; tick(); expect_first(2); pop_count = 1; tick();
        wake(); expect_first(0); assert (issue_packet[1].retire_id == tag(1)) else $fatal;
        pop_count = 2; tick();
        // 忙 MDU 不占据 ISS，两个就绪 MDU 也只能挑出一个。
        offer(0, 0); push_packet[0].uop.fu = FU_MULDIV;
        offer(1, 1); push_count = 2; mdu_available = 0; tick();
        expect_first(1); pop_count = 1; tick();
        offer(0, 2); push_packet[0].uop.fu = FU_MULDIV; push_count = 1; tick();
        #1; assert (operands_ready == 0) else $fatal;
        mdu_available = 1; expect_first(0); assert (!issue_packet[1].valid) else $fatal;
        pop_count = 1; tick(); expect_first(2); pop_count = 1; tick();
        // CSR/FENCE 屏障不允许年轻访存先占 LSU；串行项等待 ROB 队头。
        offer(0, 0, 0, 1); offer(1, 1); push_packet[1].uop.csr_valid = 1; push_count = 2; tick();
        offer(0, 2); offer(1, 3, 1); push_count = 2; tick();
        #1; assert (operands_ready == 0) else $fatal(1, "serial barrier bypass");
        wake(); expect_first(0); assert (!issue_packet[1].valid) else $fatal;
        pop_count = 1; tick(); head_slot++; expect_first(0);
        pop_count = 1; tick(); expect_first(1); assert (issue_packet[1].retire_id == tag(2)) else $fatal;
        pop_count = 2; tick(); clear();
        // 选择留下的空洞可重新分配；恢复跨 ROB 尾部，清掉任意物理槽的年轻项。
        for (int age = 0; age < 8; age += 2) begin
            offer(0, age, 0, 1); offer(1, age+1); push_count = 2; tick();
        end
        #1; assert (push_capacity == 0 && occupancy == 8) else $fatal;
        expect_first(1); pop_count = 2; tick();
        offer(0, 8); offer(1, 9); push_count = 2; tick();
        #1; assert (occupancy == 8 && push_capacity == 0) else $fatal;
        recovery = '{valid:1, id:tag(3), pc:'0}; tick();
        #1; assert (occupancy == 2 && operands_ready == 0) else $fatal(1, "hole recovery");
        wake(); expect_first(0); assert (issue_packet[1].retire_id == tag(2)) else $fatal;
        pop_count = 2; tick(); clear();
        #1; assert (occupancy == 0 && !issue_packet[0].valid) else $fatal;
        $display("PASS tb_scoreboard_integer_ooo XLEN=%0d bypass RAW WAW WAR memory MDU serial holes recovery", XLEN);
        $finish;
    end
endmodule
