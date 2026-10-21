// Module: tb_mdu_completion_adapter
// Description: Checks tagged MDU completions, arbitration holds, and ordered retirement with cancellation.
module tb_mdu_completion_adapter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic manual_cancel, cancel, req_valid, req_ready;
    muldiv_req_t request;
    retire_id_t request_id;
    logic mdu_valid, mdu_ready, wb_valid, wb_ready, complete_valid, complete_ready;
    retire_completion_t mdu_completion, wb_completion, completion;
    logic use_queue, manual_ready, manual_flush, auto_trap_flush, queue_flush;
    logic alloc_valid, alloc_ready, queue_ready, complete_reject;
    retire_alloc_t alloc_meta, head_meta;
    retire_id_t alloc_id, head_id;
    retire_result_t head_result;
    logic head_valid, head_complete, retire_ready, retire_fire, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;

    typedef struct packed {
        retire_id_t id;
        retire_alloc_t meta;
        retire_result_t result;
        logic done;
    } model_entry_t;
    model_entry_t queue_model[$];
    model_entry_t entry, removed;
    logic mdu_live;
    retire_id_t expected_id;
    xlen_t expected_data, launch_expected;
    int checks = 0, delivered = 0, rejected = 0, retired = 0;
    int completed_before_head = 0, cancelled_deliveries = 0;
    int collisions = 0, held_cycles = 0;
    logic mdu_held_previous = 1'b0, output_held_previous = 1'b0;
    retire_completion_t held_mdu, held_output;
    int stable_checks = 0, request_blocked_cycles = 0;

    always #5 clk = ~clk;
    assign queue_flush = manual_flush || (auto_trap_flush && retire_fire && head_result.exc.valid);
    assign cancel = manual_cancel || queue_flush;
    assign complete_ready = use_queue ? queue_ready : manual_ready;
    mdu_completion_adapter dut (
        .clk, .rst, .cancel, .req_valid, .req_ready, .request, .request_id,
        .completion_valid(mdu_valid), .completion_ready(mdu_ready), .completion(mdu_completion)
    );
    completion_arbiter u_arbiter (
        .clk, .rst, .flush(cancel), .wb_valid, .wb_ready, .wb_completion,
        .lsu_valid(1'b0), .lsu_ready(), .lsu_completion('0),
        .mdu_valid, .mdu_ready, .mdu_completion, .complete_valid, .complete_ready, .completion
    );
    retire_queue u_queue (
        .ras_entries(), .ras_head_slot(),
        .clk, .rst, .flush_all(queue_flush), .drain_complete(req_ready && !wb_valid),
        .alloc_valid, .alloc_ready, .alloc_meta, .alloc_id,
        .complete_valid(use_queue && complete_valid), .complete_ready(queue_ready), .completion,
        .complete_reject, .head_valid, .head_complete, .head_id, .head_meta, .head_result,
        .query('0), .query_result(),
        .retire_ready, .retire_fire, .occupancy, .recovering
    );

    // 跨拍快照同时检查源和合并出口；取消仅在沿上解除持包，不放宽取消当拍的稳定性。
    always @(posedge clk) begin
        if (rst) begin
            mdu_held_previous = 1'b0;
            output_held_previous = 1'b0;
        end else begin
            if (mdu_held_previous) begin
                assert (mdu_valid && mdu_completion == held_mdu)
                    else $fatal(1, "MDU completion changed while held");
                stable_checks++;
            end
            if (output_held_previous) begin
                assert (complete_valid && completion == held_output)
                    else $fatal(1, "merged completion changed while held");
                stable_checks++;
            end
            mdu_held_previous = mdu_valid && !mdu_ready && !cancel;
            output_held_previous = complete_valid && !complete_ready && !cancel;
            if (mdu_held_previous) held_mdu = mdu_completion;
            if (output_held_previous) held_output = completion;
            if (req_valid && !req_ready) request_blocked_cycles++;
        end
    end

    // 每个真实请求只产生一份 ID/算术参考；请求总线之后变化不能改写在途结果。
    // 取消沿可以同时有完成交付，是否保留交给队列年龄/flush；适配器不猜测指令生死。
    always @(posedge clk) begin
        if (rst) begin
            mdu_live = 1'b0;
            expected_id = '0;
            expected_data = '0;
        end else begin
            assert (mdu_valid == dut.u_muldiv_unit.result_available)
                else $fatal(1, "adapter inserted a result delay or combinational cancel mask");
            if (mdu_valid) begin
                retire_completion_t expected;
                expected = '0;
                expected.id = expected_id;
                expected.result.gpr_data = expected_data;
                assert (mdu_live && mdu_completion == expected)
                    else $fatal(1, "MDU ID/canonical payload mismatch got=%h expected=%h", mdu_completion, expected);
                if (!mdu_ready) held_cycles++;
            end
            if (wb_valid && mdu_valid) collisions++;
            if (mdu_valid && mdu_ready) begin
                delivered++;
                if (cancel) cancelled_deliveries++;
                mdu_live = 1'b0;
            end
            if (cancel) mdu_live = 1'b0;
            if (req_valid && req_ready) begin
                assert (!mdu_live && !mdu_valid && !cancel) else $fatal(1, "MDU accepted overlapping work");
                mdu_live = 1'b1;
                expected_id = request_id;
                expected_data = launch_expected;
            end
        end
    end

    // 微型退休参考按接纳顺序保存指令，不用 DUT 槽数组/指针判断年龄。
    // 完成按 ID 搜索，可以先完成年轻指令，但只能弹出完整队头。
    always @(posedge clk) begin
        int match_index;
        logic matching, bypass, expected_retire, expected_reject;
        retire_result_t normalized, expected_head;
        if (rst) begin
            queue_model.delete();
        end else if (use_queue) begin
            match_index = -1;
            foreach (queue_model[index])
                if (queue_model[index].id == completion.id) match_index = index;
            matching = match_index >= 0 && !queue_model[match_index].done;
            normalized = completion.result;
            if (matching && queue_model[match_index].meta.kind != RET_BRANCH)
                normalized.next_pc = queue_model[match_index].meta.seq_pc;
            bypass = complete_valid && complete_ready && matching && match_index == 0;
            expected_head = '0;
            if (queue_model.size() != 0)
                expected_head = bypass ? normalized : queue_model[0].result;
            expected_retire = queue_model.size() != 0 && (queue_model[0].done || bypass) && retire_ready;
            expected_reject = complete_valid && complete_ready &&
                              (!matching || (queue_flush && !(bypass && expected_retire)));
            assert (int'(occupancy) == queue_model.size() && head_valid == (queue_model.size() != 0))
                else $fatal(1, "retirement model occupancy mismatch");
            assert (retire_fire == expected_retire && complete_reject == expected_reject)
                else $fatal(1, "completion incorrectly became retirement or rejected a live ID");
            if (queue_model.size() != 0) begin
                assert (head_id == queue_model[0].id && head_meta == queue_model[0].meta)
                    else $fatal(1, "retirement metadata reordered");
                if (queue_model[0].done || bypass)
                    assert (head_result == expected_head) else $fatal(1, "retirement result/PC mismatch");
            end
            if (complete_reject) rejected++;
            if (retire_fire) retired++;
            if (complete_valid && complete_ready && matching && match_index > 0) completed_before_head++;
            if (queue_flush)
                queue_model.delete();
            else begin
                if (complete_valid && complete_ready && matching) begin
                    entry = queue_model[match_index];
                    entry.done = 1'b1;
                    entry.result = normalized;
                    queue_model[match_index] = entry;
                end
                if (expected_retire) removed = queue_model.pop_front();
                if (alloc_valid && alloc_ready) begin
                    entry = '0;
                    entry.id = alloc_id;
                    entry.meta = alloc_meta;
                    queue_model.push_back(entry);
                end
            end
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic reset_case(input logic queue_mode);
        rst = 1'b1;
        manual_cancel = 1'b0;
        manual_flush = 1'b0;
        auto_trap_flush = 1'b0;
        req_valid = 1'b0;
        wb_valid = 1'b0;
        manual_ready = 1'b0;
        use_queue = queue_mode;
        alloc_valid = 1'b0;
        retire_ready = 1'b0;
        tick();
        rst = 1'b0;
        tick();
        #1;
        assert (req_ready && !mdu_valid && !recovering) else $fatal(1, "completion reset/drain failed");
    endtask
    task automatic launch(input muldiv_op_e operation, input op_width_e width,
                          input xlen_t a, input xlen_t b, input xlen_t expected, input retire_id_t id);
        assert (req_ready && !mdu_valid) else $fatal(1, "launch while MDU occupied");
        request = '{operation:operation, op_width:width, operand_a:a, operand_b:b};
        request_id = id;
        launch_expected = expected;
        req_valid = 1'b1;
        tick();
        req_valid = 1'b0;
        request = '1;
        request_id = ~id;
    endtask
    task automatic await_result;
        int timeout_cycles;
        timeout_cycles = 0;
        #1;
        while (!mdu_valid) begin
            tick();
            timeout_cycles++;
            assert (timeout_cycles <= XLEN + 6) else $fatal(1, "tagged MDU completion timeout");
        end
    endtask
    task automatic consume_manual;
        manual_ready = 1'b1;
        tick();
        manual_ready = 1'b0;
        #1;
        assert (!mdu_valid && req_ready) else $fatal(1, "MDU result duplicated or not consumed");
        checks++;
    endtask
    task automatic allocate(input int pc, output retire_id_t id);
        alloc_meta = '0;
        alloc_meta.pc = xlen_t'(pc);
        alloc_meta.seq_pc = xlen_t'(pc + 4);
        alloc_meta.inst = 32'h0000_0013;
        alloc_meta.gpr_write = 1'b1;
        alloc_meta.rd = 5'd3;
        alloc_meta.kind = RET_EXEC;
        alloc_valid = 1'b1;
        #1;
        assert (alloc_ready) else $fatal(1, "micro harness allocation blocked");
        id = alloc_id;
        tick();
        alloc_valid = 1'b0;
    endtask
    task automatic send_wb(input retire_id_t id, input xlen_t data, input logic fault);
        wb_completion = '0;
        wb_completion.id = id;
        wb_completion.result.gpr_data = data;
        wb_completion.result.exc.valid = fault;
        wb_completion.result.exc.cause = EXC_LOAD_ACCESS_FAULT;
        wb_completion.result.exc.tval = xlen_t'(32'h1000_0040);
        wb_valid = 1'b1;
        #1;
        assert (wb_ready) else $fatal(1, "WB source unexpectedly blocked in queue harness");
        tick();
        wb_valid = 1'b0;
    endtask

    initial begin
        retire_id_t older, younger, stale;
        xlen_t value;
        int before_retire, before_reject;
        logic found_zero;
        request = '0;
        request_id = '0;
        wb_completion = '0;
        alloc_meta = '0;
        launch_expected = '0;
        @(negedge clk);
        reset_case(1'b0);
        // 八类 M 操作经过实际后端；协议压力不依赖某个乘除算法的固定等待拍数。
        for (int operation = 0; operation < 8; operation++) begin
            case (muldiv_op_e'(operation))
                MD_MUL: value = xlen_t'(21);
                MD_DIV, MD_DIVU: value = xlen_t'(2);
                MD_REM, MD_REMU: value = xlen_t'(1);
                default: value = '0;
            endcase
            launch(muldiv_op_e'(operation), OP_WIDTH_XLEN, xlen_t'(7), xlen_t'(3), value,
                   retire_id_t'(operation));
            await_result();
            repeat (5) begin
                tick();
                assert (!req_ready && mdu_valid) else $fatal(1, "held completion accepted new ID");
            end
            consume_manual();
        end
        // 特殊除法在请求沿写入原 RESULT，适配后下一拍就可交付，ID=0 不是非法标记。
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(99), '0, '1, '0);
        #1;
        assert (mdu_valid && mdu_completion.id == '0) else $fatal(1, "special division acquired extra cycle");
        consume_manual();
        value = xlen_t'(1) << (XLEN-1);
        launch(MD_DIV, OP_WIDTH_XLEN, value, '1, value, retire_id_t'(7));
        #1;
        assert (mdu_valid) else $fatal(1, "overflow division acquired extra cycle");
        consume_manual();
        if (XLEN == 64) begin
            launch(MD_MUL, OP_WIDTH_WORD, xlen_t'(64'hdead_beef_8000_0000), xlen_t'(3),
                   xlen_t'($signed(32'h8000_0000)), retire_id_t'(6));
            await_result();
            consume_manual();
            launch(MD_REMU, OP_WIDTH_WORD, xlen_t'(64'hfeed_cafe_8000_0001), '0,
                   xlen_t'($signed(32'h8000_0001)), retire_id_t'(5));
            #1;
            assert (mdu_valid) else $fatal(1, "word divide special acquired extra cycle");
            consume_manual();
        end

        // 第二个请求持续持有 valid/ID/操作数，必须等旧请求交付或取消后才能接纳。
        // 分别覆盖 RESULT 正常消费、RUN 取消、RESULT 取消，不依赖先等 ready 的驱动。
        for (int release_mode = 0; release_mode < 3; release_mode++) begin
            launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(100), xlen_t'(7), xlen_t'(14), retire_id_t'(10));
            request = '{operation:MD_MUL, op_width:OP_WIDTH_XLEN,
                        operand_a:xlen_t'(9), operand_b:xlen_t'(11)};
            request_id = retire_id_t'(11);
            launch_expected = xlen_t'(99);
            req_valid = 1'b1;
            if (release_mode != 1) begin
                await_result();
                repeat (3) begin
                    #1;
                    assert (!req_ready && mdu_completion.id == retire_id_t'(10))
                        else $fatal(1, "pending second request replaced first ID");
                    tick();
                end
            end
            manual_cancel = (release_mode != 0);
            manual_ready = (release_mode == 0);
            #1;
            assert (!req_ready) else $fatal(1, "second request accepted before old owner released");
            tick();
            manual_cancel = 1'b0;
            manual_ready = 1'b0;
            #1;
            assert (req_ready && !mdu_valid) else $fatal(1, "pending request did not become eligible");
            tick();
            req_valid = 1'b0;
            request = '0;
            request_id = '0;
            await_result();
            consume_manual();
            checks++;
        end

        // WB 连续到达时 MDU 保持原 ID/数据；WB 流结束后不再增加搬运拍。
        wb_valid = 1'b1;
        wb_completion = '0;
        manual_ready = 1'b1;
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(17), '0, '1, retire_id_t'(3));
        for (int cycle = 0; cycle < 40; cycle++) begin
            #1;
            assert (wb_ready && !mdu_ready && mdu_valid && completion == wb_completion)
                else $fatal(1, "unblocked WB priority gained a cycle or overwrote MDU");
            tick();
            wb_completion.id = retire_id_t'(cycle);
            wb_completion.result.gpr_data = xlen_t'(cycle + 100);
        end
        wb_valid = 1'b0;
        #1;
        assert (mdu_ready && complete_valid && completion == mdu_completion)
            else $fatal(1, "MDU release gained transfer cycle");
        consume_manual();

        // MDU 先锁定后 WB 才到，输出必须继续展示 MDU；同步取消一起释放源和锁。
        for (int ready_at_cancel = 0; ready_at_cancel < 2; ready_at_cancel++) begin
            launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(17), '0, '1, retire_id_t'(4));
            tick();
            wb_valid = 1'b1;
            repeat (9) tick();
            manual_cancel = 1'b1;
            manual_ready = 1'(ready_at_cancel);
            #1;
            assert (mdu_valid && complete_valid && completion == mdu_completion && !wb_ready)
                else $fatal(1, "cancel combinationally suppressed locked completion");
            tick();
            manual_cancel = 1'b0;
            manual_ready = 1'b0;
            wb_valid = 1'b0;
            #1;
            assert (req_ready && !mdu_valid) else $fatal(1, "cancelled RESULT survived");
            checks++;
        end

        // 年轻 MDU 可先完成，但必须等未完成老 WB 退休；后继 PC 来自队列静态包。
        reset_case(1'b1);
        allocate(100, older);
        allocate(104, younger);
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(7), '0, '1, younger);
        tick();
        retire_ready = 1'b1;
        #1;
        assert (!mdu_valid && occupancy == 2 && !head_complete && !retire_fire)
            else $fatal(1, "young MDU completion retired before old WB");
        send_wb(older, xlen_t'(55), 1'b0);
        #1;
        assert (retire_fire && head_id == younger && head_result.gpr_data == '1 && head_result.next_pc == 108)
            else $fatal(1, "stored young MDU result lost or failed PC normalization");
        tick();
        checks++;

        // 同拍 WB/MDU：WB 优先完成年轻项，随后 MDU 队头完成并按序退休。
        reset_case(1'b1);
        allocate(200, older);
        allocate(204, younger);
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(7), '0, '1, older);
        retire_ready = 1'b1;
        before_retire = retired;
        send_wb(younger, xlen_t'(66), 1'b0);
        assert (retired == before_retire && mdu_valid) else $fatal(1, "WB completed past MDU head");
        tick();
        tick();
        assert (retired == before_retire + 2 && occupancy == 0) else $fatal(1, "ordered completion drain failed");
        checks++;

        // 已寄存老异常退休与年轻 RESULT 交付同沿：完成保持 valid，但被队列丢弃。
        reset_case(1'b1);
        allocate(300, older);
        allocate(304, younger);
        send_wb(older, '0, 1'b1);
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(7), '0, '1, younger);
        auto_trap_flush = 1'b1;
        retire_ready = 1'b1;
        #1;
        assert (queue_flush && cancel && mdu_valid && mdu_ready && complete_reject && retire_fire)
            else $fatal(1, "young result delivery/trap cancellation boundary missing");
        tick();
        auto_trap_flush = 1'b0;
        tick();
        assert (occupancy == 0 && !mdu_valid && req_ready && !recovering)
            else $fatal(1, "trap cancellation failed to drain result owner");
        checks++;

        // 老 WB 异常与乘/除 RUN/RESULT 相遇：WB 本身仍完成，年轻运算沿上取消。
        // DSP 的 RUN 取消也正好覆盖 backend done 尚未进入统一 RESULT 的沿。
        for (int backend = 0; backend < 2; backend++) begin
            for (int result_state = 0; result_state < 2; result_state++) begin
                reset_case(1'b1);
                allocate(400, older);
                allocate(404, younger);
                value = xlen_t'(32'hfedc_ba98);
                launch(backend == 0 ? MD_MUL : MD_DIVU, OP_WIDTH_XLEN, value, xlen_t'(7),
                       backend == 0 ? value * xlen_t'(7) : value / xlen_t'(7), younger);
                if (result_state) await_result();
                auto_trap_flush = 1'b1;
                retire_ready = 1'b1;
                send_wb(older, '0, 1'b1);
                auto_trap_flush = 1'b0;
                repeat (XLEN + 6) begin
                    tick();
                    assert (req_ready && !mdu_valid && occupancy == 0)
                        else $fatal(1, "cancelled MDU revived after trap");
                end
                checks++;
            end
        end

        // 无归属零 ID、错误代次与重复完成由 queue 检查，适配器/仲裁器不按数值过滤。
        reset_case(1'b1);
        before_reject = rejected;
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(7), '0, '1, '0);
        tick();
        allocate(500, older);
        stale = older;
        stale.generation ^= RETIRE_GEN_W'(1);
        launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(7), '0, '1, stale);
        tick();
        send_wb(older, xlen_t'(3), 1'b0);
        send_wb(older, xlen_t'(4), 1'b0);
        assert (rejected == before_reject + 3 && head_result.gpr_data == 3)
            else $fatal(1, "unowned/stale/duplicate completion overwrote live result");
        retire_ready = 1'b1;
        tick();
        // 经过有限代次回卷，数值为零的 ID 也能合法归属于一条真实 M 指令。
        found_zero = 1'b0;
        for (int allocation = 0; allocation <= RETIRE_ENTRIES * (1 << RETIRE_GEN_W); allocation++) begin
            allocate(600 + 4*allocation, older);
            if (older == '0) begin
                launch(MD_DIVU, OP_WIDTH_XLEN, xlen_t'(9), '0, '1, older);
                tick();
                found_zero = 1'b1;
                break;
            end
            send_wb(older, xlen_t'(allocation), 1'b0);
        end
        assert (found_zero && occupancy == 0 && req_ready) else $fatal(1, "live zero ID rejected");
        checks++;
        assert (collisions >= 40 && held_cycles >= 50 && completed_before_head >= 2 &&
                cancelled_deliveries >= 2 && rejected >= 4 &&
                stable_checks >= 100 && request_blocked_cycles >= 8)
            else $fatal(1, "completion protocol coverage missing");
        $display("PASS tb_mdu_completion_adapter RV%0d MUL=%0d DIV=%0d checks=%0d delivered=%0d retired=%0d rejects=%0d held=%0d collisions=%0d stable=%0d req_blocked=%0d",
                 XLEN, MUL_IMPL, DIV_IMPL, checks, delivered, retired, rejected, held_cycles, collisions,
                 stable_checks, request_blocked_cycles);
        $finish;
    end
    initial begin
        repeat (30000) @(posedge clk);
        $fatal(1, "completion adapter timeout");
    end
endmodule
