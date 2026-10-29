// Module: rename_table
// Description: Maps architectural registers to full ROB tags and checkpoints speculative mappings.
module rename_table (
    input logic clk, rst, flush,
    input logic [1:0] alloc_fire,
    input pipeline_pkg::retire_alloc_t alloc_meta [2],
    input pipeline_pkg::retire_id_t alloc_id [2],
    input pipeline_pkg::d1_d2_t decode [2],
    input pipeline_pkg::retire_trace_t retire [2],
    output pipeline_pkg::gpr_dependency_t source [2][2],
    output logic checkpoint_ready,
    input logic branch_resolved,
    input pipeline_pkg::retire_id_t resolved_id,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;

    rename_entry_t map_q [GPR_NUM], map_d [GPR_NUM];
    rename_entry_t after_first [GPR_NUM], after_second [GPR_NUM];
    rename_entry_t checkpoint_q [BRANCH_CHECKPOINTS][GPR_NUM];
    branch_checkpoint_t owner_q [BRANCH_CHECKPOINTS];
    logic [BRANCH_CHECKPOINTS-1:0] free_checkpoint;
    logic [1:0] branch_alloc;
    integer free_first, free_second, recovery_slot;
    integer free_count, branch_count;

    // 退休只删除指向该完整 ID 的映射；更年轻同名写者继续保留。
    function automatic rename_entry_t prune(input rename_entry_t entry);
        rename_entry_t value;
        value = entry;
        for (int lane = 0; lane < 2; lane++) begin
            if (retire[lane].valid && retire[lane].rd_we && entry.mapped &&
                retire[lane].id == entry.id)
                value.mapped = 1'b0;
        end
        return value;
    endfunction

    // 先从寄存映射选中一个条目，再检查退休；同组 RAW 只旁路第一槽的新分配。
    // mapped 清零仍保留原 ID，与状态表的 prune 语义相同。
    function automatic gpr_dependency_t query_source(input gpr_addr_t rs, input logic second_lane);
        rename_entry_t value;
        value = prune(map_q[rs]);
        if (second_lane && alloc_fire[0] && alloc_meta[0].gpr_write &&
            alloc_meta[0].rd != '0 && alloc_meta[0].rd == rs)
            value = '{mapped:1'b1, id:alloc_id[0]};
        return '{pending:value.mapped, id:value.id};
    endfunction

    always_comb begin
        free_checkpoint = '0;
        free_first = -1;
        free_second = -1;
        free_count = 0;
        recovery_slot = -1;
        for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
            free_checkpoint[cp] = !owner_q[cp].valid ||
                (branch_resolved && owner_q[cp].id == resolved_id);
            if (free_checkpoint[cp]) begin
                if (free_first < 0) free_first = cp;
                else if (free_second < 0) free_second = cp;
                free_count++;
            end
            if (owner_q[cp].valid && owner_q[cp].id == recovery.id)
                recovery_slot = cp;
        end
        branch_count = 0;
        for (int lane = 0; lane < 2; lane++) begin
            if (decode[lane].valid && !decode[lane].exc.valid &&
                decode[lane].uop.branch_op != BR_NONE)
                branch_count++;
            branch_alloc[lane] = alloc_fire[lane] && alloc_meta[lane].kind == RET_BRANCH &&
                                 !decode[lane].exc.valid;
        end
        checkpoint_ready = free_count >= branch_count;
    end

    // 查询不经过下一状态宽数组；使用前仍保留 valid、异常、used 与 x0 门控。
    always_comb begin
        for (int lane = 0; lane < 2; lane++) begin
            source[lane][0] = '0;
            source[lane][1] = '0;
            if (decode[lane].valid && !decode[lane].exc.valid) begin
                if (decode[lane].uop.rs1_used && decode[lane].rs1 != '0)
                    source[lane][0] = query_source(decode[lane].rs1, lane == 1);
                if (decode[lane].uop.rs2_used && decode[lane].rs2 != '0)
                    source[lane][1] = query_source(decode[lane].rs2, lane == 1);
            end
        end
    end

    // 映射更新按程序年龄展开；checkpoint 继续保留两槽各自写入后的视图。
    always_comb begin
        for (int regno = 0; regno < GPR_NUM; regno++) begin
            map_d[regno] = prune(map_q[regno]);
            after_first[regno] = prune(map_q[regno]);
            after_second[regno] = prune(map_q[regno]);
        end
        for (int lane = 0; lane < 2; lane++) begin
            if (alloc_fire[lane] && alloc_meta[lane].gpr_write && alloc_meta[lane].rd != '0)
                map_d[alloc_meta[lane].rd] = '{mapped:1'b1, id:alloc_id[lane]};
            for (int regno = 0; regno < GPR_NUM; regno++) begin
                if (lane == 0) after_first[regno] = map_d[regno];
                else after_second[regno] = map_d[regno];
            end
        end
    end

    // checkpoint 在分支自身目的映射写入后保存；恢复同步清除已退休的老映射。
    // 不复位无效 checkpoint 的宽数据，只复位 owner.valid。
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for (int regno = 0; regno < GPR_NUM; regno++) map_q[regno] <= '0;
            for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) owner_q[cp].valid <= 1'b0;
        end else if (recovery.valid) begin
            for (int regno = 0; regno < GPR_NUM; regno++)
                if (recovery_slot >= 0)
                    map_q[regno] <= prune(checkpoint_q[recovery_slot][regno]);
            for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
                if (owner_q[cp].valid && (owner_q[cp].id == recovery.id ||
                    younger_than(owner_q[cp].id, recovery.id, head_slot)))
                    owner_q[cp].valid <= 1'b0;
                for (int regno = 0; regno < GPR_NUM; regno++)
                    checkpoint_q[cp][regno] <= prune(checkpoint_q[cp][regno]);
            end
        end else begin
            for (int regno = 0; regno < GPR_NUM; regno++) map_q[regno] <= map_d[regno];
            for (int cp = 0; cp < BRANCH_CHECKPOINTS; cp++) begin
                if (branch_resolved && owner_q[cp].id == resolved_id)
                    owner_q[cp].valid <= 1'b0;
                for (int regno = 0; regno < GPR_NUM; regno++)
                    checkpoint_q[cp][regno] <= prune(checkpoint_q[cp][regno]);
                if (branch_alloc[0] && cp == free_first) begin
                    owner_q[cp] <= '{valid:1'b1, id:alloc_id[0]};
                    for (int regno = 0; regno < GPR_NUM; regno++)
                        checkpoint_q[cp][regno] <= after_first[regno];
                end
                if (branch_alloc[1] && cp == (branch_alloc[0] ? free_second : free_first)) begin
                    owner_q[cp] <= '{valid:1'b1, id:alloc_id[1]};
                    for (int regno = 0; regno < GPR_NUM; regno++)
                        checkpoint_q[cp][regno] <= after_second[regno];
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && !flush) begin
        assert (!alloc_fire[1] || alloc_fire[0]) else $fatal(1, "RAT non-prefix allocation");
        assert (!(recovery.valid && (|alloc_fire))) else $fatal(1, "RAT allocation during recovery");
        assert (!recovery.valid || recovery_slot >= 0) else $fatal(1, "RAT missing branch checkpoint");
        assert (!(|branch_alloc) || checkpoint_ready) else $fatal(1, "RAT checkpoint overflow");
        assert (!map_q[0].mapped) else $fatal(1, "RAT renamed x0");
    end
`endif
endmodule
