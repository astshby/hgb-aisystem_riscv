// Module: tb_scoreboard_operands
// Description: Verifies tagged operand capture across backpressure, producer reuse and recovery.
module tb_scoreboard_operands #(parameter int unsigned BROADCAST_PORTS = 2, parameter bit ISSUE_BYPASS = 0);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic [1:0] push_count, push_capacity, pop_count, operands_ready;
    d2_ex_t push_packet [2], issue_packet [2];
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_gpr_forward_t broadcast [BROADCAST_PORTS];
    logic [$clog2(ISSUE_QUEUE_ENTRIES+1)-1:0] occupancy;
    scoreboard_queue #(.BROADCAST_PORTS(BROADCAST_PORTS), .ISSUE_BYPASS(ISSUE_BYPASS)) dut (.*);
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int slot, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    task automatic idle;
        push_count = 0; pop_count = 0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) push_packet[lane] = '0;
        for (int portno = 0; portno < BROADCAST_PORTS; portno++) broadcast[portno] = '0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic push(input int lane, slot, source_slot);
        push_packet[lane] = '0;
        push_packet[lane].valid = 1;
        push_packet[lane].retire_id = tag(slot);
        push_packet[lane].rs1_dependency = '{pending:1, id:tag(source_slot)};
    endtask
    initial begin
        idle(); head_slot = 0;
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) producers[slot] = '0;
        tick(); rst = 0;
        push(0, 2, 0); push(1, 3, 1); push_count = 2; tick();
        #1; assert (operands_ready == 0 && occupancy == 2) else $fatal;
        // 第二条先就绪也不能越过第一条；队列仅提供年龄前缀。
        broadcast[BROADCAST_PORTS-1] = '{valid:1, id:tag(1), data:xlen_t'(22)}; tick();
        #1; assert (operands_ready == 2'b10 && issue_packet[0].retire_id == tag(2)) else $fatal;
        broadcast[0] = '{valid:1, id:tag(0, 2), data:xlen_t'(99)}; tick();
        #1; assert (operands_ready == 2'b10) else $fatal(1, "wrong generation woke source");
        broadcast[0] = '{valid:1, id:tag(0), data:xlen_t'(11)}; tick();
        #1; assert (operands_ready == 3 && issue_packet[0].rs1_data == 11 &&
                    issue_packet[1].rs1_data == 22) else $fatal;
        // 相同物理槽的新代次完成不能覆盖已经捕获的旧值。
        broadcast[0] = '{valid:1, id:tag(0, 2), data:xlen_t'(99)}; tick();
        #1; assert (issue_packet[0].rs1_data == 11) else $fatal;
        pop_count = 1; tick();
        #1; assert (occupancy == 1 && issue_packet[0].retire_id == tag(3)) else $fatal;
        pop_count = 1; tick();
        // 入队时读取已完成 ROB；同拍完成的数据通过广播捕获。
        producers[4] = '{valid:1, ready:1, id:tag(4), data:xlen_t'(44), kind:RET_EXEC, default:'0};
        push(0, 6, 4); push(1, 7, 5); push_count = 2;
        broadcast[0] = '{valid:1, id:tag(5), data:xlen_t'(55)}; tick();
        producers[4] = '0;
        #1; assert (operands_ready == 3 && issue_packet[0].rs1_data == 44 &&
                    issue_packet[1].rs1_data == 55) else $fatal;
        recovery = '{valid:1, id:tag(6), pc:'0}; tick();
        #1; assert (occupancy == 1 && issue_packet[0].retire_id == tag(6) &&
                    !issue_packet[1].valid) else $fatal;
        flush = 1; tick(); flush = 0;
        #1; assert (occupancy == 0 && !issue_packet[0].valid) else $fatal;
        // 所有广播口同拍返回不同完整标签；等待项需独立捕获，不能只检查末端口。
        assert (BROADCAST_PORTS >= 2 && BROADCAST_PORTS <= ISSUE_QUEUE_ENTRIES) else $fatal;
        for (int first = 0; first < BROADCAST_PORTS; first += 2) begin
            push(0, 8 + first, first);
            if (first + 1 < BROADCAST_PORTS) push(1, 9 + first, first + 1);
            push_count = first + 1 < BROADCAST_PORTS ? 2 : 1;
            tick();
        end
        #1; assert (operands_ready == 0) else $fatal;
        for (int portno = 0; portno < BROADCAST_PORTS; portno++)
            broadcast[portno] = '{valid:1, id:tag(portno), data:xlen_t'(101 + portno)};
        #1; assert (operands_ready == (ISSUE_BYPASS ? 2'b11 : 2'b00))
            else $fatal(1, "issue-view bypass setting");
        if (ISSUE_BYPASS)
            assert (issue_packet[0].rs1_data == 101 && issue_packet[1].rs1_data == 102)
                else $fatal(1, "ISS did not capture same-cycle broadcast");
        tick();
        // 已捕获值在背压和同槽新代次广播下保持；ROB 已无该生产者也能发射。
        for (int portno = 0; portno < BROADCAST_PORTS; portno++)
            broadcast[portno] = '{valid:1, id:tag(portno, 2), data:xlen_t'(999)};
        tick();
        for (int first = 0; first < BROADCAST_PORTS; first += 2) begin
            #1; assert (operands_ready[0] && issue_packet[0].rs1_data == xlen_t'(101 + first))
                else $fatal(1, "lost broadcast port %0d", first);
            if (first + 1 < BROADCAST_PORTS)
                assert (operands_ready[1] && issue_packet[1].rs1_data == xlen_t'(102 + first))
                    else $fatal(1, "lost broadcast port %0d", first + 1);
            pop_count = first + 1 < BROADCAST_PORTS ? 2 : 1;
            tick();
        end
        #1; assert (occupancy == 0) else $fatal;
        $display("PASS tb_scoreboard_operands XLEN=%0d capture backpressure reuse recovery ports=%0d issue_bypass=%0d", XLEN, BROADCAST_PORTS, ISSUE_BYPASS);
        $finish;
    end
endmodule
