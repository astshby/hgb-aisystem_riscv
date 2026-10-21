// Module: tb_completion_arbiter
// Description: Checks WB priority, stable locked completions, same-edge handshakes, and coordinated flush.
module tb_completion_arbiter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    logic clk = 1'b0, rst, flush;
    logic wb_valid, wb_ready, lsu_valid, lsu_ready, mdu_valid, mdu_ready, complete_valid, complete_ready;
    retire_completion_t wb_completion, lsu_completion, mdu_completion, completion;
    logic model_locked = 1'b0;
    int model_source = 0;
    logic held_previous = 1'b0;
    retire_completion_t held_packet;
    int checks = 0, wb_fires = 0, lsu_fires = 0, mdu_fires = 0;
    int stable_checks = 0;

    always #5 clk = ~clk;
    completion_arbiter dut (.*);

    // 另存上拍反压包，不借用当前源载荷；即使驱动源误改数据也不能跟着参考一起变化。
    always @(posedge clk) begin
        if (rst)
            held_previous = 1'b0;
        else begin
            if (held_previous) begin
                assert (complete_valid && completion == held_packet)
                    else $fatal(1, "stalled completion changed across cycles");
                stable_checks++;
            end
            held_previous = complete_valid && !complete_ready && !flush;
            if (held_previous) held_packet = completion;
        end
    end

    // 独立参考只保存被反压时的源身份；载荷直接与该源的原始包逐位比较。
    task automatic step;
        int selected;
        logic expected_valid;
        retire_completion_t expected_packet;
        selected = model_locked ? model_source : (wb_valid ? 0 : (lsu_valid ? 1 : 2));
        expected_valid = !rst && (selected == 0 ? wb_valid : (selected == 1 ? lsu_valid : mdu_valid));
        expected_packet = selected == 0 ? wb_completion : (selected == 1 ? lsu_completion : mdu_completion);
        #1;
        assert (complete_valid == expected_valid &&
                wb_ready == (!rst && selected == 0 && complete_ready) &&
                lsu_ready == (!rst && selected == 1 && complete_ready) &&
                mdu_ready == (!rst && selected == 2 && complete_ready))
            else $fatal(1, "completion arbitration/ready mismatch");
        assert (completion == (expected_valid ? expected_packet : '0))
            else $fatal(1, "completion payload changed source");
        assert (int'(wb_valid && wb_ready) + int'(lsu_valid && lsu_ready) + int'(mdu_valid && mdu_ready) ==
                int'(complete_valid && complete_ready))
            else $fatal(1, "completion endpoint fires differ");
        if (wb_valid && wb_ready) wb_fires++;
        if (lsu_valid && lsu_ready) lsu_fires++;
        if (mdu_valid && mdu_ready) mdu_fires++;
        @(posedge clk);
        if (rst || flush)
            model_locked = 1'b0;
        else if (expected_valid) begin
            model_locked = !complete_ready;
            model_source = selected;
        end
        @(negedge clk);
        checks++;
    endtask
    task automatic reset_case;
        rst = 1'b1;
        flush = 1'b0;
        wb_valid = 1'b0;
        lsu_valid = 1'b0;
        mdu_valid = 1'b0;
        complete_ready = 1'b0;
        step();
        rst = 1'b0;
    endtask

    initial begin
        wb_completion = '1;
        wb_completion.id = retire_id_t'(1);
        wb_completion.result.gpr_data = xlen_t'(64'h9876_5432_1122_3344);
        mdu_completion = '0;
        mdu_completion.id = retire_id_t'(2);
        mdu_completion.result.gpr_data = xlen_t'(64'h8765_4321_aabb_ccdd);
        lsu_completion = '0;
        lsu_completion.id = retire_id_t'(3);
        lsu_completion.result.gpr_data = xlen_t'(64'h1234_5678_eeff_aa55);
        @(negedge clk);
        for (int pattern = 0; pattern < 16; pattern++) begin
            reset_case();
            {wb_valid, lsu_valid, mdu_valid, complete_ready} = 4'(pattern);
            step();
        end

        // MDU 先被反压锁住，随后 WB 不能抢包；MDU 接纳后次拍才轮到 WB。
        reset_case();
        mdu_valid = 1'b1;
        step();
        wb_valid = 1'b1;
        repeat (17) step();
        complete_ready = 1'b1;
        step();
        mdu_valid = 1'b0;
        step();
        wb_valid = 1'b0;
        step();

        // WB 锁定与无反压连续 WB 优先均不增加结果级，MDU 等自己的 ready。
        reset_case();
        wb_valid = 1'b1;
        mdu_valid = 1'b1;
        repeat (5) step();
        complete_ready = 1'b1;
        for (int serial = 0; serial < 24; serial++) begin
            step();
            wb_completion.result.gpr_data += xlen_t'(1);
        end
        wb_valid = 1'b0;
        step();
        mdu_valid = 1'b0;
        step();

        // LSU 先锁定；随后到达的 WB 不能抢包，MDU 也必须等 LSU 交付。
        reset_case();
        lsu_valid = 1'b1;
        step();
        wb_valid = 1'b1;
        mdu_valid = 1'b1;
        repeat (9) step();
        complete_ready = 1'b1;
        step();
        lsu_valid = 1'b0;
        step();
        wb_valid = 1'b0;
        step();
        mdu_valid = 1'b0;
        step();

        // 取消不是组合撤销：本拍仍展示锁定包，沿上同时清锁、源和接收队列。
        for (int source = 0; source < 3; source++) begin
            for (int ready_at_flush = 0; ready_at_flush < 2; ready_at_flush++) begin
                reset_case();
                wb_valid = source == 0;
                lsu_valid = source == 1;
                mdu_valid = source == 2;
                step();
                wb_valid = 1'b1;
                lsu_valid = 1'b1;
                mdu_valid = 1'b1;
                flush = 1'b1;
                complete_ready = 1'(ready_at_flush);
                step();
                flush = 1'b0;
                lsu_valid = 1'b0;
                mdu_valid = 1'b0;
                complete_ready = 1'b1;
                step();
                wb_valid = 1'b0;
                step();
            end
        end
        assert (wb_fires >= 26 && lsu_fires >= 3 && mdu_fires >= 3 && stable_checks >= 29)
            else $fatal(1, "arbiter coverage missing");
        $display("PASS tb_completion_arbiter RV%0d checks=%0d wb_fires=%0d lsu_fires=%0d mdu_fires=%0d stable=%0d",
                 XLEN, checks, wb_fires, lsu_fires, mdu_fires, stable_checks);
        $finish;
    end
endmodule
