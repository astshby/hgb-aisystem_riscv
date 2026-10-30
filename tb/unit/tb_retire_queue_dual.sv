// Module: tb_retire_queue_dual
// Description: Checks dual retirement ports, completion identity and queries with an ordered software queue.
module tb_retire_queue_dual;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0, rst, flush_all, drain_complete;
    logic alloc_valid, alloc_ready, alloc_valid_1, alloc_ready_1;
    retire_alloc_t alloc_meta, alloc_meta_1;
    retire_id_t alloc_id, alloc_id_1;
    logic complete_valid, complete_ready, complete_reject;
    logic complete_valid_1, complete_ready_1, complete_reject_1;
    retire_completion_t completion, completion_1;
    retire_query_t query, query_1;
    retire_query_result_t query_result, query_result_1;
    logic head_valid, head_complete, head_valid_1, head_complete_1;
    retire_id_t head_id, head_id_1;
    retire_alloc_t head_meta, head_meta_1;
    retire_result_t head_result, head_result_1;
    logic retire_ready, retire_fire, retire_ready_1, retire_fire_1;
    logic recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;
    typedef struct packed {
        retire_id_t id;
        retire_alloc_t meta;
        retire_result_t result;
        bit done;
    } entry_t;
    entry_t model[$];
    logic [RETIRE_GEN_W-1:0] generations [RETIRE_ENTRIES];
    int tail = 0, serial = 1, seed = 1;
    bit model_recovering = 1'b1;
    logic [31:0] random_state;
    int cycles, dual_allocs, dual_retires, dual_completes, replacements, cross_bypasses;
    int duplicates, rejects, flushes, recovery_waits, second_blocked, registered_queries, retiring_queries;
    retire_id_t old_id;
    retire_id_t probe_id [5];
    logic [4:0] probe_accept;
    initial for (int probe = 0; probe < 5; probe++) probe_id[probe] = '0;

    always #5 clk = ~clk;
    retire_queue dut (.branch_recovery('0), .producer_entries(), .probe_live(), .ras_entries(), .ras_head_slot(), .*);

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    function automatic retire_alloc_t metadata(input int index);
        retire_alloc_t value;
        value = '0;
        value.pc = xlen_t'(64'h9876_5432_8000_0000) + xlen_t'(index * 4);
        value.seq_pc = value.pc + xlen_t'(4);
        value.inst = 32'h13 ^ (32'(index) << 20);
        value.kind = (index % 5 == 0) ? RET_BRANCH : RET_EXEC;
        value.gpr_write = 1'b1;
        value.rd = gpr_addr_t'(index % 31 + 1);
        return value;
    endfunction

    function automatic retire_result_t result_value(input int index);
        retire_result_t value;
        value = '0;
        value.gpr_data = xlen_t'(64'h8765_4321_3456_7890) ^ xlen_t'(index);
        value.next_pc = xlen_t'(64'hfedc_ba98_9000_1000) + xlen_t'(index * 8);
        value.csr_data = ~value.gpr_data;
        value.branch.taken = 1'(index);
        value.branch.target = value.next_pc + xlen_t'(16);
        value.exc.cause = EXC_ILLEGAL_INST;
        value.exc.tval = xlen_t'(index);
        return value;
    endfunction

    task automatic defaults;
        rst = 1'b0; flush_all = 1'b0; drain_complete = 1'b1;
        alloc_valid = 1'b0; alloc_valid_1 = 1'b0;
        alloc_meta = metadata(serial); alloc_meta_1 = metadata(serial + 1);
        // 按预计物理槽选不同rd，使随机查询也遵守单live-writer前提。
        alloc_meta.rd = gpr_addr_t'(tail + 1);
        alloc_meta_1.rd = gpr_addr_t'((tail + 1) % RETIRE_ENTRIES + 1);
        complete_valid = 1'b0; complete_valid_1 = 1'b0;
        completion = '0; completion_1 = '0;
        retire_ready = 1'b0; retire_ready_1 = 1'b0;
        query = '0; query_1 = '0;
    endtask

    // 参考查询只搜索软件年龄列表。D2排同沿正常退休者；EX仍可读它们原先寄存的结果。
    task automatic check_query(input retire_query_t request, input retire_query_result_t observed,
                               input bit enabled, input int pops, input entry_t visible[$]);
        retire_query_result_t expected;
        int consumer;
        bit retiring, writer;
        expected = '0; consumer = -1;
        if (!rst && enabled) begin
            foreach (model[index])
                if (request.consumer_valid && model[index].id == request.consumer_id) consumer = index;
            expected.consumer_live = consumer >= 0;
            foreach (model[index]) begin
                retiring = index < pops && !visible[index].result.exc.valid;
                writer = model[index].meta.gpr_write && model[index].meta.rd != '0;
                if (request.dispatch_valid && writer && !retiring) begin
                    if (request.rs1_used && request.rs1 != '0 && request.rs1 == model[index].meta.rd) begin
                        expected.rs1_dependency = '{pending:1'b1, id:model[index].id};
                        if (model[index].done && !model[index].result.exc.valid)
                            expected.dispatch_rs1 = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    end
                    if (request.rs2_used && request.rs2 != '0 && request.rs2 == model[index].meta.rd) begin
                        expected.rs2_dependency = '{pending:1'b1, id:model[index].id};
                        if (model[index].done && !model[index].result.exc.valid)
                            expected.dispatch_rs2 = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    end
                    if (request.gpr_write && request.rd != '0 && request.rd == model[index].meta.rd)
                        expected.waw_block = 1'b1;
                end
                if (consumer >= 0 && index < consumer && writer && model[index].done && !model[index].result.exc.valid) begin
                    if (request.rs1_dependency.pending && request.rs1_dependency.id == model[index].id)
                        expected.rs1_forward = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    if (request.rs2_dependency.pending && request.rs2_dependency.id == model[index].id)
                        expected.rs2_forward = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                end
                if (model[index].meta.kind == RET_MDU) begin
                    expected.any_unretired_mdu = 1'b1;
                    if (consumer >= 0 && index < consumer) expected.older_mdu_pending = 1'b1;
                end
            end
        end
        assert (observed == expected)
            else $fatal(1, "dual query cycle=%0d got=%h expected=%h", cycles, observed, expected);
        if (expected.dispatch_rs1.valid || expected.dispatch_rs2.valid) registered_queries++;
        if (pops > 0 && (expected.rs1_forward.valid || expected.rs2_forward.valid)) retiring_queries++;
    endtask

    // 完成先按完整ID在软件列表搜索，退休再取连续前缀；不读取DUT指针/valid/done来建答案。
    task automatic step;
        entry_t visible[$];
        entry_t item, removed;
        retire_completion_t offered [2];
        retire_id_t expected_ids [2];
        retire_alloc_t allocated [2];
        retire_result_t expected_result [2];
        logic [1:0] offered_valid, matched, rejected, pop, expected_valid, expected_complete;
        logic [1:0] expected_ready, admitted;
        int match_index [2];
        int pops, count_before, available, slot;
        #1;
        visible = model;
        offered = '{completion, completion_1};
        offered_valid = {complete_valid_1 && (ISSUE_WIDTH == 2), complete_valid};
        allocated = '{alloc_meta, alloc_meta_1};
        matched = '0; rejected = '0; pop = '0; expected_valid = '0; expected_complete = '0;
        expected_ready = '0; admitted = '0; pops = 0;
        count_before = model.size();
        for (int port = 0; port < 2; port++) begin
            match_index[port] = -1;
            slot = (tail + port) % RETIRE_ENTRIES;
            expected_ids[port] = '{slot:RETIRE_IDX_W'(slot), generation:generations[slot]+RETIRE_GEN_W'(1)};
            expected_result[port] = '0;
            foreach (model[index])
                if (model[index].id == offered[port].id) match_index[port] = index;
            if (!rst && offered_valid[port] && match_index[port] >= 0 && !visible[match_index[port]].done) begin
                matched[port] = 1'b1;
                item = visible[match_index[port]];
                item.done = 1'b1;
                item.result = offered[port].result;
                if (item.meta.kind != RET_BRANCH) item.result.next_pc = item.meta.seq_pc;
                visible[match_index[port]] = item;
            end
        end
        if (!rst) begin
            for (int port = 0; port < 2; port++) begin
                expected_valid[port] = port < count_before && (port == 0 || ISSUE_WIDTH == 2);
                if (expected_valid[port]) begin
                    expected_complete[port] = visible[port].done;
                    if (visible[port].done) expected_result[port] = visible[port].result;
                end
            end
            pop[0] = expected_complete[0] && retire_ready;
            pop[1] = pop[0] && expected_complete[1] && retire_ready_1;
            pops = int'(pop[0]) + int'(pop[1]);
            available = RETIRE_ENTRIES - count_before + pops;
            expected_ready[0] = !flush_all && !model_recovering && available > 0;
            admitted[0] = alloc_valid && expected_ready[0];
            expected_ready[1] = (ISSUE_WIDTH == 2) && admitted[0] && available >= 2;
            admitted[1] = alloc_valid_1 && expected_ready[1];
            for (int port = 0; port < 2; port++)
                rejected[port] = offered_valid[port] && (!matched[port] || (flush_all && match_index[port] >= pops));
        end
        assert (occupancy == RETIRE_COUNT_W'(count_before) && recovering == model_recovering)
            else $fatal(1, "queue state cycle=%0d count=%0d actual=%0d", cycles, count_before, occupancy);
        assert ({alloc_ready_1,alloc_ready} == expected_ready && alloc_id == expected_ids[0] && alloc_id_1 == expected_ids[1])
            else $fatal(1, "allocation prefix cycle=%0d", cycles);
        assert (complete_ready == !rst && complete_ready_1 == (!rst && ISSUE_WIDTH == 2) &&
                {complete_reject_1,complete_reject} == rejected)
            else $fatal(1, "completion acceptance cycle=%0d got=%b expected=%b", cycles,
                        {complete_reject_1,complete_reject}, rejected);
        assert ({head_valid_1,head_valid} == expected_valid &&
                {head_complete_1,head_complete} == expected_complete && {retire_fire_1,retire_fire} == pop)
            else $fatal(1, "retirement prefix cycle=%0d", cycles);
        assert (head_result == expected_result[0] && head_result_1 == expected_result[1])
            else $fatal(1, "retirement value cycle=%0d", cycles);
        if (expected_valid[0]) begin
            assert (head_id == model[0].id && head_meta == model[0].meta) else $fatal(1, "head0 age");
        end else assert (!retire_fire && head_meta == '0) else $fatal(1, "empty head0 retired");
        if (expected_valid[1]) begin
            assert (head_id_1 == model[1].id && head_meta_1 == model[1].meta) else $fatal(1, "head1 age");
        end else assert (!retire_fire_1 && head_meta_1 == '0) else $fatal(1, "empty head1 retired");
        check_query(query, query_result, 1'b1, pops, visible);
        check_query(query_1, query_result_1, ISSUE_WIDTH == 2, pops, visible);

        if (&admitted) dual_allocs++;
        if (&pop) dual_retires++;
        if (&matched) dual_completes++;
        if (count_before == RETIRE_ENTRIES && (&admitted) && (&pop)) replacements++;
        if ((matched[0] && match_index[0] == 1) && (matched[1] && match_index[1] == 0) && (&pop)) cross_bypasses++;
        if (offered_valid == 2'b11 && offered[0].id == offered[1].id && matched[0] && rejected[1]) duplicates++;
        rejects += int'(rejected[0]) + int'(rejected[1]);
        if (flush_all) flushes++;
        if (model_recovering && !drain_complete) recovery_waits++;
        if (retire_ready_1 && !pop[0] && expected_complete[1]) second_blocked++;

        @(posedge clk);
        if (rst) begin
            model.delete(); tail = 0; model_recovering = 1'b1;
            foreach (generations[index]) generations[index] = '0;
        end else if (flush_all) begin
            model.delete(); tail = 0; model_recovering = 1'b1;
        end else begin
            model = visible;
            repeat (pops) removed = model.pop_front();
            for (int port = 0; port < 2; port++) begin
                if (admitted[port]) begin
                    item = '0; item.id = expected_ids[port]; item.meta = allocated[port];
                    model.push_back(item);
                    generations[tail] = item.id.generation;
                    tail = (tail + 1) % RETIRE_ENTRIES;
                    serial++;
                end
            end
            if (drain_complete) model_recovering = 1'b0;
        end
        cycles++;
        @(negedge clk);
    endtask

    task automatic reset_case;
        defaults(); rst = 1'b1; step();
        defaults(); step();
    endtask

    task automatic fill_queue;
        while (model.size() < RETIRE_ENTRIES) begin
            defaults(); alloc_valid = 1'b1; alloc_valid_1 = 1'b1; step();
        end
    endtask

    task automatic query_producers;
        if (model.size() >= 2) begin
            query.dispatch_valid = 1'b1;
            query.rs1_used = 1'b1; query.rs2_used = 1'b1;
            query.rs1 = model[0].meta.rd; query.rs2 = model[1].meta.rd;
            query.gpr_write = 1'b1; query.rd = model[0].meta.rd;
            query.consumer_valid = 1'b1; query.consumer_id = model[model.size()-1].id;
            query.rs1_dependency = '{pending:1'b1, id:model[0].id};
            query.rs2_dependency = '{pending:1'b1, id:model[1].id};
            query_1 = query;
        end
    endtask

    initial begin
        cycles = 0; dual_allocs = 0; dual_retires = 0; dual_completes = 0; replacements = 0;
        cross_bypasses = 0; duplicates = 0; rejects = 0; flushes = 0; recovery_waits = 0;
        second_blocked = 0; registered_queries = 0; retiring_queries = 0;
        foreach (generations[index]) generations[index] = '0;
        void'($value$plusargs("seed=%d", seed)); random_state = 32'(seed) ^ 32'h514cbda9;
        defaults(); rst = 1'b1;
        @(negedge clk); step(); defaults(); step();

        // 第二分配口不能独自接纳。两个完成口可交叉旁路两个head，并同沿满队列换代。
        defaults(); alloc_valid_1 = 1'b1; step();
        fill_queue();
        old_id = model[0].id;
        defaults(); complete_valid = 1'b1; completion.id = model[1].id; completion.result = result_value(11);
        complete_valid_1 = 1'b1; completion_1.id = model[0].id; completion_1.result = result_value(12);
        retire_ready = 1'b1; retire_ready_1 = 1'b1; alloc_valid = 1'b1; alloc_valid_1 = 1'b1; step();
        defaults(); complete_valid = 1'b1; completion.id = old_id; step();

        reset_case(); fill_queue();
        // 同完整ID的第二完成必须被拒，不能以第二值覆盖；未完成head阻止完成head1越过。
        defaults(); complete_valid = 1'b1; complete_valid_1 = 1'b1;
        completion.id = model[1].id; completion.result = result_value(21);
        completion_1.id = completion.id; completion_1.result = result_value(22);
        retire_ready_1 = 1'b1; step();
        defaults(); retire_ready_1 = 1'b1; query_producers(); step();
        defaults(); complete_valid = 1'b1; completion.id = model[0].id; completion.result = result_value(23); step();
        defaults(); retire_ready = 1'b1; retire_ready_1 = 1'b1; query_producers(); step();

        reset_case(); fill_queue();
        // 第二条异常留待成为队头；本单元的retire_ready_1模拟提交资格，不允许异常年轻项提交。
        defaults(); complete_valid = 1'b1; completion.id = model[0].id; completion.result = result_value(31);
        complete_valid_1 = 1'b1; completion_1.id = model[1].id; completion_1.result = result_value(32);
        completion_1.result.exc.valid = 1'b1; step();
        defaults(); query_producers(); retire_ready = 1'b1; step();
        if (ISSUE_WIDTH == 2) begin
            defaults(); retire_ready = 1'b1; flush_all = 1'b1; query_producers(); step();
        end else begin
            defaults(); flush_all = 1'b1; step();
        end
        repeat (3) begin
            defaults(); drain_complete = 1'b0; alloc_valid = 1'b1; alloc_valid_1 = 1'b1;
            complete_valid = 1'b1; completion.id = old_id; step();
        end
        defaults(); step();

        reset_case(); fill_queue();
        // flush自产head事件不屏蔽完成；第二年轻完成同沿吞掉并reject，随后排空才重新分配。
        defaults(); complete_valid_1 = 1'b1; completion_1.id = model[0].id;
        completion_1.result = result_value(41); completion_1.result.exc.valid = 1'b1;
        complete_valid = 1'b1; completion.id = model[1].id; completion.result = result_value(42);
        retire_ready = 1'b1; flush_all = 1'b1; step();
        defaults(); step();

        // 随机组合也遵守ID/年龄模型，含空槽、旧代次、重复完成、满/空回卷和恢复阻塞。
        for (int iteration = 0; iteration < 3000; iteration++) begin
            defaults();
            alloc_valid = 1'(random_word()); alloc_valid_1 = 1'(random_word());
            complete_valid = 1'(random_word()); complete_valid_1 = 1'(random_word());
            retire_ready = 1'(random_word()); retire_ready_1 = 1'(random_word());
            drain_complete = (random_word() % 4 != 0);
            flush_all = (random_word() % 53 == 0);
            completion.result = result_value(iteration+100);
            completion_1.result = result_value(iteration+200);
            if (model.size() != 0) begin
                completion.id = model[random_word() % model.size()].id;
                completion_1.id = model[random_word() % model.size()].id;
            end
            if (iteration % 11 == 0) completion.id.generation++;
            if (iteration % 13 == 0) completion_1.id.generation++;
            if (iteration % 7 == 0) begin
                completion_1.id = completion.id; complete_valid_1 = 1'b1;
            end
            query_producers();
            if (iteration % 9 == 0) query.consumer_id.generation++;
            if (iteration % 10 == 0) begin query_1.rs1 = '0; query_1.rs2 = '0; query_1.rd = '0; end
            step();
        end
        assert (rejects > 10 && flushes > 10 && recovery_waits > 2 && registered_queries > 0 && retiring_queries > 0)
            else $fatal(1, "queue/query basic coverage");
        if (ISSUE_WIDTH == 2)
            assert (dual_allocs > 20 && dual_retires > 10 && dual_completes > 10 && replacements > 0 &&
                    cross_bypasses > 0 && duplicates > 0 && second_blocked > 0) else $fatal(1, "dual coverage");
        else assert (dual_allocs == 0 && dual_retires == 0 && dual_completes == 0) else $fatal(1, "disabled lane1");
        $display("PASS tb_retire_queue_dual RV%0d issue=%0d depth=%0d seed=%0d cycles=%0d alloc2=%0d complete2=%0d retire2=%0d full2=%0d cross=%0d duplicate=%0d reject=%0d flush=%0d recovery=%0d blocked1=%0d d2value=%0d retirecapture=%0d",
                 XLEN, ISSUE_WIDTH, RETIRE_ENTRIES, seed, cycles, dual_allocs, dual_completes, dual_retires,
                 replacements, cross_bypasses, duplicates, rejects, flushes, recovery_waits, second_blocked,
                 registered_queries, retiring_queries);
        $finish;
    end
endmodule
