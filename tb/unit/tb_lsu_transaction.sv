// Module: tb_lsu_transaction
// Description: Independently checks one LSU owner, registered responses, cancellation, and queue handoff.
module tb_lsu_transaction;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic cancel, manual_cancel, issue_valid, issue_ready, head_valid, manual_head_valid;
    lsu_descriptor_t descriptor;
    retire_id_t head_id, manual_head_id, owner_id;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write, dmem_rsp_valid, dmem_rsp_ready;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_error, complete_valid, complete_ready, manual_complete_ready;
    retire_completion_t completion;
    retire_gpr_forward_t registered_forward;
    logic busy, draining, owner_valid, request_pending;
    logic queue_mode, auto_trap, alloc_valid, alloc_ready, queue_ready, complete_reject;
    logic queue_head_valid, queue_head_complete, retire_ready, retire_fire, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;
    retire_id_t probe_id [5];
    logic [4:0] probe_accept;
    initial for (int probe = 0; probe < 5; probe++) probe_id[probe] = '0;
    retire_id_t alloc_id, queue_head_id;
    retire_alloc_t alloc_meta, head_meta;
    retire_result_t head_result;

    // 参考仅保存端口握手历史；不读取 DUT 状态、响应槽或队列内部数组。
    logic model_live = 1'b0, model_issued = 1'b0, model_response = 1'b0, model_killed = 1'b0;
    lsu_descriptor_t model_owner;
    xlen_t model_data;
    logic model_error;
    int cycle = 0, req_cycle = 0, rsp_cycle = 0, outstanding = 0;
    int checks = 0, issued = 0, requests = 0, responses = 0, completions = 0;
    int stores = 0, reads = 0, faults = 0, cancelled_completions = 0, drained = 0;
    int head_wait = 0, request_hold = 0, completion_hold = 0, response_hold = 0;
    int replacements = 0, fastest = 0, cancelled_prep = 0, cancelled_wait = 0;
    int cancelled_result = 0, cancelled_rsp = 0, cancelled_req = 0, resets_live = 0;
    int queue_rejections = 0, queue_traps = 0, transactions = 0, reused_after_drain = 0;
    int poisoned_busy_cycles = 0;
    logic negative_head;
    logic previous_req_hold = 1'b0, previous_complete_hold = 1'b0, previous_rsp_hold = 1'b0;
    lsu_descriptor_t held_request;
    retire_completion_t held_completion;
    xlen_t held_response;
    logic held_error;
    int unsigned random_state, seed, serial = 0;

    always #5 clk = ~clk;
    assign cancel = manual_cancel || (queue_mode && auto_trap && retire_fire && head_result.exc.valid);
    assign head_valid = queue_mode ? queue_head_valid : manual_head_valid;
    assign head_id = queue_mode ? queue_head_id : manual_head_id;
    assign complete_ready = queue_mode ? queue_ready : manual_complete_ready;
    lsu_transaction dut (.*);
    retire_queue u_queue (
        .ras_entries(), .ras_head_slot(),
        .clk, .rst, .flush_all(queue_mode && cancel), .drain_complete(!busy),
        .alloc_valid, .alloc_ready, .alloc_meta, .alloc_id,
        .complete_valid(queue_mode && complete_valid), .complete_ready(queue_ready),
        .completion, .complete_reject, .probe_id(probe_id), .probe_accept(probe_accept),
        .query('0), .query_result(),
        .head_valid(queue_head_valid), .head_complete(queue_head_complete),
        .head_id(queue_head_id), .head_meta, .head_result,
        .retire_ready, .retire_fire, .occupancy, .recovering
    );

    // 字节逐位参考，与 DUT 的移位/拼接格式化实现独立。
    function automatic xlen_t formatted(input xlen_t raw, input lsu_descriptor_t op);
        xlen_t value;
        int bits, start;
        bits = 8 << int'(op.size);
        start = 8 * int'(op.address % XLEN'(DBUS_BYTES));
        value = '0;
        for (int b = 0; b < XLEN; b++) begin
            if (b < bits && start + b < XLEN) value[b] = raw[start+b];
            else if (b >= bits && !op.unsigned_load) value[b] = raw[start+bits-1];
        end
        return value;
    endfunction
    function automatic int unsigned random_word;
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction
    function automatic lsu_descriptor_t make_descriptor(input int size_value, input int lane,
                                                         input logic wr, input logic unsign);
        lsu_descriptor_t value;
        value = '0;
        value.id.slot = RETIRE_IDX_W'(serial % RETIRE_ENTRIES);
        value.id.generation = RETIRE_GEN_W'(serial / RETIRE_ENTRIES);
        value.address = XLEN'('h1000 + lane);
        if (XLEN == 64) value.address = value.address | (XLEN'(1) << 40);
        value.write = wr;
        value.size = mem_size_e'(size_value);
        value.unsigned_load = unsign;
        value.wdata = XLEN'(64'h81fe_9023_ff80_a57e);
        for (int b = 0; b < DBUS_BYTES; b++)
            value.wstrb[b] = wr && b >= lane && b < lane + (1 << size_value);
        serial++;
        return value;
    endfunction

    always @(posedge clk) begin
        retire_completion_t expected;
        logic expected_request, expected_complete, was_result;
        cycle++;
        if (rst) begin
            if (model_live) resets_live++;
            model_live = 1'b0;
            model_issued = 1'b0;
            model_response = 1'b0;
            model_killed = 1'b0;
            outstanding = 0;
            previous_req_hold = 1'b0;
            previous_complete_hold = 1'b0;
            previous_rsp_hold = 1'b0;
        end else begin
            expected_request = model_live && !model_issued && head_valid && head_id == model_owner.id;
            expected_complete = model_live && model_response && !model_killed;
            was_result = expected_complete;
            assert (busy == model_live && owner_valid == model_live && draining == model_killed)
                else $fatal(1, "owner lifetime mismatch cycle=%0d", cycle);
            if (model_live) assert (owner_id == model_owner.id) else $fatal(1, "owner ID changed");
            assert (dmem_req_valid == expected_request && complete_valid == expected_complete)
                else $fatal(1, "request/completion boundary mismatch cycle=%0d", cycle);
            assert (dmem_rsp_ready == (model_live && model_issued && !model_response))
                else $fatal(1, "response owner/ready mismatch");
            assert (issue_ready == (!cancel && (!model_live || (expected_complete && complete_ready))))
                else $fatal(1, "descriptor turnover added a bubble or reused live owner");
            if (dmem_req_valid) begin
                assert ({dmem_req_addr, dmem_req_write, dmem_req_size, dmem_req_wdata, dmem_req_wstrb} ==
                        {model_owner.address, model_owner.write, model_owner.size, model_owner.wdata, model_owner.wstrb})
                    else $fatal(1, "request changed after descriptor acceptance");
            end
            if (previous_req_hold && !negative_head) begin
                assert (dmem_req_valid && {dmem_req_addr, dmem_req_write, dmem_req_size, dmem_req_wdata, dmem_req_wstrb} ==
                        {held_request.address, held_request.write, held_request.size, held_request.wdata, held_request.wstrb})
                    else $fatal(1, "request violated backpressure hold");
            end
            if (previous_complete_hold)
                assert (complete_valid && completion == held_completion)
                    else $fatal(1, "completion violated backpressure hold");
            if (previous_rsp_hold)
                assert (dmem_rsp_valid && dmem_rsp_rdata == held_response && dmem_rsp_error == held_error)
                    else $fatal(1, "TB response producer violated backpressure hold");
            previous_req_hold = dmem_req_valid && !dmem_req_ready;
            held_request = model_owner;
            previous_complete_hold = complete_valid && !complete_ready && !cancel;
            held_completion = completion;
            previous_rsp_hold = dmem_rsp_valid && !dmem_rsp_ready;
            held_response = dmem_rsp_rdata;
            held_error = dmem_rsp_error;
            request_hold += int'(previous_req_hold);
            completion_hold += int'(complete_valid && !complete_ready);
            response_hold += int'(previous_rsp_hold);
            head_wait += int'(model_live && !model_issued && !dmem_req_valid);

            expected = '0;
            expected.id = model_owner.id;
            if (!model_owner.write) expected.result.gpr_data = model_data;
            if (model_error) expected.result.exc = '{valid:1'b1,
                cause:model_owner.write ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT,
                tval:model_owner.address};
            if (complete_valid) begin
                assert (completion == expected && cycle > rsp_cycle)
                    else $fatal(1, "formatted data/fault/ID mismatch or raw response bypass");
            end
            assert (registered_forward.valid == (expected_complete && !model_owner.write && !model_error))
                else $fatal(1, "forward valid includes store/fault/raw response");
            if (registered_forward.valid)
                assert (registered_forward.id == model_owner.id && registered_forward.data == model_data)
                    else $fatal(1, "registered forward mismatch");

            if (dmem_req_valid && dmem_req_ready) begin
                assert (!model_issued && outstanding == 0) else $fatal(1, "second LSU request/side effect");
                model_issued = 1'b1;
                outstanding++;
                req_cycle = cycle;
                requests++;
                if (model_owner.write) stores++; else reads++;
                if (cancel) cancelled_req++;
            end
            if (dmem_rsp_valid && dmem_rsp_ready) begin
                assert (outstanding == 1 && cycle > req_cycle) else $fatal(1, "response had no accepted owner");
                outstanding--;
                responses++;
                rsp_cycle = cycle;
                model_data = formatted(dmem_rsp_rdata, model_owner);
                model_error = dmem_rsp_error;
                model_response = 1'b1;
                if (model_killed) begin
                    drained++;
                    model_live = 1'b0;
                    model_killed = 1'b0;
                end
                if (cancel) cancelled_rsp++;
            end
            if (complete_valid && complete_ready) begin
                assert (outstanding == 0) else $fatal(1, "completion preceded response");
                completions++;
                if (model_error) faults++;
                if (cycle == req_cycle + 2) fastest++;
                if (cancel) cancelled_completions++;
                model_live = 1'b0;
            end
            if (cancel) begin
                if (was_result) cancelled_result++;
                else if (model_live && !model_issued) cancelled_prep++;
                else if (model_live && model_issued && !model_response) cancelled_wait++;
                if (model_live && model_issued && !model_response) model_killed = 1'b1;
                else begin model_live = 1'b0; model_killed = 1'b0; end
            end
            if (issue_valid && issue_ready) begin
                assert (!model_live && outstanding == 0) else $fatal(1, "ID reused before drain");
                if (complete_valid && complete_ready) replacements++;
                model_owner = descriptor;
                model_live = 1'b1;
                model_issued = 1'b0;
                model_response = 1'b0;
                model_killed = 1'b0;
                model_error = 1'b0;
                model_data = '0;
                issued++;
            end
            if (queue_mode && complete_reject) queue_rejections++;
            if (queue_mode && retire_fire && head_result.exc.valid) queue_traps++;
            checks++;
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic defaults;
        manual_cancel = 1'b0;
        issue_valid = 1'b0;
        descriptor = '0;
        manual_head_valid = 1'b0;
        manual_head_id = '0;
        dmem_req_ready = 1'b0;
        dmem_rsp_valid = 1'b0;
        dmem_rsp_rdata = '0;
        dmem_rsp_error = 1'b0;
        manual_complete_ready = 1'b0;
        queue_mode = 1'b0;
        auto_trap = 1'b0;
        alloc_valid = 1'b0;
        alloc_meta = '0;
        retire_ready = 1'b0;
    endtask
    task automatic coordinated_reset;
        // 此操作同时清仿真总线生产者及参考 owner，不声称支持单边 Core reset。
        rst = 1'b1;
        defaults();
        negative_head = $test$plusargs("NEGATIVE_HEAD");
        tick();
        assert (!busy && !complete_valid && !dmem_rsp_ready) else $fatal(1, "reset did not clear owner");
        rst = 1'b0;
        tick();
    endtask
    task automatic launch(input lsu_descriptor_t op);
        descriptor = op;
        issue_valid = 1'b1;
        tick();
        assert (busy && owner_id == op.id) else $fatal(1, "descriptor was not accepted");
        issue_valid = 1'b0;
        descriptor = '1; // 接受后故意改变总线，不能改变在途地址/载荷。
        manual_head_id = op.id;
        manual_head_valid = 1'b1;
    endtask
    task automatic request_accept;
        dmem_req_ready = 1'b1;
        tick();
        dmem_req_ready = 1'b0;
    endtask
    task automatic respond(input xlen_t data, input logic error);
        dmem_rsp_valid = 1'b1;
        dmem_rsp_rdata = data;
        dmem_rsp_error = error;
        tick();
        dmem_rsp_valid = 1'b0;
        dmem_rsp_rdata = ~data;
        dmem_rsp_error = !error;
    endtask
    task automatic complete;
        manual_complete_ready = 1'b1;
        tick();
        manual_complete_ready = 1'b0;
        manual_head_valid = 1'b0;
        assert (!busy) else $fatal(1, "completed owner not released");
    endtask

    initial begin
        lsu_descriptor_t op, next_op;
        int choice, request_delay, response_delay, complete_delay;
        defaults();
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        random_state = seed == 0 ? 32'h9e3779b9 : seed;
        @(negedge clk);
        coordinated_reset();

        // 禁止撤回已展示请求的契约负例由 runner 独立进程执行，必须以指定断言失败。
        if ($test$plusargs("NEGATIVE_CANCEL") || negative_head) begin
            launch(make_descriptor(0, 0, 1'b1, 1'b0));
            tick();
            if (negative_head) manual_head_valid = 1'b0;
            else manual_cancel = 1'b1;
            tick();
            $fatal(1, "negative test did not trigger its protocol assertion");
        end

        // 全部自然对齐 lane、大小、符号与错误组合，覆盖 RV64 高地址 tval 不截断。
        for (int size = 0; size <= $clog2(DBUS_BYTES); size++) begin
            for (int lane = 0; lane < DBUS_BYTES; lane += (1 << size)) begin
                for (int wr = 0; wr < 2; wr++) begin
                    for (int unsign = 0; unsign < 2; unsign++) begin
                        for (int error = 0; error < 2; error++) begin
                            for (int pattern = 0; pattern < 2; pattern++) begin
                                op = make_descriptor(size, lane, 1'(wr), 1'(unsign));
                                launch(op);
                                request_accept();
                                respond(pattern == 0 ? XLEN'(64'h81fe_9023_ff80_a57e) :
                                                       ~XLEN'(64'h81fe_9023_ff80_a57e), 1'(error));
                                complete();
                                transactions++;
                            end
                        end
                    end
                end
            end
        end

        // 同槽错误代次不可获准；从端在 req_fire 同沿展示响应也须保持到下一沿。
        op = make_descriptor(0, DBUS_BYTES-1, 1'b0, 1'b0);
        launch(op);
        manual_head_id.generation = op.id.generation + RETIRE_GEN_W'(1);
        dmem_req_ready = 1'b1;
        repeat (4) tick();
        manual_head_id = op.id;
        dmem_req_ready = 1'b0;
        repeat (3) tick();
        dmem_rsp_valid = 1'b1;
        dmem_rsp_rdata = XLEN'(64'h81fe_9023_ff80_a57e);
        dmem_rsp_error = 1'b0;
        request_accept();
        tick();
        dmem_rsp_valid = 1'b0;
        repeat (4) tick();
        // 旧完成消费沿接纳下一个描述符，测试不会为统一接口额外插入空拍。
        next_op = make_descriptor(1, 0, 1'b1, 1'b0);
        descriptor = next_op;
        issue_valid = 1'b1;
        manual_complete_ready = 1'b1;
        tick();
        issue_valid = 1'b0;
        manual_complete_ready = 1'b0;
        manual_head_id = next_op.id;
        request_accept();
        respond('0, 1'b0);
        complete();

        // PREP 尚无 head 许可可以取消；req_fire 同沿取消不能撤销副作用，只能排空。
        launch(make_descriptor(0, 0, 1'b0, 1'b0));
        manual_head_valid = 1'b0;
        manual_cancel = 1'b1;
        tick();
        manual_cancel = 1'b0;
        launch(make_descriptor(0, 0, 1'b1, 1'b0));
        manual_cancel = 1'b1;
        request_accept();
        manual_cancel = 1'b0;
        respond('0, 1'b1);
        tick();

        // 有限 generation 完全相同也允许在确实排空之后复用；旧错误响应不能污染新结果。
        op = make_descriptor(0, 0, 1'b0, 1'b1);
        launch(op);
        request_accept();
        manual_cancel = 1'b1;
        tick();
        manual_cancel = 1'b0;
        descriptor = op;
        issue_valid = 1'b1;
        repeat (4) tick();
        respond('1, 1'b1);
        issue_valid = 1'b0;
        launch(op);
        request_accept();
        respond(XLEN'('h35), 1'b0);
        complete();
        reused_after_drain++;

        // 纯拒收压力测试刻意改变无握手的输入，不把它称为合法生产者的保持协议。
        // 旧 owner 的请求/完成全包仍由上面的独立握手参考检查。
        op = make_descriptor(1, 0, 1'b0, 1'b0);
        launch(op);
        request_accept();
        issue_valid = 1'b1;
        repeat (4) begin
            descriptor = make_descriptor(0, 1, 1'b1, 1'b1);
            tick();
            poisoned_busy_cycles++;
        end
        respond(XLEN'('ha537), 1'b0);
        repeat (4) begin
            descriptor = make_descriptor(0, 2, 1'b1, 1'b1);
            tick();
            poisoned_busy_cycles++;
        end
        issue_valid = 1'b0;
        complete();

        // 随机延迟只驱动合法生产者；取消覆盖 WAIT、已登记响应及同沿 rsp/complete。
        for (int n = 0; n < 180; n++) begin
            op = make_descriptor(0, int'(random_word() % DBUS_BYTES), 1'(random_word()), 1'(random_word()));
            choice = int'(random_word() % 6);
            request_delay = int'(random_word() % 5);
            response_delay = int'(random_word() % 8);
            complete_delay = int'(random_word() % 5);
            launch(op);
            repeat (request_delay) tick();
            request_accept();
            repeat (response_delay) tick();
            if (choice == 1) begin
                manual_cancel = 1'b1;
                tick();
                manual_cancel = 1'b0;
                // 即使新 ID 数值回卷为相同旧 ID，也必须等旧响应排空。
                descriptor = op;
                issue_valid = 1'b1;
                repeat (3) tick();
                respond(XLEN'(random_word()), 1'b1);
                issue_valid = 1'b0;
                tick();
            end else begin
                if (choice == 2) manual_cancel = 1'b1;
                respond(XLEN'(random_word()), n[0]);
                manual_cancel = 1'b0;
                if (choice == 2) tick();
                else begin
                    repeat (complete_delay) tick();
                    if (choice == 3 || choice == 4) manual_cancel = 1'b1;
                    if (choice == 4) begin
                        tick();
                        manual_cancel = 1'b0;
                    end else begin
                        complete();
                        manual_cancel = 1'b0;
                    end
                end
            end
            transactions++;
        end

        // 协调 reset 覆盖未发请求、已接受等待、结果保持和已取消排空四种生命周期。
        launch(make_descriptor(0, 0, 1'b0, 1'b0));
        coordinated_reset();
        launch(make_descriptor(0, 0, 1'b0, 1'b0));
        request_accept();
        coordinated_reset();
        launch(make_descriptor(0, 0, 1'b0, 1'b0));
        request_accept();
        respond('1, 1'b0);
        coordinated_reset();
        launch(make_descriptor(0, 0, 1'b0, 1'b0));
        request_accept();
        manual_cancel = 1'b1;
        tick();
        coordinated_reset();

        // 真实 queue 接口：未 complete 的 head 即可授权请求；外部取消关闭 retire_ready。
        // 随后由 fault completion→head旁路→Trap cancel 形成真实组合依赖，验证没有环。
        queue_mode = 1'b1;
        for (int scenario = 0; scenario < 2; scenario++) begin
            while (!alloc_ready) tick();
            op = make_descriptor(0, 1, 1'b0, 1'b0);
            op.id = alloc_id;
            alloc_meta = '0;
            alloc_meta.kind = RET_LOAD;
            alloc_meta.pc = XLEN'('h1000);
            alloc_meta.seq_pc = XLEN'('h1004);
            alloc_valid = 1'b1;
            tick();
            alloc_valid = 1'b0;
            launch(op);
            assert (queue_head_valid && !queue_head_complete) else $fatal(1, "queue setup already complete");
            request_accept();
            if (scenario == 1) begin auto_trap = 1'b1; retire_ready = 1'b1; end
            respond(XLEN'('h80ff), 1'b1);
            if (scenario == 0) manual_cancel = 1'b1;
            tick();
            manual_cancel = 1'b0;
            auto_trap = 1'b0;
            retire_ready = 1'b0;
            assert (!busy && occupancy == 0) else $fatal(1, "queue flush failed to release owner");
            tick();
        end
        queue_mode = 1'b0;
        tick();
        assert (outstanding == 0 && !busy && !complete_valid) else $fatal(1, "final drain incomplete");
        assert (head_wait >= 4 && request_hold > 3 && completion_hold > 4 && response_hold >= 1 &&
                replacements == 1 && fastest > 0 && cancelled_prep > 0 && cancelled_wait > 0 &&
                cancelled_result > 0 && cancelled_rsp > 0 && cancelled_req == 1 && drained > 0 &&
                cancelled_completions > 0 && resets_live == 4 && queue_rejections == 1 && queue_traps == 1 &&
                reused_after_drain == 1 && poisoned_busy_cycles == 8)
            else $fatal(1, "coverage missing head=%0d reqhold=%0d comphold=%0d rsphold=%0d replace=%0d fastest=%0d prep=%0d wait=%0d result=%0d rsp=%0d req=%0d drain=%0d canccomp=%0d resets=%0d reject=%0d traps=%0d",
                head_wait, request_hold, completion_hold, response_hold, replacements, fastest,
                cancelled_prep, cancelled_wait, cancelled_result, cancelled_rsp, cancelled_req,
                drained, cancelled_completions, resets_live, queue_rejections, queue_traps);
        $display("PASS tb_lsu_transaction RV%0d seed=%0d checks=%0d transactions=%0d issue=%0d req=%0d rsp=%0d completion=%0d stores=%0d reads=%0d faults=%0d fastest=%0d replace=%0d head_wait=%0d req_hold=%0d rsp_hold=%0d completion_hold=%0d drain=%0d cancel_complete=%0d reset=%0d queue_reject=%0d queue_trap=%0d reused_after_drain=%0d poison=%0d",
                 XLEN, seed, checks, transactions, issued, requests, responses, completions, stores,
                 reads, faults, fastest, replacements, head_wait, request_hold, response_hold,
                 completion_hold, drained, cancelled_completions, resets_live, queue_rejections, queue_traps,
                 reused_after_drain, poisoned_busy_cycles);
        $finish;
    end
    initial begin
        repeat (12000) @(posedge clk);
        $fatal(1, "LSU test timeout");
    end
endmodule
