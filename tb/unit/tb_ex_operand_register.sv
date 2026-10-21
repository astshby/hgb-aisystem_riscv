// Module: tb_ex_operand_register
// Description: Checks independent operand capture, ID isolation, ALU throughput, and real queue/RF retirement edges.
module tb_ex_operand_register;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    pipe_action_e action;
    d2_ex_t in_packet, out_packet;
    retire_gpr_forward_t queue_rs1, queue_rs2, wb_forward, lsu_forward, mdu_forward, mem_forward;
    retire_gpr_forward_t manual_q1, manual_q2, manual_wb;
    xlen_t rs1_value, rs2_value, alu_result, rf1, rf2;
    logic operands_ready, queue_mode;
    logic qflush, alloc_valid, alloc_ready, complete_valid, complete_ready, complete_reject;
    logic head_valid, head_complete, retire_ready, retire_fire, recovering;
    logic [RETIRE_COUNT_W-1:0] occupancy;
    retire_alloc_t alloc_meta, head_meta;
    retire_id_t alloc_id, head_id;
    retire_completion_t completion;
    retire_result_t head_result;
    retire_query_t query;
    retire_query_result_t query_result;
    int checks = 0, ii1_cycles = 0, partial_captures = 0, retired_sources = 0;
    int retire_lookup_partial = 0, capacity_adapted = 0;

    always #5 clk = ~clk;
    ex_operand_register dut (.aux_forward('0), .*);
    alu u_alu (.operand_a(rs1_value), .operand_b(rs2_value), .operation(ALU_ADD),
               .op_width(OP_WIDTH_XLEN), .result(alu_result));
    retire_queue u_queue (
        .ras_entries(), .ras_head_slot(),
        .clk, .rst, .flush_all(qflush), .drain_complete(1'b1),
        .alloc_valid, .alloc_ready, .alloc_meta, .alloc_id,
        .complete_valid, .complete_ready, .completion, .complete_reject,
        .query, .query_result,
        .head_valid, .head_complete, .head_id, .head_meta, .head_result,
        .retire_ready, .retire_fire, .occupancy, .recovering
    );
    regfile u_regfile (
        .clk, .rs1_addr(in_packet.rs1), .rs2_addr(in_packet.rs2), .rs1_data(rf1), .rs2_data(rf2),
        .write_enable(retire_fire && !head_result.exc.valid && head_meta.gpr_write),
        .write_addr(head_meta.rd), .write_data(head_result.gpr_data)
    );
    always_comb begin
        query = '0;
        if (queue_mode) begin
            query.dispatch_valid = alloc_valid;
            query.rs1_used = in_packet.uop.rs1_used;
            query.rs2_used = in_packet.uop.rs2_used;
            query.rs1 = in_packet.rs1;
            query.rs2 = in_packet.rs2;
            query.rd = in_packet.rd;
            query.gpr_write = in_packet.uop.gpr_write;
            query.consumer_valid = out_packet.valid;
            query.consumer_id = out_packet.retire_id;
            query.rs1_dependency = out_packet.rs1_dependency;
            query.rs2_dependency = out_packet.rs2_dependency;
        end
        queue_rs1 = queue_mode ? query_result.rs1_forward : manual_q1;
        queue_rs2 = queue_mode ? query_result.rs2_forward : manual_q2;
        wb_forward = manual_wb;
        if (queue_mode)
            wb_forward = '{valid:complete_valid && !completion.result.exc.valid,
                           id:completion.id, data:completion.result.gpr_data};
    end

    // 同 ID 的合法多副本必须一致；该检查与 DUT 的来源优先选择相互独立。
    always @(posedge clk) begin
        retire_gpr_forward_t copies [6];
        copies = '{queue_rs1, queue_rs2, wb_forward, lsu_forward, mdu_forward, mem_forward};
        if (!rst) begin
            for (int first = 0; first < 6; first++)
                for (int second = first + 1; second < 6; second++)
                    if (copies[first].valid && copies[second].valid && copies[first].id == copies[second].id)
                        assert (copies[first].data == copies[second].data)
                            else $fatal(1, "test source replicas disagree for one ID");
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic clear_forwards;
        manual_q1 = '0;
        manual_q2 = '0;
        manual_wb = '0;
        lsu_forward = '0;
        mdu_forward = '0;
        mem_forward = '0;
    endtask
    task automatic reset_case;
        rst = 1'b1;
        action = PIPE_CLEAR;
        in_packet = '0;
        clear_forwards();
        queue_mode = 1'b0;
        qflush = 1'b0;
        alloc_valid = 1'b0;
        alloc_meta = '0;
        complete_valid = 1'b0;
        completion = '0;
        retire_ready = 1'b0;
        tick();
        rst = 1'b0;
        action = PIPE_HOLD;
        tick();
    endtask
    task automatic make_packet(input retire_id_t id, input gpr_dependency_t source1,
                               input gpr_dependency_t source2, input xlen_t first, input xlen_t second);
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.retire_id = id;
        in_packet.pc = xlen_t'(64'h1234_5678_8000_0000);
        in_packet.inst = 32'h0062_83b3;
        in_packet.uop.rs1_used = 1'b1;
        in_packet.uop.rs2_used = 1'b1;
        in_packet.uop.gpr_write = 1'b1;
        in_packet.rs1 = 5'd5;
        in_packet.rs2 = 5'd6;
        in_packet.rd = 5'd7;
        in_packet.rs1_data = first;
        in_packet.rs2_data = second;
        in_packet.rs1_dependency = source1;
        in_packet.rs2_dependency = source2;
    endtask
    task automatic install;
        action = PIPE_ADVANCE;
        tick();
        action = PIPE_HOLD;
    endtask
    task automatic check(input logic ready, input xlen_t first, input xlen_t second);
        #1;
        assert (out_packet.valid && operands_ready == ready && rs1_value == first && rs2_value == second)
            else $fatal(1, "operand mismatch check=%0d ready=%b values=%h/%h expected=%h/%h",
                        checks, operands_ready, rs1_value, rs2_value, first, second);
        checks++;
    endtask
    task automatic allocate_entry(input gpr_addr_t rd, input retire_kind_e kind, output retire_id_t id);
        alloc_meta = '0;
        alloc_meta.kind = kind;
        alloc_meta.rd = rd;
        alloc_meta.gpr_write = 1'b1;
        alloc_valid = 1'b1;
        #1;
        assert (alloc_ready) else $fatal(1, "producer allocation failed");
        id = alloc_id;
        tick();
        alloc_valid = 1'b0;
    endtask
    task automatic allocate_producer(output retire_id_t id);
        allocate_entry(5'd5, RET_MDU, id);
    endtask
    task automatic prepare_consumer;
        alloc_meta = '0;
        alloc_meta.kind = RET_EXEC;
        alloc_meta.rd = 5'd7;
        alloc_meta.gpr_write = 1'b1;
        alloc_valid = 1'b1;
        make_packet(alloc_id, '0, '0, xlen_t'(999), xlen_t'(1));
        in_packet.uop.rs2_used = 1'b0;
        #1;
        in_packet.retire_id = alloc_id;
        in_packet.rs1_dependency = query_result.rs1_dependency;
        in_packet.rs2_dependency = query_result.rs2_dependency;
    endtask

    initial begin
        retire_id_t first_id, second_id, third_id, producer, reused;
        xlen_t prior_result;
        first_id = retire_id_t'(1);
        second_id = retire_id_t'(2);
        third_id = retire_id_t'(3);
        @(negedge clk);
        reset_case();
        make_packet(third_id, '0, '0, xlen_t'(37), xlen_t'(49));
        install();
        check(1'b1, xlen_t'(37), xlen_t'(49));
        // x0/未使用源不等待，即使驱动附带了不应使用的 dependency。
        make_packet(third_id, '{pending:1'b1, id:first_id}, '{pending:1'b1, id:second_id}, '1, '1);
        in_packet.rs1 = '0;
        in_packet.uop.rs2_used = 1'b0;
        install();
        check(1'b1, '0, '0);

        // 相同槽不同代次不能前递；pending 没就绪时不能回退到故意填错的 RF 快照。
        make_packet(third_id, '{pending:1'b1, id:first_id}, '{pending:1'b1, id:second_id}, xlen_t'(999), xlen_t'(888));
        install();
        mem_forward = '{valid:1'b1, id:first_id, data:xlen_t'(100)};
        mem_forward.id.generation ^= RETIRE_GEN_W'(1);
        check(1'b0, '0, '0);
        clear_forwards();
        // rs1 先到并离开所有前递口，仍要等 rs2；源按各自第一次可用独立捕获。
        manual_wb = '{valid:1'b1, id:first_id, data:xlen_t'(41)};
        check(1'b0, xlen_t'(41), '0);
        tick();
        clear_forwards();
        repeat (5) begin
            check(1'b0, xlen_t'(41), '0);
            tick();
        end
        partial_captures++;
        mdu_forward = '{valid:1'b1, id:second_id, data:xlen_t'(73)};
        check(1'b1, xlen_t'(41), xlen_t'(73));
        tick();
        clear_forwards();
        check(1'b1, xlen_t'(41), xlen_t'(73));

        // LSU 独立寄存结果不依赖仲裁是否选中；完整代次匹配后，本拍使用并捕获。
        make_packet(third_id, '{pending:1'b1, id:first_id}, '0, xlen_t'(999), xlen_t'(5));
        install();
        lsu_forward = '{valid:1'b1, id:first_id, data:xlen_t'(64'hfeed_beef_8000_0081)};
        lsu_forward.id.generation ^= RETIRE_GEN_W'(1);
        check(1'b0, '0, xlen_t'(5));
        lsu_forward.id = first_id;
        // 更高优先完成源可同时携带别的 ID，不能遮蔽未被仲裁选中的 LSU 前递。
        manual_wb = '{valid:1'b1, id:second_id, data:xlen_t'(77)};
        check(1'b1, lsu_forward.data, xlen_t'(5));
        tick();
        clear_forwards();
        check(1'b1, xlen_t'(64'hfeed_beef_8000_0081), xlen_t'(5));

        // 反向到达顺序，MEM 与 queue 已完成值均可直接供本拍执行。
        make_packet(third_id, '{pending:1'b1, id:first_id}, '{pending:1'b1, id:second_id}, '0, '0);
        install();
        mem_forward = '{valid:1'b1, id:second_id, data:xlen_t'(17)};
        check(1'b0, '0, xlen_t'(17));
        tick();
        clear_forwards();
        check(1'b0, '0, xlen_t'(17));
        partial_captures++;
        manual_q1 = '{valid:1'b1, id:first_id, data:xlen_t'(64'hfeed_beef_8000_0011)};
        check(1'b1, manual_q1.data, xlen_t'(17));
        tick();
        clear_forwards();

        // 两个源绑定同一条指令，多口副本相同；已捕获后不再观察变化的旧 ID 总线。
        make_packet(third_id, '{pending:1'b1, id:first_id}, '{pending:1'b1, id:first_id}, '0, '0);
        in_packet.rs2 = in_packet.rs1;
        install();
        manual_q1 = '{valid:1'b1, id:first_id, data:xlen_t'(69)};
        manual_q2 = manual_q1;
        manual_wb = manual_q1;
        mdu_forward = manual_q1;
        mem_forward = manual_q1;
        check(1'b1, xlen_t'(69), xlen_t'(69));
        tick();
        clear_forwards();
        mem_forward = '{valid:1'b1, id:first_id, data:xlen_t'(99)};
        check(1'b1, xlen_t'(69), xlen_t'(69));
        clear_forwards();

        // 每沿替换一条不同 rd 的 ADD，上一条的寄存 MEM 结果当拍供 EX，无额外 capture 拍。
        make_packet(first_id, '0, '0, '0, xlen_t'(1));
        install();
        check(1'b1, '0, xlen_t'(1));
        for (int serial = 1; serial <= 24; serial++) begin
            prior_result = alu_result;
            first_id = out_packet.retire_id;
            make_packet(retire_id_t'(serial + 1), '{pending:1'b1, id:first_id}, '0, '1, xlen_t'(1));
            in_packet.rd = gpr_addr_t'((serial % 29) + 1);
            install();
            mem_forward = '{valid:1'b1, id:first_id, data:prior_result};
            check(1'b1, xlen_t'(serial), xlen_t'(1));
            assert (alu_result == xlen_t'(serial) + xlen_t'(1)) else $fatal(1, "ALU dependency gained a capture cycle");
            ii1_cycles++;
        end
        // 同沿新包/CLEAR 的优先级高于旧源捕获，不得把旧结果写进新指令。
        make_packet(third_id, '0, '0, xlen_t'(7), xlen_t'(8));
        install();
        check(1'b1, xlen_t'(7), xlen_t'(8));
        action = PIPE_CLEAR;
        tick();
        #1;
        assert (!out_packet.valid) else $fatal(1, "flush retained EX owner");

        // 真实 queue：源完成同拍通过 WB 捕获，下一拍退休后该源不再能从 query 找到。
        reset_case();
        queue_mode = 1'b1;
        allocate_producer(producer);
        prepare_consumer();
        install();
        alloc_valid = 1'b0;
        check(1'b0, '0, '0);
        complete_valid = 1'b1;
        completion.id = producer;
        completion.result.gpr_data = xlen_t'(151);
        check(1'b1, xlen_t'(151), '0);
        tick();
        complete_valid = 1'b0;
        retire_ready = 1'b1;
        tick();
        retire_ready = 1'b0;
        check(1'b1, xlen_t'(151), '0);
        assert (!query_result.rs1_forward.valid && !out_packet.rs1_dependency.pending)
            else $fatal(1, "captured source retained a dead producer dependency");
        retired_sources++;

        // 真实 RF 写穿透：老完成/退休与 D2 分配同沿，绑定排除老写者但新包必须得到新值。
        reset_case();
        queue_mode = 1'b1;
        allocate_producer(producer);
        complete_valid = 1'b1;
        completion.id = producer;
        completion.result.gpr_data = xlen_t'(237);
        retire_ready = 1'b1;
        prepare_consumer();
        #1;
        assert (retire_fire && !query_result.rs1_dependency.pending && rf1 == xlen_t'(237))
            else $fatal(1, "same-edge D2 binding lost retirement write-through");
        in_packet.rs1_data = rf1;
        install();
        alloc_valid = 1'b0;
        complete_valid = 1'b0;
        retire_ready = 1'b0;
        check(1'b1, xlen_t'(237), '0);
        retired_sources++;

        // 联合边界：rs1 只在退休沿由 queue 查得，rs2 仍等；旧物理槽复用不能覆盖已捕获值。
        // 四槽以上可同时容纳两个 producer 和消费者；这里直接驱动 queue，压力不代表 C2 已乱序发射。
        reset_case();
        queue_mode = 1'b1;
        allocate_entry(5'd5, RET_EXEC, first_id);
        if (RETIRE_ENTRIES >= 4) begin
            complete_valid = 1'b1;
            completion.id = first_id;
            completion.result.gpr_data = xlen_t'(317);
            tick();
            complete_valid = 1'b0;
            allocate_entry(5'd6, RET_MDU, second_id);
            alloc_meta = '0;
            alloc_meta.rd = 5'd7;
            alloc_meta.gpr_write = 1'b1;
            alloc_valid = 1'b1;
            make_packet(alloc_id, '{pending:1'b1, id:first_id}, '{pending:1'b1, id:second_id}, '1, '1);
            #1;
            in_packet.retire_id = alloc_id;
            install();
            alloc_valid = 1'b0;
            retire_ready = 1'b1;
            #1;
            assert (retire_fire && head_id == first_id && queue_rs1.valid &&
                    !wb_forward.valid && !mdu_forward.valid && !mem_forward.valid &&
                    out_packet.rs1_dependency.pending && out_packet.rs2_dependency.pending)
                else $fatal(1, "missing queue-only retirement-edge capture window");
            check(1'b0, xlen_t'(317), '0);
            tick();
            retire_ready = 1'b0;
            assert (!out_packet.rs1_dependency.pending && out_packet.rs2_dependency.pending)
                else $fatal(1, "retiring source did not capture independently");
            // 尾指针绕回已退休源槽；新值在该槽完成，消费者仍等待另一老来源。
            for (int filler = 0; filler < RETIRE_ENTRIES - 2; filler++) begin
                allocate_entry(filler == RETIRE_ENTRIES - 3 ? 5'd5 : gpr_addr_t'(8 + filler), RET_EXEC, reused);
                check(1'b0, xlen_t'(317), '0);
            end
            assert (reused.slot == first_id.slot && reused.generation != first_id.generation)
                else $fatal(1, "retired producer slot was not reused");
            complete_valid = 1'b1;
            completion.id = reused;
            completion.result.gpr_data = xlen_t'(999);
            check(1'b0, xlen_t'(317), '0);
            tick();
            complete_valid = 1'b0;
            check(1'b0, xlen_t'(317), '0);
            retire_lookup_partial++;
        end else begin
            // 两槽不能同时保留两个 producer 加消费者：先证明容量反压，再从 RF 接续已退休 rs1。
            allocate_entry(5'd6, RET_MDU, second_id);
            alloc_valid = 1'b1;
            alloc_meta.rd = 5'd7;
            #1;
            assert (!alloc_ready && occupancy == RETIRE_COUNT_W'(2))
                else $fatal(1, "two-slot queue accepted a third owner");
            tick();
            alloc_valid = 1'b0;
            complete_valid = 1'b1;
            completion.id = first_id;
            completion.result.gpr_data = xlen_t'(317);
            retire_ready = 1'b1;
            tick();
            complete_valid = 1'b0;
            retire_ready = 1'b0;
            alloc_meta = '0;
            alloc_meta.rd = 5'd7;
            alloc_meta.gpr_write = 1'b1;
            alloc_valid = 1'b1;
            make_packet(alloc_id, '0, '{pending:1'b1, id:second_id}, '1, '1);
            #1;
            in_packet.retire_id = alloc_id;
            in_packet.rs1_data = rf1;
            assert (rf1 == xlen_t'(317) && !query_result.rs1_dependency.pending)
                else $fatal(1, "two-slot capacity release lost the retired value");
            install();
            alloc_valid = 1'b0;
            check(1'b0, xlen_t'(317), '0);
            capacity_adapted++;
        end
        complete_valid = 1'b1;
        completion.id = second_id;
        completion.result.gpr_data = xlen_t'(431);
        retire_ready = 1'b1;
        check(1'b1, xlen_t'(317), xlen_t'(431));
        tick();
        complete_valid = 1'b0;
        retire_ready = 1'b0;
        check(1'b1, xlen_t'(317), xlen_t'(431));

        // 真实异常条目只保留依赖，不传播无效结果；取消与已有输出相遇时清理 EX 所有者。
        reset_case();
        queue_mode = 1'b1;
        allocate_producer(producer);
        prepare_consumer();
        install();
        alloc_valid = 1'b0;
        complete_valid = 1'b1;
        completion.id = producer;
        completion.result.gpr_data = xlen_t'(999);
        completion.result.exc.valid = 1'b1;
        completion.result.exc.cause = EXC_LOAD_ACCESS_FAULT;
        tick();
        complete_valid = 1'b0;
        check(1'b0, '0, '0);
        qflush = 1'b1;
        retire_ready = 1'b1;
        action = PIPE_CLEAR;
        tick();
        #1;
        assert (!out_packet.valid && occupancy == '0) else $fatal(1, "fault flush left an operand owner");
        assert (ii1_cycles == 24 && partial_captures == 2 && retired_sources == 2 &&
                retire_lookup_partial + capacity_adapted == 1)
            else $fatal(1, "operand coverage missing");
        $display("PASS tb_ex_operand_register RV%0d depth=%0d checks=%0d ii1=%0d partial=%0d retire_edges=%0d retire_lookup_partial=%0d capacity_adapted=%0d",
                 XLEN, RETIRE_ENTRIES, checks, ii1_cycles, partial_captures, retired_sources,
                 retire_lookup_partial, capacity_adapted);
        $finish;
    end
    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "operand capture timeout");
    end
endmodule
