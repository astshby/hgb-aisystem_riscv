// Module: tb_retire_queue
// Description: Checks the retirement queue against an independent ordered software model.
module tb_retire_queue;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic rst, flush_all, drain_complete;
    logic alloc_valid, alloc_ready;
    retire_alloc_t alloc_meta;
    retire_id_t alloc_id;
    logic complete_valid, complete_ready, complete_reject;
    retire_completion_t completion;
    logic head_valid, head_complete;
    retire_id_t head_id;
    retire_alloc_t head_meta;
    retire_result_t head_result;
    logic retire_ready, retire_fire, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;

    // 参考模型是按程序顺序排列的软件队列，不使用 DUT 指针、valid 位或数组。
    typedef struct packed {
        retire_id_t id;
        retire_alloc_t meta;
        retire_result_t result;
        bit done;
    } model_entry_t;
    model_entry_t model[$];
    logic [RETIRE_GEN_W-1:0] model_generation [RETIRE_ENTRIES];
    int next_slot = 0;
    bit model_recovering = 1'b1;
    retire_id_t last_alloc_id;
    retire_id_t ids [RETIRE_ENTRIES];
    retire_id_t stale_id, fresh_id;
    retire_alloc_t test_meta;
    retire_result_t test_result;
    int seed = 1;
    logic [31:0] random_state;
    int cycles = 0, allocations = 0, completions = 0, pops = 0;
    int rejects = 0, bypasses = 0, replacements = 0, flushes = 0;
    int recovery_cycles = 0, generation_wraps = 0, exception_events = 0;

    always #5 clk = ~clk;
    retire_queue dut (
        .branch_recovery('0), .producer_entries(),
        .ras_entries(), .ras_head_slot(), .query('0), .query_result(),
        .alloc_valid_1(1'b0), .alloc_ready_1(), .alloc_meta_1('0), .alloc_id_1(),
        .complete_valid_1(1'b0), .complete_ready_1(), .completion_1('0), .complete_reject_1(),
        .query_1('0), .query_result_1(), .head_valid_1(), .head_complete_1(),
        .head_id_1(), .head_meta_1(), .head_result_1(), .retire_ready_1(1'b0), .retire_fire_1(), .*
    );

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    function automatic retire_alloc_t make_meta(input int serial);
        retire_alloc_t value;
        value = '0;
        value.pc = xlen_t'(64'h1234_5678_8000_0000) + xlen_t'(4 * serial);
        value.seq_pc = value.pc + xlen_t'(4);
        value.inst = 32'h0000_0013 ^ (32'(serial) << 20);
        value.rd = gpr_addr_t'(serial % 32);
        value.csr_addr = csr_addr_t'(CSR_MSCRATCH);
        value.kind = retire_kind_e'(serial % 6);
        value.sys_op = value.kind == RET_SERIAL ? SYS_FENCE : SYS_NONE;
        value.gpr_write = (value.kind != RET_STORE) && (value.kind != RET_SERIAL);
        return value;
    endfunction

    function automatic retire_result_t make_result(input int serial);
        retire_result_t value;
        value = '0;
        value.next_pc = xlen_t'(64'hcafe_beef_9000_0000) + xlen_t'(4 * serial);
        value.gpr_data = xlen_t'(64'h9876_5432_1122_3344) ^ xlen_t'(serial);
        value.csr_data = xlen_t'(64'h8877_6655_4433_2211) ^ (xlen_t'(serial) << 8);
        value.csr_write = (serial % 3) == 0;
        value.exc.valid = (serial % 13) == 0;
        value.exc.cause = EXC_LOAD_ACCESS_FAULT;
        value.exc.tval = xlen_t'(64'h7654_3210_1000_0000) + xlen_t'(serial);
        return value;
    endfunction

    task automatic idle_inputs;
        rst = 1'b0;
        flush_all = 1'b0;
        drain_complete = 1'b1;
        alloc_valid = 1'b0;
        alloc_meta = '0;
        complete_valid = 1'b0;
        completion = '0;
        retire_ready = 1'b0;
    endtask

    // 每步从下降沿驱动，经组合稳定检查后在上升沿更新独立模型。
    // 完成按 ID 搜索软件队列，与 RTL 的物理槽索引实现不同。
    task automatic step;
        int match_index;
        int old_size;
        bit match_found, expected_pop, expected_alloc, expected_reject;
        bit expected_head_complete, expected_alloc_ready, expected_bypass;
        retire_id_t expected_id;
        retire_result_t expected_result, normalized_result;
        model_entry_t entry, removed;
        #1;
        old_size = model.size();
        match_index = -1;
        match_found = 1'b0;
        expected_pop = 1'b0;
        expected_alloc = 1'b0;
        expected_reject = 1'b0;
        expected_bypass = 1'b0;
        normalized_result = completion.result;
        expected_id.slot = RETIRE_IDX_W'(next_slot);
        expected_id.generation = model_generation[next_slot] + RETIRE_GEN_W'(1);

        if (rst) begin
            assert (!alloc_ready && !complete_ready && !head_valid && !head_complete && !retire_fire)
                else $fatal(1, "reset exposed a queue event");
        end else begin
            foreach (model[index]) begin
                if (model[index].id == completion.id) match_index = index;
            end
            if (match_index >= 0) begin
                match_found = !model[match_index].done;
                if (model[match_index].meta.kind != RET_BRANCH)
                    normalized_result.next_pc = model[match_index].meta.seq_pc;
            end
            expected_bypass = complete_valid && match_found && (match_index == 0);
            expected_head_complete = old_size != 0 && (model[0].done || expected_bypass);
            expected_pop = expected_head_complete && retire_ready;
            expected_alloc_ready = !flush_all && !model_recovering &&
                                   ((old_size < RETIRE_ENTRIES) || expected_pop);
            expected_alloc = alloc_valid && expected_alloc_ready;
            expected_reject = complete_valid &&
                              (!match_found || (flush_all && !(expected_bypass && expected_pop)));

            assert (int'(occupancy) == old_size && recovering == model_recovering)
                else $fatal(1, "queue state cycle=%0d depth=%0d size=%0d occupancy=%0d", cycles, RETIRE_ENTRIES, old_size, occupancy);
            assert (alloc_ready == expected_alloc_ready && alloc_id == expected_id)
                else $fatal(1, "allocation contract cycle=%0d", cycles);
            assert (complete_ready && complete_reject == expected_reject)
                else $fatal(1, "completion qualification cycle=%0d index=%0d", cycles, match_index);
            assert (head_valid == (old_size != 0) && head_complete == expected_head_complete &&
                    retire_fire == expected_pop)
                else $fatal(1, "head eligibility cycle=%0d", cycles);
            if (old_size != 0) begin
                assert (head_id == model[0].id && head_meta == model[0].meta)
                    else $fatal(1, "out-of-order head metadata cycle=%0d", cycles);
                if (expected_head_complete) begin
                    expected_result = expected_bypass ? normalized_result : model[0].result;
                    assert (head_result == expected_result)
                        else $fatal(1, "head result/exception mismatch cycle=%0d", cycles);
                end else begin
                    assert (head_result == '0) else $fatal(1, "unfinished head exposed stale payload");
                end
            end else begin
                assert (head_id == '0 && head_meta == '0 && head_result == '0)
                    else $fatal(1, "empty queue exposed stale payload");
            end
        end

        @(posedge clk);
        if (rst) begin
            model.delete();
            next_slot = 0;
            model_recovering = 1'b1;
            for (int slot = 0; slot < RETIRE_ENTRIES; slot++) model_generation[slot] = '0;
        end else begin
            if (model_recovering) recovery_cycles++;
            if (complete_valid && !expected_reject) completions++;
            if (expected_reject) rejects++;
            if (expected_bypass && expected_pop) bypasses++;
            if (expected_pop) begin
                pops++;
                if (expected_result.exc.valid) exception_events++;
            end
            if (old_size == RETIRE_ENTRIES && expected_pop && expected_alloc) replacements++;
            if (flush_all) begin
                model.delete();
                next_slot = 0;
                model_recovering = 1'b1;
                flushes++;
            end else begin
                if (complete_valid && match_found) begin
                    entry = model[match_index];
                    entry.result = normalized_result;
                    entry.done = 1'b1;
                    model[match_index] = entry;
                end
                if (expected_pop) removed = model.pop_front();
                if (expected_alloc) begin
                    entry = '0;
                    entry.id = expected_id;
                    entry.meta = alloc_meta;
                    model.push_back(entry);
                    model_generation[next_slot] = expected_id.generation;
                    if (expected_id.generation == '0) generation_wraps++;
                    next_slot = (next_slot + 1) % RETIRE_ENTRIES;
                    last_alloc_id = expected_id;
                    allocations++;
                end
                if (drain_complete) model_recovering = 1'b0;
            end
        end
        @(negedge clk);
        cycles++;
    endtask

    task automatic allocate(input retire_alloc_t meta, output retire_id_t id);
        int previous_allocations;
        previous_allocations = allocations;
        idle_inputs();
        alloc_valid = 1'b1;
        alloc_meta = meta;
        step();
        assert (allocations == previous_allocations + 1) else $fatal(1, "directed allocation blocked");
        id = last_alloc_id;
    endtask

    task automatic finish_id(input retire_id_t id, input retire_result_t value, input bit pop);
        idle_inputs();
        complete_valid = 1'b1;
        completion = '{id: id, result: value};
        retire_ready = pop;
        step();
    endtask

    task automatic drain_model;
        while (model.size() != 0) begin
            idle_inputs();
            retire_ready = 1'b1;
            if (!model[0].done) begin
                complete_valid = 1'b1;
                completion = '{id: model[0].id, result: make_result(cycles)};
            end
            step();
        end
    endtask

    initial begin
        assert (RETIRE_ENTRIES inside {2, 4, 8, 16})
            else $fatal(1, "retire queue supports only 2/4/8/16 slots");
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        random_state = seed == 0 ? 32'd1 : 32'(seed);
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) model_generation[slot] = '0;
        idle_inputs();
        @(negedge clk);
        rst = 1'b1;
        step();
        idle_inputs();
        step();

        // 空队列不能把本拍新分配 ID 的完成当作已经执行；生产者至少先取得 ID。
        idle_inputs();
        alloc_valid = 1'b1;
        alloc_meta = make_meta(1);
        complete_valid = 1'b1;
        completion.id = '{slot: RETIRE_IDX_W'(next_slot), generation: RETIRE_GEN_W'(1)};
        completion.result = make_result(1);
        retire_ready = 1'b1;
        step();
        ids[0] = last_alloc_id;
        finish_id(ids[0], make_result(1), 1'b0);
        // 重复完成不能改写已经保存的值，反压期间的队头载荷必须稳定。
        finish_id(ids[0], make_result(999), 1'b0);
        repeat (3) begin idle_inputs(); step(); end
        drain_model();

        // 年轻结果可以先完成，但不能绕过未完成队头；队头旁路可同拍完成并弹出。
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) allocate(make_meta(slot + 10), ids[slot]);
        for (int slot = RETIRE_ENTRIES-1; slot > 0; slot--)
            finish_id(ids[slot], make_result(slot + 10), 1'b1);
        idle_inputs();
        alloc_valid = 1'b1;
        alloc_meta = make_meta(100);
        step();
        // 满队列首尾同槽：旧 ID 完成、退休与新 ID 分配发生于同一沿。
        idle_inputs();
        complete_valid = 1'b1;
        completion = '{id: ids[0], result: make_result(10)};
        retire_ready = 1'b1;
        alloc_valid = 1'b1;
        alloc_meta = make_meta(100);
        step();
        fresh_id = last_alloc_id;
        stale_id = ids[0];
        finish_id(stale_id, make_result(666), 1'b0);
        finish_id(fresh_id, make_result(100), 1'b0);
        drain_model();

        // 环形槽和有限代次多次回卷；没有旧事务存活时，代次回卷本身是合法的。
        for (int turn = 0; turn < RETIRE_ENTRIES * 10; turn++) begin
            allocate(make_meta(turn + 200), fresh_id);
            finish_id(fresh_id, make_result(turn + 200), 1'b1);
        end

        // 外部取消同拍收到年轻结果：丢弃它，恢复期间吞掉迟到响应但拒绝新分配。
        allocate(make_meta(300), ids[0]);
        allocate(make_meta(301), ids[1]);
        idle_inputs();
        flush_all = 1'b1;
        drain_complete = 1'b0;
        complete_valid = 1'b1;
        completion = '{id: ids[1], result: make_result(301)};
        step();
        for (int wait_cycle = 0; wait_cycle < 3; wait_cycle++) begin
            idle_inputs();
            drain_complete = 1'b0;
            alloc_valid = 1'b1;
            alloc_meta = make_meta(302);
            complete_valid = 1'b1;
            completion = '{id: ids[0], result: make_result(300)};
            if (wait_cycle == 0) flush_all = 1'b1; // 再次取消时的旧 ID 也不能复活。
            step();
        end
        idle_inputs();
        alloc_valid = 1'b1; // 确认排空的沿仍不分配，下一拍再恢复。
        alloc_meta = make_meta(302);
        step();
        allocate(make_meta(302), fresh_id);
        finish_id(ids[0], make_result(777), 1'b0);
        drain_model();

        // LSU 契约模型：descriptor 准备好不等于完成。这里不代替未来真实 LSU 的验证。
        test_meta = make_meta(400);
        test_meta.kind = RET_STORE;
        test_meta.gpr_write = 1'b0;
        allocate(test_meta, ids[0]);
        allocate(make_meta(401), ids[1]);
        finish_id(ids[1], make_result(401), 1'b0);
        // 模拟 Store 请求反压及随后等待写响应；队头许可不能依赖 head_complete。
        repeat (5) begin
            idle_inputs();
            retire_ready = 1'b1;
            #1;
            assert (head_valid && head_id == ids[0] && head_meta.kind == RET_STORE && !head_complete)
                else $fatal(1, "prepared store was mistaken for completed response");
            step();
        end
        // 写错误响应是异常完成；队头事件和全局清理同拍，年轻已完成 ADD 不退休。
        idle_inputs();
        complete_valid = 1'b1;
        test_result = make_result(400);
        test_result.exc.valid = 1'b1;
        test_result.exc.cause = EXC_STORE_ACCESS_FAULT;
        completion = '{id: ids[0], result: test_result};
        retire_ready = 1'b1;
        flush_all = 1'b1;
        drain_complete = 1'b0;
        step();
        idle_inputs();
        step();

        // 确定性随机流同时施加分配、乱序/重复/过期完成、退休反压及全局恢复。
        for (int iteration = 0; iteration < 4000; iteration++) begin
            int selected;
            logic [31:0] choice;
            idle_inputs();
            choice = random_word();
            alloc_valid = choice[0] || choice[1];
            alloc_meta = make_meta(iteration + 1000);
            complete_valid = choice[2] || choice[3];
            retire_ready = choice[4];
            flush_all = choice[12:7] == 6'd0;
            drain_complete = choice[5];
            completion.result = make_result(iteration + 1000);
            if (model.size() != 0 && choice[14:13] != 2'b00) begin
                selected = int'(random_word() % 32'(model.size()));
                completion.id = model[selected].id;
                if (choice[14:13] == 2'b11)
                    completion.id.generation ^= RETIRE_GEN_W'(1);
            end else begin
                completion.id.slot = RETIRE_IDX_W'(random_word());
                completion.id.generation = RETIRE_GEN_W'(random_word());
            end
            step();
        end
        idle_inputs();
        step();
        drain_model();
        idle_inputs();
        step();
        assert (allocations > 100 && completions > 50 && pops > 50 && rejects > 20 &&
                bypasses > 10 && replacements > 0 && flushes > 2 && recovery_cycles > 5 &&
                generation_wraps > 0 && exception_events > 0)
            else $fatal(1, "insufficient queue coverage");
        $display("PASS tb_retire_queue XLEN=%0d depth=%0d seed=%0d cycles=%0d alloc=%0d complete=%0d pop=%0d reject=%0d bypass=%0d full_replace=%0d flush=%0d recovery=%0d gen_wrap=%0d exceptions=%0d",
                 XLEN, RETIRE_ENTRIES, seed, cycles, allocations, completions, pops, rejects,
                 bypasses, replacements, flushes, recovery_cycles, generation_wraps, exception_events);
        $finish;
    end
endmodule
