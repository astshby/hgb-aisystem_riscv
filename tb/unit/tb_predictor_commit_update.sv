// Module: tb_predictor_commit_update
// Description: Checks retirement-only training qualification, saved context, and actual branch results.
module tb_predictor_commit_update;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic retire_fire = 1'b0;
    retire_alloc_t head_meta;
    retire_result_t head_result;
    pred_update_t update;
    logic count_serial = 1'b0;
    int serial_updates = 0;
    int truth_checks = 0;
    xlen_t previous_pc;

    always #5 clk = ~clk;
    // 没有 redirect 端口：正常退休的训练不等待前端恢复许可。
    // 整核同拍退休与重定向的连接仍由 Core 定向测试覆盖，而非在此伪造恢复输入。
    predictor_commit_update dut (.retire_fire, .head_meta, .head_result, .update);

    task automatic check_update(input logic expected_valid);
        assert (update.valid == expected_valid)
            else $fatal(1, "training qualification retire=%0b exception=%0b kind=%0d",
                        retire_fire, head_result.exc.valid, head_meta.kind);
        if (expected_valid) begin
            assert (update.kind == head_meta.branch_kind && update.pc == head_meta.pc &&
                    update.train == head_meta.pred_train &&
                    update.taken == head_result.branch.taken && update.target == head_result.branch.target &&
                    update.ras_op == head_meta.ras_op)
                else $fatal(1, "retirement training lost saved context or actual outcome");
        end
    endtask

    // 接收端按上升沿计数；连续合法退休不应增加空拍，也不能复用上一个分支的负载。
    always @(posedge clk) begin
        if (count_serial && update.valid) begin
            assert (retire_fire && !head_result.exc.valid && head_meta.kind == RET_BRANCH)
                else $fatal(1, "training event without a normal branch retirement");
            assert (serial_updates == 0 || update.pc != previous_pc)
                else $fatal(1, "successive retirements reused a stale training packet");
            previous_pc = update.pc;
            serial_updates++;
        end
    end

    initial begin
        head_meta = '0;
        head_result = '0;
        previous_pc = '0;
        // 穷举退休、异常和七类指令；非分支即使带着分支形状的旧数据也不得训练。
        for (int flags = 0; flags < 4; flags++) begin
            for (int kind = 0; kind < 7; kind++) begin
                for (int branch_kind = 1; branch_kind <= 8; branch_kind++) begin
                    for (int taken = 0; taken < 2; taken++) begin
                        @(negedge clk);
                        retire_fire = flags[0];
                        head_meta = '0;
                        head_result = '0;
                        head_meta.kind = retire_kind_e'(kind);
                        head_meta.branch_kind = branch_op_e'(branch_kind);
                        head_meta.pc = xlen_t'(64'habcd_1234_8000_0100) + xlen_t'(branch_kind * 4);
                        head_meta.seq_pc = head_meta.pc + xlen_t'(4);
                        head_meta.pred_train.pht_idx = PHT_IDX_W'(truth_checks);
                        head_meta.pred_train.local_idx = LOCAL_HISTORY_W'(truth_checks * 7);
                        head_meta.pred_train.chooser_idx = CHOOSER_IDX_W'(truth_checks * 3);
                        head_meta.pred_train.global_taken = truth_checks[0];
                        head_meta.pred_train.local_taken = truth_checks[1];
                        head_meta.pred_train.choose_local = truth_checks[2];
                        head_meta.ras_op = predictor_types_pkg::ras_op_e'(truth_checks % 4);
                        head_result.exc = '{valid:flags[1], cause:EXC_INST_ADDR_MISALIGNED, tval:xlen_t'(3)};
                        head_result.branch = '{taken:1'(taken), target:xlen_t'(64'hfedc_ba98_8000_1234)};
                        head_result.next_pc = taken != 0 ? head_result.branch.target : head_meta.seq_pc;
                        #1;
                        check_update(flags[0] && !flags[1] && kind == int'(RET_BRANCH));
                        truth_checks++;
                    end
                end
            end
        end

        // 相同目标和相同 next_pc 仍有两种真实方向；训练只能相信保存的 branch.taken。
        for (int taken = 0; taken < 2; taken++) begin
            @(negedge clk);
            retire_fire = 1'b1;
            head_meta = '0;
            head_result = '0;
            head_meta.kind = RET_BRANCH;
            head_meta.branch_kind = BR_EQ;
            head_meta.pc = xlen_t'(64'h9876_5432_8000_2000);
            head_meta.seq_pc = head_meta.pc + xlen_t'(4);
            head_meta.pred_train.pht_idx = '1;
            head_result.next_pc = head_meta.seq_pc;
            head_result.branch = '{taken:1'(taken), target:head_meta.seq_pc};
            #1;
            check_update(1'b1);
            assert (update.taken == 1'(taken) && update.target == head_meta.seq_pc)
                else $fatal(1, "sequential target was mistaken for not-taken");
        end

        // 退休停顿期间保存的合法包不能先训练；恢复退休后立即产生本拍事件。
        @(negedge clk);
        retire_fire = 1'b0;
        repeat (3) begin
            #1;
            check_update(1'b0);
            @(negedge clk);
        end
        count_serial = 1'b1;
        for (int instruction = 0; instruction < 12; instruction++) begin
            retire_fire = 1'b1;
            head_meta.pc = xlen_t'(64'h8123_4567_8000_4000) + xlen_t'(instruction * 4);
            head_meta.seq_pc = head_meta.pc + xlen_t'(4);
            head_meta.branch_kind = branch_op_e'(1 + instruction % 8);
            head_meta.pred_train.pht_idx = PHT_IDX_W'(instruction * 7);
            head_result.branch = '{
                taken:instruction[0] || head_meta.branch_kind == BR_JAL || head_meta.branch_kind == BR_JALR,
                target:head_meta.seq_pc
            };
            head_result.next_pc = head_meta.seq_pc;
            #1;
            check_update(1'b1);
            @(posedge clk);
            #1;
            assert (serial_updates == instruction + 1)
                else $fatal(1, "serial retirement dropped, duplicated, or delayed training");
            @(negedge clk);
        end
        retire_fire = 1'b0;
        repeat (3) begin
            #1;
            check_update(1'b0);
            @(posedge clk);
            #1;
            assert (serial_updates == 12) else $fatal(1, "training repeated after retirement stopped");
            @(negedge clk);
        end
        count_serial = 1'b0;
        $display("PASS tb_predictor_commit_update RV%0d truth_cases=%0d same_successor=2 serial=12", XLEN, truth_checks);
        $finish;
    end
endmodule
