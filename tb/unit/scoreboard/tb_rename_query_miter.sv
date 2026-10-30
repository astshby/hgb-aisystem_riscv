// Module: tb_rename_query_miter
// Description: Compares registered-map queries with the preserved RAT at every combinational and sequential boundary.
module tb_rename_query_miter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;

    logic clk = 0, rst = 1, flush = 0;
    logic [1:0] alloc_fire;
    retire_alloc_t alloc_meta [2];
    retire_id_t alloc_id [2];
    d1_d2_t decode [2];
    retire_trace_t retire [2];
    gpr_dependency_t source_new [2][2], source_old [2][2];
    logic checkpoint_ready_new, checkpoint_ready_old, branch_resolved;
    retire_id_t resolved_id;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic all_checkpoints_initialized = 0;
    int checks = 0, cycles = 25000, random_state = 32'h6c5a1031;
    int recovery_cases = 0, retire_cases = 0, resolved_cases = 0, random_allocations = 0;

    rename_table dut_new (.source(source_new), .checkpoint_ready(checkpoint_ready_new), .*);
    rename_table_reference dut_old (.source(source_old), .checkpoint_ready(checkpoint_ready_old), .*);
    always #5 clk = ~clk;

    function automatic retire_id_t tag(input int slot, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic int unsigned random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return unsigned'(random_state);
    endfunction
    task automatic idle;
        alloc_fire = 0; branch_resolved = 0; resolved_id = '0; recovery = '0;
        for (int lane = 0; lane < 2; lane++) begin
            alloc_meta[lane] = '0; alloc_id[lane] = '0; decode[lane] = '0; retire[lane] = '0;
        end
    endtask
    task automatic writer(input int lane, slot, rd, rs1, rs2, input bit branch = 0);
        alloc_id[lane] = tag(slot);
        alloc_meta[lane] = '0;
        alloc_meta[lane].gpr_write = 1;
        alloc_meta[lane].rd = gpr_addr_t'(rd);
        alloc_meta[lane].kind = branch ? RET_BRANCH : RET_EXEC;
        decode[lane] = '0;
        decode[lane].valid = 1;
        decode[lane].rd = gpr_addr_t'(rd);
        decode[lane].rs1 = gpr_addr_t'(rs1);
        decode[lane].rs2 = gpr_addr_t'(rs2);
        decode[lane].uop.rs1_used = 1;
        decode[lane].uop.rs2_used = 1;
        decode[lane].uop.branch_op = branch ? BR_JAL : BR_NONE;
    endtask
    task automatic compare_all;
        assert (source_new === source_old) else $fatal(1, "source mismatch check=%0d new=%p old=%p", checks, source_new, source_old);
        assert (checkpoint_ready_new === checkpoint_ready_old) else $fatal(1, "checkpoint_ready mismatch");
        for (int regno = 0; regno < GPR_NUM; regno++) begin
            assert (dut_new.map_q[regno] === dut_old.map_q[regno]) else $fatal(1, "map_q mismatch reg=%0d", regno);
            assert (dut_new.map_d[regno] === dut_old.map_d[regno]) else $fatal(1, "map_d mismatch reg=%0d", regno);
            assert (dut_new.after_first[regno] === dut_old.after_first[regno]) else $fatal(1, "after_first mismatch reg=%0d", regno);
            assert (dut_new.after_second[regno] === dut_old.after_second[regno]) else $fatal(1, "after_second mismatch reg=%0d", regno);
        end
        for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
            assert (dut_new.owner_q[cp].valid === dut_old.owner_q[cp].valid) else $fatal(1, "owner valid mismatch");
            // 未复位宽checkpoint用合法分支填满后，连同无效owner载荷也逐位比较。
            if (all_checkpoints_initialized || dut_old.owner_q[cp].valid) begin
                assert (dut_new.owner_q[cp] === dut_old.owner_q[cp]) else $fatal(1, "owner payload mismatch cp=%0d", cp);
                for (int regno = 0; regno < GPR_NUM; regno++)
                    assert (dut_new.checkpoint_q[cp][regno] === dut_old.checkpoint_q[cp][regno])
                        else $fatal(1, "checkpoint data mismatch cp=%0d reg=%0d", cp, regno);
            end
        end
        checks++;
    endtask
    task automatic step;
        #1; compare_all();
        @(posedge clk); #1; compare_all();
        @(negedge clk); idle();
    endtask
    task automatic expect_dependency(input int lane, operand, input logic pending, input retire_id_t id);
        gpr_dependency_t expected;
        expected = '{pending:pending, id:id};
        #1;
        assert (source_new[lane][operand] === expected)
            else $fatal(1, "directed dependency lane=%0d operand=%0d expected=%p got=%p", lane, operand, expected, source_new[lane][operand]);
    endtask

    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        head_slot = 0; idle(); step(); rst = 0;
        // 先初始化每个宽checkpoint；之后比较全部原始载荷，不依赖仿真器的X初值。
        for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
            writer(0, cp, cp + 1, 0, 0, 1); alloc_fire = 1; step();
        end
        all_checkpoints_initialized = 1;
        flush = 1; step(); flush = 0;

        writer(0, 1, 5, 5, 0); writer(1, 2, 5, 5, 5); alloc_fire = 3;
        expect_dependency(0, 0, 0, '0);
        expect_dependency(1, 0, 1, tag(1)); expect_dependency(1, 1, 1, tag(1)); step();
        writer(0, 3, 6, 5, 5);
        retire[0] = '{valid:0, id:tag(2), rd:gpr_addr_t'(5), rd_we:1, default:'0};
        retire[1] = '{valid:1, id:tag(2, 2), rd:gpr_addr_t'(5), rd_we:1, default:'0};
        expect_dependency(0, 0, 1, tag(2)); step();

        // prune匹配完整ID，保留pending=0的ID；退休rd载荷不参与旧实现的匹配。
        writer(0, 3, 6, 5, 5);
        retire[0] = '{valid:1, id:tag(2), rd:gpr_addr_t'(31), rd_we:1, default:'0};
        expect_dependency(0, 0, 0, tag(2)); step();
        writer(0, 3, 5, 5, 0); writer(1, 4, 5, 5, 0); alloc_fire = 3;
        retire[0] = '{valid:1, id:tag(3), rd:gpr_addr_t'(5), rd_we:1, default:'0};
        expect_dependency(0, 0, 0, tag(2)); expect_dependency(1, 0, 1, tag(3)); step();

        // alloc metadata本身拥有更新资格，第一槽decode无效或异常也不能额外门控RAW旁路。
        writer(0, 5, 5, 0, 0); writer(1, 6, 7, 5, 5); alloc_fire = 1;
        decode[0].valid = 0; decode[0].exc.valid = 1;
        expect_dependency(0, 0, 0, '0); expect_dependency(1, 0, 1, tag(5)); step();
        writer(0, 7, 0, 0, 5); writer(1, 8, 0, 0, 5); alloc_fire = 3;
        decode[0].uop.rs2_used = 0; decode[1].exc.valid = 1;
        expect_dependency(0, 0, 0, '0); expect_dependency(0, 1, 0, '0);
        expect_dependency(1, 1, 0, '0); step();

        // 同组双分支WAW保留两个不同snapshot，恢复第一条不能得到第二条的目的版本。
        writer(0, 9, 8, 5, 0, 1); writer(1, 10, 8, 8, 0, 1); alloc_fire = 3;
        expect_dependency(1, 0, 1, tag(9)); step();
        recovery = '{valid:1, id:tag(9), pc:xlen_t'(64)};
        branch_resolved = 1; resolved_id = tag(9);
        retire[0] = '{valid:1, id:tag(5), rd:gpr_addr_t'(5), rd_we:1, default:'0}; step();
        writer(0, 11, 0, 8, 5); expect_dependency(0, 0, 1, tag(9));
        expect_dependency(0, 1, 0, tag(5)); step();

        for (int cycle = 0; cycle < cycles; cycle++) begin
            int pick, free_slot, match_reg;
            idle();
            head_slot = RETIRE_IDX_W'(random_word());
            flush = cycle % 503 == 502;
            for (int lane = 0; lane < 2; lane++) begin
                writer(lane, int'(random_word() % RETIRE_ENTRIES), int'(random_word() % GPR_NUM),
                       int'(random_word() % GPR_NUM), int'(random_word() % GPR_NUM), random_word() % 5 == 0);
                alloc_id[lane].generation = RETIRE_GEN_W'(random_word());
                decode[lane].valid = random_word() % 4 != 0;
                decode[lane].exc.valid = random_word() % 19 == 0;
                decode[lane].uop.rs1_used = random_word() % 3 != 0;
                decode[lane].uop.rs2_used = random_word() % 3 != 0;
                alloc_meta[lane].gpr_write = random_word() % 5 != 0;
                retire[lane].valid = random_word() % 3 != 0;
                retire[lane].rd_we = random_word() % 4 != 0;
                retire[lane].rd = gpr_addr_t'(random_word());
                match_reg = int'(random_word() % GPR_NUM);
                retire[lane].id = random_word() % 2 == 0 ? dut_old.map_q[match_reg].id : retire_id_t'(random_word());
                if (retire[lane].valid && retire[lane].rd_we) retire_cases++;
            end
            if (random_word() % 3 == 0) decode[1].rs1 = alloc_meta[0].rd;
            if (random_word() % 3 == 0) decode[1].rs2 = alloc_meta[0].rd;
            if (random_word() % 4 == 0) alloc_meta[1].rd = alloc_meta[0].rd;
            unique case (random_word() % 3)
                0: alloc_fire = 0;
                1: alloc_fire = 1;
                default: alloc_fire = 3;
            endcase
            free_slot = -1;
            for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++)
                if (dut_old.owner_q[cp].valid) free_slot = cp;
            pick = int'(random_word() % BRANCH_CHECKPOINTS);
            if (dut_old.owner_q[pick].valid) free_slot = pick;
            if (free_slot >= 0 && random_word() % 5 == 0) begin
                branch_resolved = 1; resolved_id = dut_old.owner_q[free_slot].id; resolved_cases++;
            end else resolved_id = retire_id_t'(random_word());
            if (free_slot >= 0 && random_word() % 11 == 0 && !flush) begin
                recovery = '{valid:1, id:dut_old.owner_q[free_slot].id, pc:xlen_t'(random_word())};
                alloc_fire = 0; recovery_cases++;
            end else begin
                recovery.id = retire_id_t'(random_word()); recovery.pc = xlen_t'(random_word());
            end
            #1;
            if (!checkpoint_ready_old) alloc_fire = 0;
            if (|alloc_fire) random_allocations++;
            step();
        end
        $display("PASS tb_rename_query_miter XLEN=%0d ROB=%0d cycles=%0d checks=%0d full_checkpoint_data=1 retire=%0d recovery=%0d resolved=%0d allocations=%0d",
                 XLEN, RETIRE_ENTRIES, cycles, checks, retire_cases, recovery_cases, resolved_cases, random_allocations);
        $finish;
    end
endmodule
