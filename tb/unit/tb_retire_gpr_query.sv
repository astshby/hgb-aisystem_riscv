// Module: tb_retire_gpr_query
// Description: Checks retirement-owned queries against an independent ordered transaction model.
module tb_retire_gpr_query;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0, rst = 1'b1, flush_all, drain_complete;
    logic alloc_valid, alloc_ready, complete_valid, complete_ready, complete_reject;
    logic head_valid, head_complete, retire_ready, retire_fire, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;
    retire_alloc_t alloc_meta, head_meta;
    retire_id_t alloc_id, head_id;
    retire_completion_t completion;
    retire_result_t head_result;
    retire_query_t query;
    retire_query_result_t query_result;
    typedef struct packed {
        retire_id_t id;
        retire_alloc_t meta;
        retire_result_t result;
        logic done;
    } entry_t;
    entry_t model[$], entry, removed;
    int checks = 0, same_edge = 0, stale_checks = 0, fault_checks = 0, mdu_checks = 0;
    int full_replace = 0, wraps = 0, zero_id = 0;
    int seed = 1;
    logic [31:0] random_state;

    always #5 clk = ~clk;
    retire_queue dut (
        .branch_recovery('0), .producer_entries(),
        .ras_entries(), .ras_head_slot(),
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

    task automatic defaults;
        flush_all = 1'b0;
        drain_complete = 1'b1;
        alloc_valid = 1'b0;
        alloc_meta = '0;
        complete_valid = 1'b0;
        completion = '0;
        retire_ready = 1'b0;
        query = '0;
    endtask

    // 参考模型按接纳顺序排序，查年龄只比较软件下标，不读取 DUT 指针/槽数组。
    // 本拍完成还不是 query 的寄存结果；仅退休资格可使用原队列的完成旁路。
    task automatic step;
        int ci, fi;
        logic pop, normal_pop, allocation_fire;
        retire_query_result_t expected;
        retire_result_t retiring_result;
        retire_id_t accepted_id;
        #1;
        ci = -1;
        fi = -1;
        expected = '0;
        retiring_result = '0;
        foreach (model[index]) begin
            if (model[index].id == query.consumer_id && query.consumer_valid) ci = index;
            if (model[index].id == completion.id) fi = index;
        end
        if (model.size() != 0) begin
            retiring_result = model[0].result;
            if (complete_valid && fi == 0 && !model[0].done) retiring_result = completion.result;
        end
        pop = !rst && retire_ready && model.size() != 0 &&
              (model[0].done || (complete_valid && fi == 0));
        normal_pop = pop && !retiring_result.exc.valid;
        if (!rst) begin
            expected.consumer_live = (ci >= 0);
            foreach (model[index]) begin
                if (query.dispatch_valid && model[index].meta.gpr_write && model[index].meta.rd != '0 &&
                    !(normal_pop && index == 0)) begin
                    if (query.rs1_used && query.rs1 != '0 && query.rs1 == model[index].meta.rd) begin
                        expected.rs1_dependency = '{pending:1'b1, id:model[index].id};
                        if (model[index].done && !model[index].result.exc.valid)
                            expected.dispatch_rs1 = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    end
                    if (query.rs2_used && query.rs2 != '0 && query.rs2 == model[index].meta.rd) begin
                        expected.rs2_dependency = '{pending:1'b1, id:model[index].id};
                        if (model[index].done && !model[index].result.exc.valid)
                            expected.dispatch_rs2 = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    end
                    if (query.gpr_write && query.rd != '0 && query.rd == model[index].meta.rd)
                        expected.waw_block = 1'b1;
                end
                if (ci >= 0 && index < ci && model[index].done && !model[index].result.exc.valid &&
                    model[index].meta.gpr_write && model[index].meta.rd != '0) begin
                    if (query.rs1_dependency.pending && query.rs1_dependency.id == model[index].id)
                        expected.rs1_forward = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                    if (query.rs2_dependency.pending && query.rs2_dependency.id == model[index].id)
                        expected.rs2_forward = '{valid:1'b1, id:model[index].id, data:model[index].result.gpr_data};
                end
                if (model[index].meta.kind == RET_MDU) begin
                    expected.any_unretired_mdu = 1'b1;
                    if (ci >= 0 && index < ci) expected.older_mdu_pending = 1'b1;
                end
            end
            if (pop && query.dispatch_valid && ci >= 0) same_edge++;
            if (query.consumer_valid && ci < 0) stale_checks++;
            if (expected.any_unretired_mdu) mdu_checks++;
            foreach (model[index])
                if (model[index].done && model[index].result.exc.valid) fault_checks++;
        end
        assert (query_result == expected)
            else $fatal(1, "query mismatch cycle=%0d depth=%0d got=%h expected=%h", checks, RETIRE_ENTRIES, query_result, expected);
        allocation_fire = alloc_valid && alloc_ready;
        accepted_id = alloc_id;
        @(posedge clk);
        if (rst || flush_all)
            model.delete();
        else begin
            if (complete_valid && fi >= 0 && !model[fi].done) begin
                entry = model[fi];
                entry.done = 1'b1;
                entry.result = completion.result;
                model[fi] = entry;
            end
            if (pop && allocation_fire && model.size() == RETIRE_ENTRIES) full_replace++;
            if (pop) removed = model.pop_front();
            if (allocation_fire) begin
                entry = '0;
                entry.id = accepted_id;
                entry.meta = alloc_meta;
                model.push_back(entry);
                if (accepted_id.slot == '0) wraps++;
            end
        end
        @(negedge clk);
        checks++;
    endtask
    task automatic reset_case;
        defaults();
        rst = 1'b1;
        step();
        rst = 1'b0;
        step();
    endtask
    task automatic allocate(input int rd, input retire_kind_e kind, output retire_id_t id);
        defaults();
        alloc_meta.rd = gpr_addr_t'(rd);
        alloc_meta.gpr_write = (kind != RET_STORE);
        alloc_meta.kind = kind;
        alloc_meta.seq_pc = xlen_t'(4) * (xlen_t'(checks) + xlen_t'(1));
        alloc_valid = 1'b1;
        #1;
        assert (alloc_ready) else $fatal(1, "query test allocated full queue");
        id = alloc_id;
        step();
        alloc_valid = 1'b0;
    endtask
    task automatic finish(input retire_id_t id, input logic fault);
        complete_valid = 1'b1;
        completion = '0;
        completion.id = id;
        completion.result.gpr_data = xlen_t'(64'hfeed_cafe_1234_5678) ^ xlen_t'(id);
        completion.result.exc.valid = fault;
        completion.result.exc.cause = EXC_LOAD_ACCESS_FAULT;
        step();
        complete_valid = 1'b0;
    endtask

    initial begin
        retire_id_t producer, consumer, reused, old_head;
        int ci, pi, rd_candidate;
        logic used_rd;
        if ($value$plusargs("seed=%d", seed)) begin end
        random_state = 32'(seed);
        @(negedge clk);
        reset_case();
        allocate(5, RET_MDU, producer);
        allocate(6, RET_EXEC, consumer);
        defaults();
        query = '{dispatch_valid:1'b1, rs1_used:1'b1, rs2_used:1'b1,
                  rs1:5'd5, rs2:'0, rd:5'd5, gpr_write:1'b1,
                  consumer_valid:1'b1, consumer_id:consumer,
                  rs1_dependency:'{pending:1'b1, id:producer}, rs2_dependency:'0};
        step();
        assert (query_result.waw_block && query_result.older_mdu_pending && !query_result.rs1_forward.valid)
            else $fatal(1, "unfinished RAW/WAW/MDU ownership missing");
        finish(producer, 1'b0);
        step();
        assert (query_result.rs1_forward.valid && query_result.older_mdu_pending)
            else $fatal(1, "MDU completion incorrectly released retirement age");
        // 正常退休沿：D2 改读带写穿透的 RF，而 EX 仍看见即将消失的老生产者。
        retire_ready = 1'b1;
        step();
        retire_ready = 1'b0;
        step();
        query.consumer_id.generation ^= RETIRE_GEN_W'(1);
        step();
        query.consumer_id = consumer;
        query.rs1_dependency.id = consumer;
        step();

        // 异常 producer 仍占名字，无前递；flush 同沿查询不撤销已存在的状态。
        reset_case();
        allocate(5, RET_MDU, producer);
        allocate(6, RET_EXEC, consumer);
        query.dispatch_valid = 1'b1;
        query.rs1_used = 1'b1;
        query.rs1 = 5'd5;
        query.rd = 5'd5;
        query.gpr_write = 1'b1;
        query.consumer_valid = 1'b1;
        query.consumer_id = consumer;
        query.rs1_dependency = '{pending:1'b1, id:producer};
        finish(producer, 1'b1);
        step();
        assert (query_result.rs1_dependency.pending && query_result.waw_block && !query_result.rs1_forward.valid)
            else $fatal(1, "faulting producer fell back to RF");
        flush_all = 1'b1;
        retire_ready = 1'b1;
        step();
        defaults();
        step();

        // x0 与不写 GPR 的条目都不占名字；MDU 年龄与 GPR 写使能互相独立。
        allocate(0, RET_MDU, producer);
        allocate(8, RET_STORE, consumer);
        query.dispatch_valid = 1'b1;
        query.rs1_used = 1'b1;
        query.rs2_used = 1'b1;
        query.rs2 = 5'd8;
        query.rd = 5'd8;
        query.gpr_write = 1'b1;
        query.consumer_valid = 1'b1;
        query.consumer_id = consumer;
        step();
        assert (!query_result.rs1_dependency.pending && !query_result.rs2_dependency.pending &&
                !query_result.waw_block && query_result.older_mdu_pending)
            else $fatal(1, "x0 or a non-GPR writer incorrectly became a producer");

        // 满环同沿退休/复用：新代次不能满足旧 ID；软件下标验证跨物理槽零点的年龄。
        reset_case();
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) allocate(slot + 1, RET_EXEC, producer);
        old_head = model[0].id;
        defaults();
        complete_valid = 1'b1;
        completion.id = old_head;
        completion.result.gpr_data = xlen_t'(73);
        retire_ready = 1'b1;
        alloc_valid = 1'b1;
        alloc_meta.gpr_write = 1'b1;
        alloc_meta.rd = 5'd20;
        alloc_meta.kind = RET_MDU;
        query.dispatch_valid = 1'b1;
        query.rs1_used = 1'b1;
        query.rs1 = 5'd1;
        query.consumer_valid = 1'b1;
        query.consumer_id = producer;
        query.rs1_dependency = '{pending:1'b1, id:old_head};
        #1;
        reused = alloc_id;
        step();
        defaults();
        query.consumer_valid = 1'b1;
        query.consumer_id = reused;
        query.rs1_dependency = '{pending:1'b1, id:old_head};
        finish(model[0].id, 1'b0);
        query.rs1_dependency.id = model[0].id;
        step();
        assert (!query_result.older_mdu_pending && query_result.any_unretired_mdu)
            else $fatal(1, "MDU counted itself as older");

        // 代次回卷后数值为零的 ID 仍然有效；pending/valid 而不是 ID 数值表达存在性。
        reset_case();
        for (int allocation = 0; allocation < RETIRE_ENTRIES * (1 << RETIRE_GEN_W); allocation++) begin
            allocate(5, RET_MDU, producer);
            if (producer == '0) begin
                allocate(6, RET_EXEC, consumer);
                query.consumer_valid = 1'b1;
                query.consumer_id = consumer;
                query.rs1_dependency = '{pending:1'b1, id:producer};
                finish(producer, 1'b0);
                step();
                assert (query_result.rs1_forward.valid && query_result.rs1_forward.id == '0 &&
                        query_result.consumer_live && query_result.older_mdu_pending)
                    else $fatal(1, "live zero ID was rejected");
                zero_id++;
                break;
            end
            retire_ready = 1'b1;
            finish(producer, 1'b0);
        end
        assert (zero_id == 1) else $fatal(1, "zero ID coverage missing");
        reset_case();

        // 固定种子随机合法流：分配无重名写者，完成/退休/取消与查询彼此独立。
        for (int cycle = 0; cycle < 700; cycle++) begin
            defaults();
            query.dispatch_valid = 1'b1;
            query.rs1_used = 1'(random_word());
            query.rs2_used = 1'(random_word());
            query.rs1 = gpr_addr_t'(random_word());
            query.rs2 = gpr_addr_t'(random_word());
            query.rd = gpr_addr_t'(random_word());
            query.gpr_write = 1'b1;
            if (model.size() != 0) begin
                ci = int'(random_word() % 32'(model.size()));
                pi = int'(random_word() % 32'(model.size()));
                query.consumer_valid = 1'b1;
                query.consumer_id = model[ci].id;
                query.rs1_dependency = '{pending:1'b1, id:model[pi].id};
                query.rs2_dependency = '{pending:1'b1, id:model[0].id};
                if (cycle % 7 == 0) query.consumer_id.generation ^= RETIRE_GEN_W'(1);
                if (cycle % 11 == 0) query.rs1_dependency.id.generation ^= RETIRE_GEN_W'(1);
                retire_ready = 1'(random_word());
                complete_valid = !model[pi].done;
                completion.id = model[pi].id;
                completion.result.gpr_data = xlen_t'(random_word()) ^ (xlen_t'(random_word()) << (XLEN/2));
                completion.result.exc.valid = cycle % 17 == 0;
            end
            rd_candidate = int'(random_word() % 31) + 1;
            for (int attempt = 0; attempt < 31; attempt++) begin
                used_rd = 1'b0;
                foreach (model[index])
                    if (model[index].meta.gpr_write && model[index].meta.rd == gpr_addr_t'(rd_candidate)) used_rd = 1'b1;
                if (!used_rd) break;
                rd_candidate = (rd_candidate % 31) + 1;
            end
            alloc_valid = 1'(random_word());
            alloc_meta.gpr_write = (cycle % 5 != 0);
            alloc_meta.rd = gpr_addr_t'(rd_candidate);
            alloc_meta.kind = (cycle % 3 == 0) ? RET_MDU : RET_EXEC;
            flush_all = (cycle % 73 == 0);
            step();
        end
        assert (same_edge >= 2 && stale_checks > 20 && fault_checks > 0 &&
                mdu_checks > 20 && full_replace > 0 && wraps > 3)
            else $fatal(1, "query coverage missing");
        $display("PASS tb_retire_gpr_query RV%0d depth=%0d seed=%0d checks=%0d same_edge=%0d stale=%0d faults=%0d mdu=%0d full_replace=%0d wraps=%0d zero_id=%0d",
                 XLEN, RETIRE_ENTRIES, seed, checks, same_edge, stale_checks, fault_checks, mdu_checks, full_replace, wraps, zero_id);
        $finish;
    end
endmodule
