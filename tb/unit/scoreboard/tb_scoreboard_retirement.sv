// Module: tb_scoreboard_retirement
// Description: Checks registered retirement, precise faults, recovery and continuous two-wide throughput.
module tb_scoreboard_retirement;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, flush_all = 0, drain_complete = 1;
    logic alloc_valid, alloc_ready, alloc_valid_1, alloc_ready_1;
    retire_alloc_t alloc_meta, alloc_meta_1, head_meta, head_meta_1;
    retire_id_t alloc_id, alloc_id_1, head_id, head_id_1;
    logic complete_valid, complete_ready, complete_reject;
    logic complete_valid_1, complete_ready_1, complete_reject_1;
    retire_completion_t completion, completion_1;
    retire_query_t query, query_1;
    retire_query_result_t query_result, query_result_1;
    logic head_valid, head_complete, head_valid_1, head_complete_1;
    retire_result_t head_result, head_result_1;
    logic retire_ready, retire_fire, retire_ready_1, retire_fire_1, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;
    branch_recovery_t branch_recovery;
    retire_gpr_entry_t producer_entries [RETIRE_ENTRIES];
    retire_id_t ids [256];
    int dual_streak, maximum_streak, retired;
    always #5 clk = ~clk;
    retire_queue #(.RENAMED(1), .REGISTER_RETIRE(1)) dut (.ras_entries(), .ras_head_slot(), .*);

    task automatic idle;
        alloc_valid = 0; alloc_valid_1 = 0; alloc_meta = '0; alloc_meta_1 = '0;
        complete_valid = 0; complete_valid_1 = 0; completion = '0; completion_1 = '0;
        query = '0; query_1 = '0; retire_ready = 0; retire_ready_1 = 0; branch_recovery = '0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic restart;
        rst = 1; flush_all = 0; idle(); tick();
        rst = 0; drain_complete = 1; tick();
    endtask
    task automatic offer_pair(input int first);
        alloc_valid = 1; alloc_valid_1 = 1;
        alloc_meta.kind = RET_EXEC; alloc_meta_1.kind = RET_EXEC;
        alloc_meta.seq_pc = xlen_t'(4 * first + 4);
        alloc_meta_1.seq_pc = xlen_t'(4 * first + 8);
        #1;
        assert (alloc_ready && alloc_ready_1) else $fatal(1, "allocation unavailable");
        ids[first] = alloc_id; ids[first+1] = alloc_id_1;
    endtask
    task automatic complete_pair(input int first);
        // 完成口与年龄反向配对，覆盖两个结果交叉写入，答案按程序序号生成。
        complete_valid = 1; complete_valid_1 = 1;
        completion.id = ids[first+1]; completion.result.gpr_data = xlen_t'(first+1);
        completion_1.id = ids[first]; completion_1.result.gpr_data = xlen_t'(first);
    endtask

    initial begin
        restart();
        // 反压期间先完成年轻项；队头本拍完成时，退休与异常观察都必须等待寄存沿。
        offer_pair(0); tick(); offer_pair(2); tick();
        complete_pair(2); tick();
        complete_pair(0); retire_ready = 1; retire_ready_1 = 1;
        #1;
        assert (!head_complete && !head_complete_1 && !retire_fire && !retire_fire_1)
            else $fatal(1, "completion bypassed registered retirement");
        tick();
        assert (head_complete && head_complete_1 && head_result.gpr_data == 0 &&
                head_result_1.gpr_data == 1) else $fatal(1, "registered completion data");
        retire_ready = 1; retire_ready_1 = 1;
        // 重复完成不得破坏已登记的队头结果。
        complete_pair(0); completion_1.result.gpr_data = 999;
        #1; assert (retire_fire && retire_fire_1 && complete_reject && complete_reject_1 &&
                    head_result.gpr_data == 0) else $fatal(1, "duplicate completion");
        tick();
        assert (head_id == ids[2] && head_result.gpr_data == 2) else $fatal(1, "age order");

        restart(); offer_pair(0); tick();
        complete_pair(0);
        completion.result.exc = '{valid:1, cause:EXC_LOAD_ACCESS_FAULT, tval:xlen_t'(32'h80000008)};
        retire_ready = 1;
        #1; assert (!retire_fire && !head_result_1.exc.valid) else $fatal(1, "early fault");
        tick();
        retire_ready = 1; retire_ready_1 = !head_result.exc.valid && !head_result_1.exc.valid;
        #1; assert (retire_fire && !retire_fire_1 && head_result_1.exc.valid)
            else $fatal(1, "second fault crossed older instruction");
        tick();
        #1; assert (head_complete && head_id == ids[1] && head_result.exc.valid &&
                    head_result.exc.tval == xlen_t'(32'h80000008)) else $fatal(1, "precise fault owner");
        flush_all = 1; retire_ready = 1; drain_complete = 0;
        complete_valid = 1; completion.id = ids[1];
        #1; assert (retire_fire && complete_reject && !alloc_ready) else $fatal(1, "fault flush");
        tick(); flush_all = 0;
        assert (recovering && occupancy == 0 && !alloc_ready) else $fatal(1, "flush drain boundary");
        drain_complete = 1; tick();

        // 恢复与更老退休并行；分支完成要存入 ROB，年轻完成被丢弃。
        offer_pair(0); alloc_meta_1.kind = RET_BRANCH; tick(); offer_pair(2); tick();
        complete_valid = 1; completion.id = ids[0]; tick();
        branch_recovery = '{valid:1, id:ids[1], pc:xlen_t'(128)};
        complete_valid = 1; completion.id = ids[1]; completion.result.next_pc = 128;
        complete_valid_1 = 1; completion_1.id = ids[2];
        retire_ready = 1; retire_ready_1 = 1;
        #1; assert (retire_fire && !retire_fire_1 && !complete_reject && complete_reject_1)
            else $fatal(1, "registered branch recovery");
        tick();
        assert (occupancy == 1 && head_id == ids[1] && head_complete && head_result.next_pc == 128)
            else $fatal(1, "recovered branch completion lost");

        // 相同物理槽但旧代次到达端口 0，不能挡住端口 1 的真实完成。
        restart(); offer_pair(0); tick();
        complete_valid = 1; completion.id = ids[0];
        completion.id.generation = ids[0].generation - RETIRE_GEN_W'(1);
        completion.result.gpr_data = 999;
        complete_valid_1 = 1; completion_1.id = ids[0]; completion_1.result.gpr_data = 55;
        #1; assert (complete_reject && !complete_reject_1) else $fatal(1, "old generation blocked live completion");
        tick();
        assert (head_complete && head_result.gpr_data == 55 && head_result.next_pc == 4)
            else $fatal(1, "slot-local completion data or seq_pc");
        complete_valid = 1; completion.id = ids[1]; completion.result.gpr_data = 88;
        complete_valid_1 = 1; completion_1.id = ids[1]; completion_1.result.gpr_data = 99;
        #1; assert (!complete_reject && complete_reject_1) else $fatal(1, "duplicate port priority");
        tick();
        assert (head_result_1.gpr_data == 88) else $fatal(1, "duplicate overwrote first port");

        // 满表同沿双退休/双分配；旧完成不能把新代次标记完成或污染其结果。
        restart();
        for (int index = 0; index < RETIRE_ENTRIES; index += 2) begin
            offer_pair(index); tick();
        end
        complete_pair(0); tick();
        retire_ready = 1; retire_ready_1 = 1;
        offer_pair(RETIRE_ENTRIES); complete_pair(0);
        #1; assert (retire_fire && retire_fire_1 && complete_reject && complete_reject_1)
            else $fatal(1, "full-table reuse handshake");
        tick();
        assert (occupancy == RETIRE_COUNT_W'(RETIRE_ENTRIES) &&
                producer_entries[ids[RETIRE_ENTRIES].slot].valid &&
                !producer_entries[ids[RETIRE_ENTRIES].slot].ready)
            else $fatal(1, "old completion leaked into recycled slot");
        complete_pair(RETIRE_ENTRIES); tick();
        assert (producer_entries[ids[RETIRE_ENTRIES].slot].ready &&
                producer_entries[ids[RETIRE_ENTRIES].slot].data == xlen_t'(RETIRE_ENTRIES))
            else $fatal(1, "recycled slot lost new completion");

        // 包含指针、代次反复回绕；分配、双完成和双退休每拍重叠。
        restart(); dual_streak = 0; maximum_streak = 0; retired = 0;
        for (int cycle = 0; cycle < 102; cycle++) begin
            if (cycle < 100) offer_pair(cycle*2);
            if (cycle >= 1 && cycle < 101) complete_pair((cycle-1)*2);
            retire_ready = 1; retire_ready_1 = 1;
            #1;
            if (cycle >= 2) begin
                assert (retire_fire && retire_fire_1 && head_id == ids[retired] &&
                        head_id_1 == ids[retired+1] && head_result.gpr_data == xlen_t'(retired) &&
                        head_result_1.gpr_data == xlen_t'(retired+1) &&
                        head_result.next_pc == xlen_t'(retired*4+4))
                    else $fatal(1, "continuous ordered retirement cycle=%0d", cycle);
                retired += 2; dual_streak++;
                if (dual_streak > maximum_streak) maximum_streak = dual_streak;
            end else begin
                assert (!retire_fire && !retire_fire_1) else $fatal(1, "early continuous retirement");
                dual_streak = 0;
            end
            tick();
        end
        assert (occupancy == 0 && retired == 200 && maximum_streak == 100)
            else $fatal(1, "throughput or drain");
        $display("PASS tb_scoreboard_retirement XLEN=%0d retired=%0d dual_streak=%0d fault duplicate recovery wrap",
                 XLEN, retired, maximum_streak);
        $finish;
    end
endmodule
