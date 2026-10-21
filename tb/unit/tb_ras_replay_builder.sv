// Module: tb_ras_replay_builder
// Description: Checks RAS replay order against an independent software age list and complete-ID model.
module tb_ras_replay_builder;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import predictor_types_pkg::*;

    retire_ras_entry_t entries [RETIRE_ENTRIES];
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic normal_retire, flush_all, ex_exception_valid, dispatch_fire, d1_advance;
    retire_id_t retiring_id, ex_exception_id;
    retire_alloc_t alloc_meta;
    d1_d2_t d1_packet;
    logic [RETIRE_ENTRIES+1:0] replay_valid;
    ras_event_t replay [RETIRE_ENTRIES+2];

    // 参考模型按程序年龄保存 owner；物理槽布局仅在发布输入时生成。
    // 未读 DUT 的旋转索引或输出建期望；valid 的完成项和未完成项都必须保留。
    retire_id_t age_ids [RETIRE_ENTRIES];
    ras_event_t age_events [RETIRE_ENTRIES];
    bit age_faults [RETIRE_ENTRIES];
    int live_count, checks = 0, replayed = 0;
    int same_slot = 0, stale_retire = 0, stale_exception = 0, flush_checks = 0;
    ras_op_e expected_d1_op;
    int unsigned seed = 32'h4a39_27d1;
    int unsigned initial_seed;

    ras_replay_builder dut (.normal_retire_1(1'b0), .retiring_id_1('0), .*);

    function automatic int unsigned random_word();
        seed = seed ^ (seed << 13);
        seed = seed ^ (seed >> 17);
        seed = seed ^ (seed << 5);
        return seed;
    endfunction

    task automatic initialize(input int count, input int head);
        live_count = count;
        head_slot = RETIRE_IDX_W'(head);
        normal_retire = 0; flush_all = 0; ex_exception_valid = 0;
        dispatch_fire = 0; d1_advance = 0;
        retiring_id = '0; ex_exception_id = '0;
        alloc_meta = '0; d1_packet = '0; expected_d1_op = RAS_NONE;
        for (int age = 0; age < RETIRE_ENTRIES; age++) begin
            age_ids[age] = '{slot:RETIRE_IDX_W'((head+age) % RETIRE_ENTRIES),
                             generation:RETIRE_GEN_W'(checks+age)};
            age_events[age] = '{op:RAS_PUSH,
                addr:xlen_t'(64'h1234_0000_0000_1000) + xlen_t'(checks*4096+age*4)};
            age_faults[age] = 0;
        end
        alloc_meta.ras_op = RAS_PUSH;
        alloc_meta.seq_pc = xlen_t'(64'habcd_0000_0000_0800) + xlen_t'(checks*4096);
        d1_packet.seq_pc = xlen_t'(64'hfedc_0000_0000_0c00) + xlen_t'(checks*4096);
    endtask

    // 指令与预期 hint 成对明确指定，参考不调用 DUT decoder 或其函数。
    task automatic set_d1(input int variant);
        unique case (variant)
            0: begin d1_packet.inst = 32'h0000_0013; expected_d1_op = RAS_NONE; end
            1: begin d1_packet.inst = 32'h0000_00ef; expected_d1_op = RAS_PUSH; end
            2: begin d1_packet.inst = 32'h0000_8067; expected_d1_op = RAS_POP; end
            3: begin d1_packet.inst = 32'h0000_82e7; expected_d1_op = RAS_POP_PUSH; end
            4: begin d1_packet.inst = 32'h0000_80e7; expected_d1_op = RAS_PUSH; end
            default: begin d1_packet.inst = 32'h0000_9067; expected_d1_op = RAS_NONE; end
        endcase
    endtask

    task automatic check(input string label_text, input int required_count = -1);
        ras_event_t expected [RETIRE_ENTRIES+2];
        int expected_count, observed_count;
        expected_count = 0;
        foreach (entries[i]) begin
            // 无效槽带非零毒化载荷，防止只检查 op 而遗漏 valid。
            entries[i] = '{valid:1'b0, id:'1,
                event_info:'{op:RAS_POP_PUSH, addr:'1}, exception:1'b0};
        end
        for (int age = 0; age < live_count; age++) begin
            entries[int'(age_ids[age].slot)] = '{valid:1'b1, id:age_ids[age],
                event_info:age_events[age], exception:age_faults[age]};
            if (!flush_all && !age_faults[age] && age_events[age].op != RAS_NONE &&
                !(normal_retire && age_ids[age] == retiring_id) &&
                !(ex_exception_valid && age_ids[age] == ex_exception_id)) begin
                expected[expected_count] = age_events[age];
                expected_count++;
            end
        end
        if (!flush_all && dispatch_fire && alloc_meta.ras_op != RAS_NONE) begin
            expected[expected_count] = '{op:alloc_meta.ras_op, addr:alloc_meta.seq_pc};
            expected_count++;
        end
        if (!flush_all && d1_advance && d1_packet.valid && !d1_packet.exc.valid &&
            expected_d1_op != RAS_NONE) begin
            expected[expected_count] = '{op:expected_d1_op, addr:d1_packet.seq_pc};
            expected_count++;
        end
        #1;
        observed_count = 0;
        for (int pos = 0; pos < RETIRE_ENTRIES+2; pos++) begin
            if (replay_valid[pos]) begin
                assert (observed_count < expected_count)
                    else $fatal(1, "%s: unexpected replay event at %0d", label_text, pos);
                assert (replay[pos] == expected[observed_count])
                    else $fatal(1, "%s: wrong age/content at event %0d actual=%h expected=%h",
                                label_text, observed_count, replay[pos], expected[observed_count]);
                observed_count++;
            end
        end
        assert (observed_count == expected_count &&
                (required_count < 0 || observed_count == required_count))
            else $fatal(1, "%s: replay count actual=%0d expected=%0d required=%0d",
                        label_text, observed_count, expected_count, required_count);
        checks++; replayed += observed_count;
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin end
        assert (seed != 0) else $fatal(1, "SEED must be nonzero");
        initial_seed = seed;
        // 满环 head 逐槽旋转；旧 head 退休进入 committed，新代次 D2 只能追加在最年轻端。
        // builder 不接新 alloc ID，其资格由真实 dispatch_fire 保证，不把旧槽当成新指令。
        for (int head = 0; head < RETIRE_ENTRIES; head++) begin
            initialize(RETIRE_ENTRIES, head);
            check("full age rotation", RETIRE_ENTRIES);
            normal_retire = 1; retiring_id = age_ids[0]; dispatch_fire = 1;
            d1_advance = 1; d1_packet.valid = 1; set_d1(1);
            check("retire same-slot allocation plus cold D1", RETIRE_ENTRIES+1); same_slot++;
            retiring_id.generation = retiring_id.generation + RETIRE_GEN_W'(1);
            check("stale generation does not remove old owner", RETIRE_ENTRIES+2); stale_retire++;
            retiring_id = age_ids[0]; ex_exception_valid = 1; ex_exception_id = age_ids[1];
            check("same-edge EX exception removed before completion", RETIRE_ENTRIES);
            ex_exception_id.generation = ex_exception_id.generation + RETIRE_GEN_W'(1);
            check("stale EX generation keeps current owner", RETIRE_ENTRIES+1); stale_exception++;
            flush_all = 1;
            check("global flush overrides all replay inputs", 0); flush_checks++;
        end

        // D1 缺 valid、未实际推进或存在异常均无事件，合法 call/return/coroutine 逐项验证。
        for (int variant = 0; variant < 6; variant++) begin
            for (int qualifiers = 0; qualifiers < 8; qualifiers++) begin
                initialize(0, 0); set_d1(variant);
                d1_packet.valid = qualifiers[0]; d1_advance = qualifiers[1];
                d1_packet.exc.valid = qualifiers[2];
                check("D1 hint and qualification");
            end
        end

        // 随机组合验证模块输入优先级，不声称所有组合都属于合法上游生产者协议。
        // 软件列表先决定年龄，再发布环形槽；同 slot 不同 generation 必须区别对待。
        for (int trial = 0; trial < 3000; trial++) begin
            int count, head, selected;
            count = int'(random_word() % (RETIRE_ENTRIES+1));
            head = int'(random_word() % RETIRE_ENTRIES);
            initialize(count, head);
            for (int age = 0; age < count; age++) begin
                age_ids[age].generation = RETIRE_GEN_W'(random_word());
                age_events[age].op = ras_op_e'(2'(random_word()));
                age_faults[age] = (random_word() % 8) == 0;
            end
            flush_all = (random_word() % 8) == 0;
            normal_retire = count > 0 && (random_word() % 2) == 0;
            if (normal_retire) begin
                retiring_id = age_ids[0];
                if ((random_word() % 4) == 0)
                    retiring_id.generation = retiring_id.generation + RETIRE_GEN_W'(1);
            end
            ex_exception_valid = count > 0 && (random_word() % 2) == 0;
            if (ex_exception_valid) begin
                selected = int'(random_word() % count);
                ex_exception_id = age_ids[selected];
                if ((random_word() % 4) == 0)
                    ex_exception_id.generation = ex_exception_id.generation + RETIRE_GEN_W'(1);
            end
            dispatch_fire = 1'(random_word());
            alloc_meta.ras_op = ras_op_e'(2'(random_word()));
            d1_packet.valid = 1'(random_word()); d1_advance = 1'(random_word());
            d1_packet.exc.valid = 1'(random_word());
            set_d1(int'(random_word() % 6));
            check("random age replay");
        end
        assert (same_slot == RETIRE_ENTRIES && stale_retire == RETIRE_ENTRIES &&
                stale_exception == RETIRE_ENTRIES && flush_checks == RETIRE_ENTRIES)
            else $fatal(1, "directed replay coverage missing");
        $display("PASS tb_ras_replay_builder RV%0d entries=%0d seed=%0d checks=%0d replayed=%0d same_slot=%0d stale_retire=%0d stale_exception=%0d flush=%0d",
                 XLEN, RETIRE_ENTRIES, initial_seed, checks, replayed, same_slot,
                 stale_retire, stale_exception, flush_checks);
        $finish;
    end
endmodule
