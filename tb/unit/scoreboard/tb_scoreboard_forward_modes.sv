// Module: tb_scoreboard_forward_modes
// Description: Checks same-cycle and captured LSU hints, branch masking and ordinary completion bypass.
module tb_scoreboard_forward_modes;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0, mdu_available = 1;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic [1:0] push_count, push_memory, push_capacity, pop_count, operands_ready;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [9];
    logic [$clog2(8+4+1)-1:0] occupancy;
    split_scoreboard_queue #(.INTEGER_DEPTH(8), .MEMORY_DEPTH(4), .BROADCAST_PORTS(9), .LIMITED_OOO(1)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int slot, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    task automatic idle;
        push_count = 0; pop_count = 0; push_memory = 0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) push_packet[lane] = '0;
        for (int portno = 0; portno < 9; portno++) broadcast[portno] = '0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic offer(input int lane, slot, source, input schedule_class_e kind);
        push_packet[lane] = '0; push_packet[lane].valid = 1;
        push_packet[lane].retire_id = tag(slot);
        push_packet[lane].rs1_dependency = '{pending:1, id:tag(source)};
        push_packet[lane].uop.mem_read = kind == SCHED_MEMORY;
        push_packet[lane].uop.branch_op = kind == SCHED_BRANCH ? BR_EQ : BR_NONE;
        push_memory[lane] = kind == SCHED_MEMORY;
    endtask
    initial begin
        idle(); for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        tick(); rst = 0;
        offer(0, 0, 6, SCHED_ALU); offer(1, 1, 7, SCHED_BRANCH); push_count = 2; tick();
        broadcast[7] = '{valid:1, id:tag(6), data:xlen_t'(11)};
        broadcast[8] = '{valid:1, id:tag(7), data:xlen_t'(22)};
        #1;
        unique case (SCHEDULER_FORWARD_MODE)
            IQ_FORWARD_ALL: assert (operands_ready == 3) else $fatal(1, "full hint bypass");
            IQ_FORWARD_BRANCH_COMPLETION: assert (operands_ready == 1) else $fatal(1, "branch hint masking");
            IQ_FORWARD_LSU_CAPTURE: assert (operands_ready == 0) else $fatal(1, "late hint reached issue view");
            IQ_FORWARD_STORE_CAPTURE: assert (operands_ready == 0) else $fatal(1, "late Store hint reached issue view");
            default: $fatal(1, "unknown mode");
        endcase
        tick();
        #1; assert (operands_ready == (SCHEDULER_FORWARD_MODE == IQ_FORWARD_ALL ? 3 : 1) &&
                    issue_packet[0].rs1_data == 11) else $fatal(1, "hint capture or branch mask");
        broadcast[0] = '{valid:1, id:tag(7), data:xlen_t'(42)};
        #1; assert (operands_ready == 3 && issue_packet[1].rs1_data ==
                    (SCHEDULER_FORWARD_MODE == IQ_FORWARD_ALL ? 22 : 42))
            else $fatal(1, "ordinary completion did not wake branch");
        pop_count = 2; tick();
        // 合法读返回与 Store 资格分源。模式 3 保留返回旁路，模式 1/2 仍屏蔽分支。
        offer(0, 0, 7, SCHED_BRANCH); push_count = 1; tick();
        broadcast[5] = '{valid:1, id:tag(7), data:xlen_t'(42)};
        #1; assert (operands_ready == ((SCHEDULER_FORWARD_MODE inside {IQ_FORWARD_ALL, IQ_FORWARD_STORE_CAPTURE}) ? 1 : 0))
            else $fatal(1, "load return branch policy");
        tick();
        #1; assert (operands_ready == ((SCHEDULER_FORWARD_MODE inside {IQ_FORWARD_ALL, IQ_FORWARD_STORE_CAPTURE}) ? 1 : 0))
            else $fatal(1, "load return capture policy");
        broadcast[0] = '{valid:1, id:tag(7), data:xlen_t'(42)};
        #1; assert (operands_ready == 1 && issue_packet[0].rs1_data == 42) else $fatal;
        pop_count = 1; tick();
        // Memory FIFO 同样区分当拍旁路和沿后捕获，不增加 Load 的描述符/返回级。
        offer(0, 0, 6, SCHED_MEMORY); push_count = 1; tick();
        broadcast[5] = '{valid:1, id:tag(6), data:xlen_t'(11)};
        #1; assert (operands_ready == (SCHEDULER_FORWARD_MODE == IQ_FORWARD_LSU_CAPTURE ? 0 : 1)) else $fatal;
        tick(); #1; assert (operands_ready == 1 && issue_packet[0].rs1_data == 11) else $fatal;
        pop_count = 1; tick();
        offer(0, 0, 6, SCHED_MEMORY); push_count = 1; tick();
        broadcast[7] = '{valid:1, id:tag(6), data:xlen_t'(11)};
        #1; assert (operands_ready == ((SCHEDULER_FORWARD_MODE inside {IQ_FORWARD_LSU_CAPTURE, IQ_FORWARD_STORE_CAPTURE}) ? 0 : 1))
            else $fatal(1, "Store hint memory issue policy");
        tick(); #1; assert (operands_ready == 1 && issue_packet[0].rs1_data == 11) else $fatal;
        pop_count = 1; tick();
        // 分配当拍也不能把提示数据保存到被屏蔽的分支操作数中。
        offer(0, 0, 7, SCHED_BRANCH); push_count = 1;
        broadcast[8] = '{valid:1, id:tag(7), data:xlen_t'(99)}; tick();
        #1; assert (operands_ready == (SCHEDULER_FORWARD_MODE == IQ_FORWARD_ALL ? 1 : 0)) else $fatal;
        broadcast[2] = '{valid:1, id:tag(7), data:xlen_t'(42)};
        #1; assert (operands_ready == 1 && issue_packet[0].rs1_data ==
                    (SCHEDULER_FORWARD_MODE == IQ_FORWARD_ALL ? 99 : 42)) else $fatal;
        pop_count = 1; tick();
        // 完整代次仍参与提示匹配，ALU/MDU 的普通入 CMP 广播保持当拍可用。
        offer(0, 0, 6, SCHED_ALU); push_count = 1; tick();
        broadcast[7] = '{valid:1, id:tag(6, 2), data:xlen_t'(99)}; tick();
        #1; assert (operands_ready == 0) else $fatal(1, "stale hint generation");
        broadcast[4] = '{valid:1, id:tag(6), data:xlen_t'(11)};
        #1; assert (operands_ready == 1 && issue_packet[0].rs1_data == 11) else $fatal(1, "MDU ordinary bypass");
        pop_count = 1; tick();
        #1; assert (occupancy == 0) else $fatal;
        $display("PASS tb_scoreboard_forward_modes XLEN=%0d mode=%0d branch_mask capture load_return ordinary generation", XLEN, SCHEDULER_FORWARD_MODE);
        $finish;
    end
endmodule
