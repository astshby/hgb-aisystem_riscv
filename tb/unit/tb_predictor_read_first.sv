// Module: tb_predictor_read_first
// Description: Checks the unchanged BTB64/GShare64 read-first boundary used by C4a comparisons.
module tb_predictor_read_first;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    logic clk = 0, rst = 1;
    xlen_t lookup_pc, btb_update_pc, btb_update_target, lookup_target;
    logic lookup_hit, lookup_taken, btb_update_valid, gshare_update_valid, update_taken;
    branch_op_e lookup_kind, update_kind;
    logic [BTB_IDX_W-1:0] btb_idx;
    logic [PHT_IDX_W-1:0] pht_idx, update_idx;
    btb btb_dut (
        .clk, .rst, .lookup_pc, .lookup_hit, .lookup_target, .lookup_kind, .lookup_idx(btb_idx),
        .update_valid(btb_update_valid), .update_pc(btb_update_pc),
        .update_target(btb_update_target), .update_kind
    );
    gshare gshare_dut (
        .clk, .rst, .lookup_pc, .lookup_taken, .lookup_idx(pht_idx),
        .update_valid(gshare_update_valid), .update_idx, .update_taken
    );
    always #5 clk = ~clk;
    bit tags_valid [BTB_ENTRIES];
    xlen_t tags [BTB_ENTRIES], targets [BTB_ENTRIES];
    branch_op_e kinds [BTB_ENTRIES];
    int patterns [PHT_ENTRIES], history = 0;
    int cycles = 0, checks = 0, target_conflicts = 0, direction_conflicts = 0;
    logic [31:0] random_q = 32'h9d39a761;

    function automatic int saturate(input int old_value, input bit taken);
        if (taken) return old_value < 3 ? old_value + 1 : 3;
        return old_value > 0 ? old_value - 1 : 0;
    endfunction

    task automatic check_lookup();
        int b, p;
        bit hit;
        b = int'(lookup_pc >> 2) & (BTB_ENTRIES-1);
        p = (int'(lookup_pc >> 2) ^ history) & (PHT_ENTRIES-1);
        hit = tags_valid[b] && tags[b] == lookup_pc;
        assert (int'(btb_idx) == b && lookup_hit == hit &&
                lookup_target == (hit ? targets[b] : xlen_t'(0)) &&
                lookup_kind == (hit ? kinds[b] : BR_NONE))
            else $fatal(1, "BTB read-first cycle=%0d pc=%h", cycles, lookup_pc);
        assert (int'(pht_idx) == p && lookup_taken == (patterns[p] >= 2))
            else $fatal(1, "GShare read-first cycle=%0d", cycles);
        checks++;
    endtask

    task automatic tick();
        int b, p;
        #1;
        if (cycles != 0) begin
            check_lookup();
            b = int'(lookup_pc >> 2) & (BTB_ENTRIES-1);
            p = (int'(lookup_pc >> 2) ^ history) & (PHT_ENTRIES-1);
            if (!rst && btb_update_valid && b == (int'(btb_update_pc >> 2) & (BTB_ENTRIES-1)))
                target_conflicts++;
            if (!rst && gshare_update_valid && p == int'(update_idx) &&
                (patterns[p] >= 2) != (saturate(patterns[p], update_taken) >= 2)) direction_conflicts++;
        end
        @(posedge clk);
        if (rst) begin
            foreach (tags_valid[i]) tags_valid[i] = 0;
            foreach (patterns[i]) patterns[i] = 1;
            history = 0;
        end else begin
            if (btb_update_valid) begin
                b = int'(btb_update_pc >> 2) & (BTB_ENTRIES-1);
                tags_valid[b] = 1; tags[b] = btb_update_pc;
                targets[b] = btb_update_target; kinds[b] = update_kind;
            end
            if (gshare_update_valid) begin
                patterns[int'(update_idx)] = saturate(patterns[int'(update_idx)], update_taken);
                history = ((history << 1) | int'(update_taken)) & ((1 << GHR_W)-1);
            end
        end
        cycles++;
        #1; check_lookup();
        @(negedge clk);
    endtask

    initial begin
        assert (BTB_ENTRIES == 64 && PHT_ENTRIES == 64 && GHR_W == 6)
            else $fatal(1, "C4a comparison requires BTB64/PHT64/GHR6");
        lookup_pc = '0; btb_update_pc = '0; btb_update_target = '0;
        btb_update_valid = 0; gshare_update_valid = 0; update_idx = '0;
        update_taken = 0; update_kind = BR_NONE;
        @(negedge clk); tick(); rst = 0;
        // BTB 同 PC 更新、同索引异标签替换以及 RV64 完整高位标签。
        btb_update_valid = 1; update_kind = BR_JAL;
        btb_update_target = xlen_t'(64'hf1234567_80000040); tick();
        btb_update_target = xlen_t'(64'hf1234567_80000080); tick();
        btb_update_pc = xlen_t'(BTB_ENTRIES*4); tick();
        btb_update_pc = xlen_t'(64'h12345678_00000000);
        lookup_pc = btb_update_pc; tick();
        btb_update_valid = 0;
        // 查询 PC 按模型 GHR 选择 PHT[0]，反复跨越方向阈值。
        gshare_update_valid = 1; update_idx = '0;
        for (int i = 0; i < 20; i++) begin
            lookup_pc = xlen_t'(history*4); update_taken = !i[0]; tick();
        end
        for (int i = 0; i < 2048; i++) begin
            random_q ^= random_q << 13; random_q ^= random_q >> 17; random_q ^= random_q << 5;
            lookup_pc = xlen_t'(int'(random_q[15:8])*4);
            btb_update_pc = xlen_t'(int'(random_q[23:16])*4);
            btb_update_target = xlen_t'({random_q, random_q ^ 32'hcafef00d});
            btb_update_valid = random_q[0]; gshare_update_valid = random_q[1];
            update_kind = random_q[2] ? BR_JALR : BR_EQ;
            update_idx = PHT_IDX_W'(random_q[29:24]); update_taken = random_q[3];
            rst = i == 1000; tick();
        end
        rst = 0; btb_update_valid = 0; gshare_update_valid = 0;
        for (int i = 0; i < BTB_ENTRIES; i++) begin lookup_pc = xlen_t'(i*4); tick(); end
        assert (target_conflicts >= 4 && direction_conflicts >= 20)
            else $fatal(1, "insufficient read-first conflict coverage");
        $display("PASS tb_predictor_read_first RV%0d btb=%0d pht=%0d ghr=%0d checks=%0d cycles=%0d target_conflicts=%0d direction_conflicts=%0d",
            XLEN, BTB_ENTRIES, PHT_ENTRIES, GHR_W, checks, cycles, target_conflicts, direction_conflicts);
        $finish;
    end
    initial begin #1000000; $fatal(1, "read-first watchdog"); end
endmodule
