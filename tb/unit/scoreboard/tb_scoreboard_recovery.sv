// Module: tb_scoreboard_recovery
// Description: Checks partial ROB recovery, old completion rejection and generation reuse.
module tb_scoreboard_recovery;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
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
    retire_id_t probe_id [5];
    logic [4:0] probe_accept;
    retire_id_t ids [16];
    initial for (int probe = 0; probe < 5; probe++) probe_id[probe] = '0;
    always #5 clk = ~clk;
    retire_queue #(.RENAMED(1)) dut (.probe_live(), .ras_entries(), .ras_head_slot(), .*);
    task automatic idle;
        alloc_valid = 0; alloc_valid_1 = 0; alloc_meta = '0; alloc_meta_1 = '0;
        complete_valid = 0; complete_valid_1 = 0; completion = '0; completion_1 = '0;
        query = '0; query_1 = '0; retire_ready = 0; retire_ready_1 = 0; branch_recovery = '0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    initial begin
        idle(); tick(); rst = 0; tick();
        for (int pair = 0; pair < 4; pair++) begin
            alloc_valid = 1; alloc_valid_1 = 1;
            alloc_meta.kind = pair == 1 ? RET_BRANCH : RET_EXEC;
            alloc_meta_1.kind = RET_EXEC;
            alloc_meta.gpr_write = 1; alloc_meta_1.gpr_write = 1;
            alloc_meta.rd = 5; alloc_meta_1.rd = 5;
            #1; assert (alloc_ready && alloc_ready_1) else $fatal;
            ids[pair * 2] = alloc_id; ids[pair * 2 + 1] = alloc_id_1; tick();
        end
        #1; assert (occupancy == 8) else $fatal;
        // 年轻项先完成；恢复时更老结果保留，年轻完成不能留下 done。
        complete_valid = 1; completion.id = ids[0]; completion.result.gpr_data = 10;
        complete_valid_1 = 1; completion_1.id = ids[7]; completion_1.result.gpr_data = 70; tick();
        branch_recovery = '{valid:1, id:ids[2], pc:xlen_t'(64)};
        complete_valid = 1; completion.id = ids[1]; completion.result.gpr_data = 20;
        complete_valid_1 = 1; completion_1.id = ids[3]; completion_1.result.gpr_data = 30;
        retire_ready = 1;
        drain_complete = 0;
        #1; assert (retire_fire && !complete_reject && complete_reject_1) else $fatal;
        tick();
        #1; assert (occupancy == 2 && head_id == ids[1] && head_complete && recovering &&
                    head_result.gpr_data == 20 && !alloc_ready) else $fatal;
        for (int slot = 3; slot < 8; slot++)
            assert (!producer_entries[slot].valid) else $fatal(1, "younger ROB entry survived");
        complete_valid = 1; completion.id = ids[7];
        #1; assert (complete_reject) else $fatal(1, "late completion not rejected");
        tick();
        drain_complete = 1; tick();
        alloc_valid = 1; #1;
        assert (alloc_ready && alloc_id.slot == ids[3].slot && alloc_id != ids[3])
            else $fatal(1, "recovered tail identity");
        ids[8] = alloc_id; tick();
        // 已释放物理槽重用后，旧代次仍拒绝，新代次能够完成。
        complete_valid = 1; completion.id = ids[3];
        complete_valid_1 = 1; completion_1.id = ids[8];
        #1; assert (complete_reject && !complete_reject_1) else $fatal;
        tick();
        flush_all = 1; tick(); flush_all = 0; tick();
        #1; assert (occupancy == 0 && !head_valid) else $fatal;
        $display("PASS tb_scoreboard_recovery XLEN=%0d ROB=%0d partial old_response reuse", XLEN, RETIRE_ENTRIES);
        $finish;
    end
endmodule
