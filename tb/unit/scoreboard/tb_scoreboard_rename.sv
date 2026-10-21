// Module: tb_scoreboard_rename
// Description: Checks same-group renaming, retirement races and branch checkpoint lifetime.
module tb_scoreboard_rename;
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
    gpr_dependency_t source [2][2];
    logic checkpoint_ready, branch_resolved;
    retire_id_t resolved_id;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    rename_table dut (.*);
    always #5 clk = ~clk;

    function automatic retire_id_t tag(input int slot, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
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
    task automatic tick;
        @(posedge clk); #1;
        @(negedge clk); idle();
    endtask
    task automatic expect_source(input int lane, operand, slot, input bit pending = 1);
        #1;
        assert (source[lane][operand].pending == pending &&
                (!pending || source[lane][operand].id == tag(slot)))
            else $fatal(1, "rename source lane=%0d src=%0d expected slot=%0d pending=%0d got=%p",
                        lane, operand, slot, pending, source[lane][operand]);
    endtask
    initial begin
        head_slot = 0; idle(); tick(); rst = 0;
        // 两条都写 x5；第二条的真实 RAW 绑定第一条，下一组读到第二条。
        writer(0, 0, 5, 0, 0); writer(1, 1, 5, 5, 0); alloc_fire = 3;
        expect_source(0, 0, 0, 0); expect_source(1, 0, 0); tick();
        writer(0, 2, 6, 5, 0); expect_source(0, 0, 1);
        retire[0] = '{valid:1, id:tag(0), rd:gpr_addr_t'(5), rd_we:1, default:'0};
        expect_source(0, 0, 1); tick();
        // 分支自身写 x6，下一条覆盖 x6；恢复必须回到分支版本。
        writer(0, 2, 6, 5, 0, 1); writer(1, 3, 6, 6, 0); alloc_fire = 3;
        expect_source(1, 0, 2); tick();
        // 老 x5 在 checkpoint 存活期间退休，恢复后不能引用已释放槽。
        retire[0] = '{valid:1, id:tag(1), rd:gpr_addr_t'(5), rd_we:1, default:'0};
        tick();
        recovery = '{valid:1, id:tag(2), pc:xlen_t'(64)};
        branch_resolved = 1; resolved_id = tag(2); tick();
        writer(0, 4, 0, 5, 6); expect_source(0, 0, 0, 0); expect_source(0, 1, 2);
        alloc_fire = 1; tick();
        writer(0, 5, 7, 0, 6); expect_source(0, 0, 0, 0);
        // 错代次退休不能删除当前映射。
        retire[0] = '{valid:1, id:tag(2, 2), rd:gpr_addr_t'(6), rd_we:1, default:'0};
        expect_source(0, 1, 2); tick();
        // 同沿老版本退休与新版本分配，下一组读到新版本。
        retire[0] = '{valid:1, id:tag(2), rd:gpr_addr_t'(6), rd_we:1, default:'0};
        writer(0, 6, 6, 6, 0); alloc_fire = 1; expect_source(0, 0, 0, 0); tick();
        writer(0, 7, 7, 6, 0); expect_source(0, 0, 6); tick();
        flush = 1; tick(); flush = 0;
        writer(0, 0, 1, 6, 5); expect_source(0, 0, 0, 0); expect_source(0, 1, 0, 0); idle();
        // 耗尽所有 checkpoint 后反压；正确解析释放一项，可同沿重用。
        for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
            writer(0, cp, cp + 1, 0, 0, 1);
            #1; assert (checkpoint_ready) else $fatal(1, "checkpoint early full");
            alloc_fire = 1; tick();
        end
        writer(0, BRANCH_CHECKPOINTS, 10, 0, 0, 1);
        #1; assert (!checkpoint_ready) else $fatal(1, "checkpoint missing backpressure");
        branch_resolved = 1; resolved_id = tag(0);
        #1; assert (checkpoint_ready) else $fatal(1, "checkpoint not reusable");
        alloc_fire = 1; tick();
        $display("PASS tb_scoreboard_rename XLEN=%0d same_group retirement recovery checkpoint_full", XLEN);
        $finish;
    end
endmodule
