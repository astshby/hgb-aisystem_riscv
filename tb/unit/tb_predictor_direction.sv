// Module: tb_predictor_direction
// Description: Independently models delayed local/chooser training and read-first queries.
module tb_predictor_direction #(
    parameter int unsigned LHT_ENTRIES = 64,
    parameter int unsigned HISTORY_W = 8,
    parameter int unsigned CHOOSER_ENTRIES = 32
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    localparam int PHT_SIZE = 1 << HISTORY_W;
    localparam int CHOICE_W = $clog2(CHOOSER_ENTRIES);
    logic clk = 0, rst = 1;
    xlen_t lookup_pc, update_pc;
    logic lookup_taken, update_valid, update_taken, choose_local;
    logic [HISTORY_W-1:0] lookup_idx, update_idx;
    logic [CHOICE_W-1:0] choice_lookup_idx, choice_update_idx;
    logic update_local_taken, update_global_taken;
    local_history #(.LHT_ENTRIES(LHT_ENTRIES), .HISTORY_W(HISTORY_W)) local_dut (
        .lookup_pc_1('0), .lookup_taken_1(), .lookup_idx_1(), .*);
    chooser #(.ENTRIES(CHOOSER_ENTRIES)) chooser_dut (
        .clk, .rst, .lookup_pc, .choose_local, .lookup_idx(choice_lookup_idx),
        .update_valid, .update_idx(choice_update_idx), .update_local_taken,
        .update_global_taken, .update_taken
    );
    always #5 clk = ~clk;

    int histories [LHT_ENTRIES], patterns [PHT_SIZE], choices [CHOOSER_ENTRIES];
    typedef struct packed {
        xlen_t pc;
        logic [HISTORY_W-1:0] local_idx;
        logic [CHOICE_W-1:0] choice_idx;
        logic local_taken, global_taken;
    } saved_t;
    saved_t saved [16];
    int cycles = 0, checks = 0, stale = 0, agreements = 0, disagreements = 0;
    int local_read_first = 0, choice_read_first = 0, saturated = 0, aliases = 0;
    logic [31:0] random_q = 32'h134721ab;

    function automatic int saturate(input int old_value, input bit taken);
        if (taken) return old_value < 3 ? old_value + 1 : 3;
        return old_value > 0 ? old_value - 1 : 0;
    endfunction

    task automatic check_lookup();
        int h, p, c;
        h = int'(lookup_pc >> 2) & (LHT_ENTRIES-1);
        p = histories[h]; c = int'(lookup_pc >> 2) & (CHOOSER_ENTRIES-1);
        assert (int'(lookup_idx) == p && lookup_taken == (patterns[p] >= 2))
            else $fatal(1, "local read-first cycle=%0d idx=%0d expected=%0d", cycles, lookup_idx, p);
        assert (int'(choice_lookup_idx) == c && choose_local == (choices[c] >= 2))
            else $fatal(1, "chooser read-first cycle=%0d", cycles);
        checks++;
    endtask

    // 沿前模型不包含当前训练；检查沿后则先更新独立模型，再检查所有查询输出。
    task automatic tick();
        int h, p, c, next_p, next_c;
        bit train_choice;
        #1;
        if (cycles != 0) begin
            check_lookup();
            h = int'(lookup_pc >> 2) & (LHT_ENTRIES-1);
            p = histories[h]; c = int'(lookup_pc >> 2) & (CHOOSER_ENTRIES-1);
            next_p = saturate(patterns[int'(update_idx)], update_taken);
            next_c = saturate(choices[int'(choice_update_idx)], update_local_taken == update_taken);
            train_choice = update_valid && update_local_taken != update_global_taken;
            if (!rst && update_valid) begin
                if (p == int'(update_idx) && (patterns[p] >= 2) != (next_p >= 2)) local_read_first++;
                if (train_choice && c == int'(choice_update_idx) && (choices[c] >= 2) != (next_c >= 2)) choice_read_first++;
                if (next_p == patterns[int'(update_idx)]) saturated++;
                if (int'(update_idx) != histories[int'(update_pc >> 2) & (LHT_ENTRIES-1)]) stale++;
                if ((lookup_pc != update_pc) &&
                    ((int'(lookup_pc >> 2) & (LHT_ENTRIES-1)) == (int'(update_pc >> 2) & (LHT_ENTRIES-1)))) aliases++;
                if (train_choice) disagreements++;
                else agreements++;
            end
        end
        @(posedge clk);
        if (rst) begin
            foreach (histories[i]) histories[i] = 0;
            foreach (patterns[i]) patterns[i] = 1;
            foreach (choices[i]) choices[i] = 1;
        end else if (update_valid) begin
            h = int'(update_pc >> 2) & (LHT_ENTRIES-1);
            histories[h] = ((histories[h] << 1) | int'(update_taken)) & (PHT_SIZE-1);
            patterns[int'(update_idx)] = saturate(patterns[int'(update_idx)], update_taken);
            if (update_local_taken != update_global_taken)
                choices[int'(choice_update_idx)] = saturate(choices[int'(choice_update_idx)], update_local_taken == update_taken);
        end
        cycles++;
        #1; check_lookup();
        @(negedge clk);
    endtask

    initial begin
        saved_t next_snapshot;
        int h, c;
        lookup_pc = '0; update_pc = '0; update_idx = '0; choice_update_idx = '0;
        update_valid = 0; update_taken = 0; update_local_taken = 0; update_global_taken = 0;
        foreach (saved[i]) saved[i] = '0;
        @(negedge clk); tick(); rst = 0;

        // 查询 PC=0 保持历史零，训练另一 LHT 行的旧 PHT[0] 快照。
        // 上升/下降穿越阈值直接暴露不允许的训练旁路；连续同值覆盖饱和。
        update_valid = 1; update_pc = xlen_t'(4); update_idx = '0; choice_update_idx = '0;
        update_local_taken = 1; update_global_taken = 0;
        for (int pass = 0; pass < 4; pass++) begin
            update_taken = !pass[0];
            repeat (6) tick();
        end
        // 两候选一致时保持 chooser，即使候选都预测错误也不改变偏好。
        update_local_taken = 1; update_global_taken = 1; update_taken = 0;
        repeat (6) tick();
        // 不同 PC 别名到同一 LHT，历史在当前状态上追加，不回滚到旧索引。
        lookup_pc = xlen_t'(4); update_pc = xlen_t'(4 + 4*LHT_ENTRIES);
        update_idx = '0; update_taken = 1;
        repeat (HISTORY_W + 3) tick();

        // 两轮确定性延迟快照，第二轮复位确保所有表状态重新初始化。
        for (int epoch = 0; epoch < 2; epoch++) begin
            rst = 1; update_valid = 0; tick(); rst = 0;
            foreach (saved[i]) saved[i] = '0;
            for (int step = 0; step < 4096; step++) begin
                random_q ^= random_q << 13; random_q ^= random_q >> 17; random_q ^= random_q << 5;
                lookup_pc = xlen_t'(int'(random_q[15:8]) * 4);
                update_pc = saved[step % 16].pc;
                update_idx = saved[step % 16].local_idx;
                choice_update_idx = saved[step % 16].choice_idx;
                update_local_taken = saved[step % 16].local_taken;
                update_global_taken = saved[step % 16].global_taken;
                update_valid = step >= 16 && random_q[0]; update_taken = random_q[1];
                h = int'(lookup_pc >> 2) & (LHT_ENTRIES-1);
                c = int'(lookup_pc >> 2) & (CHOOSER_ENTRIES-1);
                // 参考快照来自模型，不回读 DUT 输出作为后续训练的正确性依据。
                next_snapshot = '{pc:lookup_pc, local_idx:HISTORY_W'(histories[h]),
                    choice_idx:CHOICE_W'(c), local_taken:(patterns[histories[h]] >= 2), global_taken:random_q[2]};
                tick(); saved[step % 16] = next_snapshot;
            end
        end
        // 只通过查询接口遍历各 LHT；chooser 独立 PC 索引也全部读到。
        update_valid = 0;
        for (int i = 0; i < LHT_ENTRIES + CHOOSER_ENTRIES; i++) begin
            lookup_pc = xlen_t'(i*4); tick();
        end
        assert (stale > 100 && agreements > 100 && disagreements > 100 && saturated > 100 &&
                local_read_first >= 4 && choice_read_first >= 4 && aliases >= HISTORY_W + 3)
            else $fatal(1, "insufficient direction coverage stale=%0d local_rf=%0d choice_rf=%0d", stale, local_read_first, choice_read_first);
        $display("PASS tb_predictor_direction RV%0d lht=%0d history=%0d lpht=%0d chooser=%0d checks=%0d cycles=%0d stale=%0d agree=%0d disagree=%0d local_rf=%0d choice_rf=%0d saturated=%0d aliases=%0d",
            XLEN, LHT_ENTRIES, HISTORY_W, PHT_SIZE, CHOOSER_ENTRIES, checks, cycles,
            stale, agreements, disagreements, local_read_first, choice_read_first, saturated, aliases);
        $finish;
    end
    initial begin #1000000; $fatal(1, "direction watchdog"); end
endmodule
