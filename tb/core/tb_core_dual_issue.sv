// Module: tb_core_dual_issue
// Description: Independent architectural and full-ID age checks for single/dual issue integration.
module tb_core_dual_issue;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    logic imem_rsp_error, imem_rsp_error_1;
    xlen_t imem_req_addr;
    logic [FETCH_DATA_W-1:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    logic commit_valid, commit_rd_we, commit_exception, fence_i_commit;
    logic irq_timer;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    retire_trace_t commit_trace [2];
    logic [31:0] rom [256];
    xlen_t registers [32];
    typedef struct packed {
        retire_id_t id;
        xlen_t pc;
        logic [31:0] inst;
        logic completed;
    } age_t;
    age_t ages[$];
    age_t discarded;
    xlen_t reference_pc;
    int scenario, stop_pc, fault_pc, retired, cycles, requests, stores, reads;
    int issue_streak, retire_streak, max_issue_streak, max_retire_streak;
    int pair_issues, pair_retires, raw_seen, waw_seen, war_seen, war_fence_retired;
    int independent_load_done, independent_mdu_done, csr_checks, total_checks;
    int last_retire_width, irq_entries, irq_boundary_width, alu_cases, load_forward_seen, fault_young_done;
    logic [31:0] lane1_alu_seen;
    xlen_t reference_mepc;
    int delay_q;
    logic pending_q, pending_error_q, load_returned, mdu_returned, done;
    xlen_t stored_word;

    always #5 clk = ~clk;
    core dut (.irq_software(1'b0), .irq_external(1'b0), .*);
    assign imem_req_ready = !rst && (!imem_rsp_valid || imem_rsp_ready);
    assign dmem_req_ready = !rst && !pending_q && !dmem_rsp_valid;

    // 真正的单拍宽取指端口；每个32位字独立标错，不借助DUT预测或队列生成答案。
    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 1'b0;
            imem_rsp_data <= '0;
            imem_rsp_error <= 1'b0;
            imem_rsp_error_1 <= 1'b0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 1'b0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1'b1;
                for (int lane = 0; lane < ISSUE_WIDTH; lane++) begin
                    imem_rsp_data[lane*32 +: 32] <= rom[(int'(imem_req_addr)/4+lane)%256];
                end
                imem_rsp_error <= scenario >= 5 && scenario <= 6 && int'(imem_req_addr) == fault_pc;
                imem_rsp_error_1 <= ISSUE_WIDTH == 2 && scenario >= 5 && scenario <= 6 &&
                                    int'(imem_req_addr)+4 == fault_pc;
            end
        end
    end

    // 总线响应是独立所有者：一次接受只产生一次迟到响应，直到握手才释放。
    // Store副作用在请求处计数，避免用退休记录掩盖错误路径外发。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            pending_error_q <= 1'b0;
            delay_q <= 0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_error <= 1'b0;
            dmem_rsp_rdata <= '0;
            requests <= 0;
            stores <= 0;
            reads <= 0;
            stored_word <= '0;
            irq_timer <= 1'b0;
        end else begin
            if (dut.interrupt_take) irq_timer <= 1'b0;
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 1'b0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_error <= pending_error_q;
                    dmem_rsp_rdata <= xlen_t'(41);
                end else delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (ages.size() > 0 && ages[0].id == dut.lsu_owner_id)
                    else $fatal(1, "LSU escaped independent model head scenario=%0d", scenario);
                assert (dmem_req_size == MEM_WORD) else $fatal(1, "Unexpected memory size");
                pending_q <= 1'b1;
                pending_error_q <= scenario == 8;
                delay_q <= 15;
                requests <= requests + 1;
                if (scenario == 10) irq_timer <= 1'b1;
                if (dmem_req_write) begin
                    stores <= stores + 1;
                    assert (scenario == 7 && dmem_req_addr == 520 &&
                            dmem_req_wstrb == DBUS_BYTES'(15) && dmem_req_wdata[31:0] == 42)
                        else $fatal(1, "Wrong/younger store side effect");
                    stored_word <= xlen_t'(dmem_req_wdata[31:0]);
                end else begin
                    reads <= reads + 1;
                    assert (dmem_req_addr == 512 && (scenario == 7 || scenario == 8 || scenario == 10))
                        else $fatal(1, "Wrong/younger MMIO read side effect");
                end
            end
        end
    end

    task automatic record_alloc(input retire_id_t id, input retire_alloc_t meta);
        age_t item;
        foreach (ages[i]) assert (ages[i].id != id) else $fatal(1, "Live full ID reused");
        item = '{id:id, pc:meta.pc, inst:meta.inst, completed:1'b0};
        ages.push_back(item);
    endtask

    task automatic record_complete(input retire_completion_t completion_item);
        int found;
        found = -1;
        foreach (ages[i]) if (ages[i].id == completion_item.id) found = i;
        assert (found >= 0) else $fatal(1, "Completion without independent allocation");
        assert (!ages[found].completed) else $fatal(1, "Duplicate completion pc=%h", ages[found].pc);
        ages[found].completed = 1'b1;
        if (scenario == 7 && ages[found].pc == 20 && !load_returned) independent_load_done++;
        if (scenario == 7 && ages[found].pc == 12 && !mdu_returned) independent_mdu_done++;
        if (scenario == 8 && ages[found].pc == 4 && !load_returned) fault_young_done++;
    endtask

    // 指令解释器只读取程序镜像和自己的架构寄存器；同拍两条按年龄逐条执行。
    // MINSTRET读取值来自已成功退休条数，不能把自身或同拍年轻lane算入。
    task automatic check_retire(input retire_trace_t trace_item);
        logic [31:0] instruction;
        int rd, rs1, rs2;
        xlen_t value, next_pc, immediate;
        logic [31:0] word_value;
        int shift_amount;
        logic writes, expected_exception;
        assert (ages.size() > 0 && ages[0].id == trace_item.id && ages[0].completed)
            else $fatal(1, "Retire is not completed model head scenario=%0d pc=%h", scenario, trace_item.pc);
        assert (trace_item.pc == reference_pc && ages[0].pc == trace_item.pc &&
                ages[0].inst == trace_item.inst && trace_item.inst == rom[int'(reference_pc)/4])
            else $fatal(1, "Age/instruction mismatch scenario=%0d pc=%h expected=%h", scenario, trace_item.pc, reference_pc);
        discarded = ages.pop_front();
        instruction = rom[int'(reference_pc)/4];
        rd = int'(instruction[11:7]);
        rs1 = int'(instruction[19:15]);
        rs2 = int'(instruction[24:20]);
        value = '0;
        next_pc = reference_pc + xlen_t'(4);
        immediate = xlen_t'($signed(instruction[31:20]));
        writes = 1'b0;
        expected_exception = ((scenario >= 3 && scenario <= 6) && int'(reference_pc) == fault_pc) ||
                             (scenario == 8 && reference_pc == 0);
        assert (trace_item.exception == expected_exception)
            else $fatal(1, "Exception mismatch scenario=%0d pc=%h", scenario, reference_pc);
        if (expected_exception) begin
            assert (!trace_item.rd_we && stores == 0 && requests == (scenario == 8 ? 1 : 0))
                else $fatal(1, "Fault allowed younger side effect");
            assert (dut.trap_cause == (scenario == 8 ? xlen_t'(EXC_LOAD_ACCESS_FAULT) :
                    scenario >= 5 ? xlen_t'(EXC_INST_ACCESS_FAULT) : xlen_t'(EXC_ILLEGAL_INST)))
                else $fatal(1, "Incorrect exception cause");
            assert (dut.trap_tval == (scenario == 8 ? xlen_t'(512) :
                    scenario >= 5 ? reference_pc : xlen_t'(instruction)))
                else $fatal(1, "Incorrect exception tval");
            done = 1'b1;
        end else begin
            case (instruction[6:0])
                7'h13: begin
                    writes = 1'b1;
                    shift_amount = int'(instruction[20 +: $clog2(XLEN)]);
                    case (instruction[14:12])
                        0: value = registers[rs1] + immediate;
                        1: value = registers[rs1] << shift_amount;
                        2: value = xlen_t'($signed(registers[rs1]) < $signed(immediate));
                        3: value = xlen_t'(registers[rs1] < immediate);
                        4: value = registers[rs1] ^ immediate;
                        5: value = instruction[30] ? xlen_t'($signed(registers[rs1]) >>> shift_amount) : registers[rs1] >> shift_amount;
                        6: value = registers[rs1] | immediate;
                        7: value = registers[rs1] & immediate;
                        default: $fatal(1, "Bad immediate ALU");
                    endcase
                end
                7'h33: begin
                    writes = 1'b1;
                    shift_amount = int'(registers[rs2][$clog2(XLEN)-1:0]);
                    if (instruction[31:25] == 1) begin
                        assert (instruction[14:12] == 5) else $fatal(1, "Reference only implements DIVU M operation");
                        value = registers[rs2] == 0 ? '1 : registers[rs1] / registers[rs2];
                    end else begin
                        case (instruction[14:12])
                            0: value = instruction[30] ? registers[rs1] - registers[rs2] : registers[rs1] + registers[rs2];
                            1: value = registers[rs1] << shift_amount;
                            2: value = xlen_t'($signed(registers[rs1]) < $signed(registers[rs2]));
                            3: value = xlen_t'(registers[rs1] < registers[rs2]);
                            4: value = registers[rs1] ^ registers[rs2];
                            5: value = instruction[30] ? xlen_t'($signed(registers[rs1]) >>> shift_amount) : registers[rs1] >> shift_amount;
                            6: value = registers[rs1] | registers[rs2];
                            7: value = registers[rs1] & registers[rs2];
                            default: $fatal(1, "Bad register ALU");
                        endcase
                    end
                end
                7'h37: begin writes = 1'b1; value = xlen_t'($signed({instruction[31:12],12'b0})); end
                7'h17: begin writes = 1'b1; value = reference_pc + xlen_t'($signed({instruction[31:12],12'b0})); end
                7'h1b, 7'h3b: begin
                    assert (XLEN == 64) else $fatal(1, "Word operation in RV32 program");
                    writes = 1'b1;
                    shift_amount = instruction[6:0] == 7'h1b ? int'(instruction[24:20]) : int'(registers[rs2][4:0]);
                    case (instruction[14:12])
                        0: word_value = instruction[6:0] == 7'h1b ? registers[rs1][31:0] + 32'(immediate) :
                            instruction[30] ? registers[rs1][31:0] - registers[rs2][31:0] : registers[rs1][31:0] + registers[rs2][31:0];
                        1: word_value = registers[rs1][31:0] << shift_amount;
                        5: word_value = instruction[30] ? 32'($signed(registers[rs1][31:0]) >>> shift_amount) : registers[rs1][31:0] >> shift_amount;
                        default: $fatal(1, "Bad word ALU");
                    endcase
                    value = xlen_t'($signed(word_value));
                end
                7'h03: begin writes = 1'b1; value = xlen_t'(41); end
                7'h23: assert (stored_word == 42) else $fatal(1, "Store did not complete side effect");
                7'h63: begin
                    immediate = xlen_t'($signed({instruction[31], instruction[7],
                        instruction[30:25], instruction[11:8], 1'b0}));
                    if (registers[rs1] == registers[rs2]) next_pc = reference_pc + immediate;
                end
                7'h6f: begin
                    writes = 1'b1;
                    value = next_pc;
                    immediate = xlen_t'($signed({instruction[31], instruction[19:12],
                        instruction[20], instruction[30:21], 1'b0}));
                    next_pc = reference_pc + immediate;
                end
                7'h0f: begin
                    // 真实FENCE.I退休后从对齐的WAR组重取；它只建立容量覆盖前提。
                    assert (scenario == 1 && reference_pc == 20 && instruction == 32'h0000_100f &&
                            fence_i_commit && dut.wb_redirect.valid &&
                            dut.wb_redirect.reason == REDIR_FENCE && dut.wb_redirect.pc == 24 &&
                            ages.size() == 0)
                        else $fatal(1, "WAR setup did not retire FENCE.I with an empty reference queue");
                    war_fence_retired++;
                end
                7'h73: begin
                    writes = 1'b1;
                    if (instruction[31:20] == 12'(CSR_MINSTRET)) begin
                        assert (instruction[19:15] == 0) else $fatal(1, "Counter is read-only in test");
                        value = xlen_t'(retired);
                        csr_checks++;
                    end else if (instruction[31:20] == 12'(CSR_MEPC)) value = reference_mepc;
                    else begin
                        assert (scenario == 10 && rd == 0 && instruction[31:20] inside
                                {12'(CSR_MTVEC), 12'(CSR_MIE), 12'(CSR_MSTATUS)})
                            else $fatal(1, "Unsupported reference CSR");
                    end
                end
                default: $fatal(1, "Reference unsupported instruction=%h", instruction);
            endcase
            assert (trace_item.rd_we == (writes && rd != 0)) else $fatal(1, "rd_we/x0 mismatch");
            if (writes && rd != 0) begin
                assert (trace_item.rd == gpr_addr_t'(rd) && trace_item.rd_data == value)
                    else $fatal(1, "Value scenario=%0d pc=%h rd=%0d got=%h expected=%h",
                                scenario, reference_pc, rd, trace_item.rd_data, value);
                registers[rd] = value;
            end
            assert (trace_item.next_pc == next_pc) else $fatal(1, "Wrong retired next_pc");
            retired++;
            if (int'(reference_pc) == stop_pc) done = 1'b1;
            reference_pc = next_pc;
        end
        total_checks++;
    endtask

    // 队列参考只由公开握手构建，不读取DUT槽、指针或occupancy作为答案。
    // 先记录本沿完成再验证退休，保留completion到head的合法旁路覆盖。
    always @(posedge clk) begin
        if (rst) begin
            ages.delete();
            reference_pc = '0;
            foreach (registers[i]) registers[i] = '0;
            retired = 0;
            cycles = 0;
            done = 1'b0;
            issue_streak = 0;
            retire_streak = 0;
            max_issue_streak = 0;
            max_retire_streak = 0;
            pair_issues = 0;
            pair_retires = 0;
            raw_seen = 0;
            waw_seen = 0;
            war_seen = 0;
            war_fence_retired = 0;
            independent_load_done = 0;
            independent_mdu_done = 0;
            load_returned = 1'b0;
            mdu_returned = 1'b0;
            last_retire_width = 0;
            irq_entries = 0;
            irq_boundary_width = 0;
            load_forward_seen = 0;
            fault_young_done = 0;
            reference_mepc = '0;
            lane1_alu_seen = '0;
        end else if (!done) begin
            cycles++;
            // 可选被动诊断使用握手参考队列，观察容量拆组，不改变激励或作为覆盖答案。
            if (scenario == 1 && $test$plusargs("C5_WAR_TRACE"))
                $display("WAR_TRACE cycle=%0d live=%0d head_pc=%0d d2=%0d/%0d valid=%b%b pair_ok=%b ready=%b%b fire=%b%b retire=%b%b ex=%0d/%0d ex_valid=%b%b advance=%b",
                    cycles, ages.size(), ages.size() == 0 ? -1 : int'(ages[0].pc),
                    dut.d1_d2_q.pc, dut.d1_d2_q_1.pc, dut.d1_d2_q.valid, dut.d1_d2_q_1.valid,
                    dut.issue_pair_eligible, dut.dispatch_ready, dut.dispatch_ready_1,
                    dut.dispatch_fire, dut.dispatch_fire_1, commit_trace[0].valid, commit_trace[1].valid,
                    dut.d2_ex_q.pc, dut.d2_ex_q_1.pc, dut.d2_ex_q.valid, dut.d2_ex_q_1.valid, dut.ex_stage_advance);
            assert (!dut.dispatch_fire_1 || dut.dispatch_fire) else $fatal(1, "Non-prefix dispatch");
            if (scenario == 1 && dut.dispatch_fire && dut.alloc_meta.pc == 24)
                assert (war_fence_retired == 1 && ages.size() == 0)
                    else $fatal(1, "WAR pair was not offered to an empty reference queue after FENCE.I");
            if (dut.dispatch_fire) record_alloc(dut.alloc_id, dut.alloc_meta);
            if (dut.dispatch_fire_1) record_alloc(dut.alloc_id_1, dut.alloc_meta_1);
            if (dut.complete_valid && dut.complete_ready && !dut.complete_reject) record_complete(dut.completion);
            if (dut.secondary_valid && dut.secondary_ready && !dut.secondary_reject) record_complete(dut.secondary_completion);
            if (dmem_rsp_valid && dmem_rsp_ready) load_returned = 1'b1;
            if (dut.mdu_complete_valid && dut.mdu_complete_ready) mdu_returned = 1'b1;
            if (scenario == 7 && dut.d2_ex_q.valid && dut.d2_ex_q.pc == 24 &&
                dut.d2_ex_q.rs1_dependency.pending && dut.tagged_lsu_forward.valid &&
                dut.d2_ex_q.rs1_dependency.id == dut.tagged_lsu_forward.id) begin
                assert (dut.ex_rs1_value == 41) else $fatal(1, "Registered full-ID load forwarding lost");
                load_forward_seen++;
            end
            if (dut.ex_stage_advance && dut.d2_ex_q.valid && dut.d2_ex_q_1.valid) begin
                issue_streak++;
                pair_issues++;
                if (scenario == 1 && dut.d2_ex_q.pc == 24 && dut.d2_ex_q_1.pc == 28) war_seen++;
                if (scenario == 9 && int'(dut.d2_ex_q_1.pc) >= 20 &&
                    int'(dut.d2_ex_q_1.pc) < 20+alu_cases*8 && int'(dut.d2_ex_q_1.pc)%8 == 4)
                    lane1_alu_seen[(int'(dut.d2_ex_q_1.pc)-20)/8] = 1'b1;
            end else issue_streak = 0;
            if (commit_trace[0].valid && commit_trace[1].valid) begin
                retire_streak++;
                pair_retires++;
            end else retire_streak = 0;
            if (issue_streak > max_issue_streak) max_issue_streak = issue_streak;
            if (retire_streak > max_retire_streak) max_retire_streak = retire_streak;
            if (scenario == 1 && dut.if_d1_q.valid && dut.if_d1_q_1.valid) begin
                if (dut.if_d1_q.pc == 0 && dut.if_d1_q_1.pc == 4) begin
                    assert (!dut.decode_pair_eligible) else $fatal(1, "RAW paired");
                    raw_seen++;
                end
                if (dut.if_d1_q.pc == 8 && dut.if_d1_q_1.pc == 12) begin
                    assert (!dut.decode_pair_eligible) else $fatal(1, "WAW paired");
                    waw_seen++;
                end
            end
            assert (!commit_trace[1].valid || commit_trace[0].valid) else $fatal(1, "Non-prefix retirement");
            for (int lane = 0; lane < 2; lane++)
                if (commit_trace[lane].valid) check_retire(commit_trace[lane]);
            if (commit_trace[0].valid) last_retire_width = commit_trace[1].valid ? 2 : 1;
            if (dut.interrupt_take) begin
                assert (scenario == 10 && ages.size() == 0 && !pending_q && !dmem_rsp_valid &&
                        dut.interrupt_pc == reference_pc && dut.trap_pc == reference_pc)
                    else $fatal(1, "IRQ did not drain to independent next PC");
                if (ISSUE_WIDTH == 2)
                    assert (last_retire_width == 2) else $fatal(1, "IRQ test lacks last second-lane retirement");
                reference_mepc = reference_pc;
                irq_boundary_width = last_retire_width;
                reference_pc = xlen_t'(256);
                irq_entries++;
            end
            if (dut.wb_redirect.valid) ages.delete();
        end
    end

    task automatic put(input int address, input logic [31:0] instruction);
        rom[address/4] = instruction;
    endtask

    initial begin
        total_checks = 0;
        csr_checks = 0;
        for (scenario = 0; scenario < 11; scenario++) begin
            @(negedge clk);
            rst = 1'b1;
            foreach (rom[i]) rom[i] = nop();
            fault_pc = -1;
            stop_pc = 0;
            alu_cases = 0;
            case (scenario)
                0: begin
                    // 24个不同目的寄存器循环，避免把WAW策略误算为独立ALU吞吐。
                    for (int i = 0; i < 64; i++) put(i*4, enc_addi(5'(1+i%24), 0, i+1));
                    put(256, enc_csrrs(30, CSR_MINSTRET, 0));
                    put(260, enc_addi(31, 0, 1));
                    stop_pc = 260;
                end
                1: begin
                    // GPR内容不由reset清零；WAR所读x5在程序内显式初始化。
                    put(0, enc_addi(5, 0, 11)); put(4, enc_addi(2, 5, 1));
                    put(8, enc_addi(3, 0, 21)); put(12, enc_addi(3, 0, 22));
                    // q2中旧WAW项可能只留下一个空槽，合法前缀发射会拆散紧邻WAR组。
                    // FENCE.I真实退休并重取PC24，使两槽容量可用；仍要求WAR两条实际同拍执行。
                    put(16, nop()); put(20, 32'h0000_100f);
                    put(24, enc_addi(4, 5, 1)); put(28, enc_addi(5, 0, 23));
                    put(32, enc_addi(0, 0, 55)); put(36, enc_addi(6, 0, 7));
                    put(40, enc_addi(7, 5, 2)); put(44, enc_addi(8, 2, 2));
                    put(48, enc_csrrs(30, CSR_MINSTRET, 0)); put(52, enc_addi(31, 0, 1));
                    stop_pc = 52;
                end
                2: begin
                    put(0, enc_jal(1, 16)); put(4, enc_sw(0, 0, 520));
                    put(16, enc_addi(2, 0, 2)); put(20, enc_jal(3, 12));
                    put(24, enc_lw(10, 0, 516));
                    put(32, enc_beq(0, 0, 16)); put(36, enc_sw(0, 0, 520));
                    put(48, enc_addi(4, 0, 4)); put(52, enc_beq(0, 0, 12));
                    put(56, enc_lw(10, 0, 516));
                    put(64, enc_addi(5, 0, 5)); put(68, enc_csrrs(30, CSR_MINSTRET, 0));
                    put(72, enc_addi(31, 0, 1)); stop_pc = 72;
                end
                3, 4, 5, 6: begin
                    fault_pc = (scenario == 3 || scenario == 5) ? 0 : 4;
                    put(0, enc_addi(1, 0, 1)); put(4, enc_addi(2, 0, 2));
                    if (scenario <= 4) put(fault_pc, 32'hffff_ffff);
                    put(8, enc_sw(0, 0, 520)); put(12, enc_lw(10, 0, 516));
                end
                7: begin
                    put(0, enc_addi(1, 0, -1)); put(4, enc_addi(2, 0, 3));
                    put(8, enc_divu(3, 1, 2)); put(12, enc_addi(4, 0, 44));
                    put(16, enc_lw(5, 0, 512)); put(20, enc_addi(6, 0, 66));
                    put(24, enc_addi(7, 5, 1)); put(28, enc_addi(8, 4, 1));
                    put(32, enc_sw(7, 0, 520)); put(36, enc_addi(9, 3, 1));
                    put(40, enc_csrrs(30, CSR_MINSTRET, 0)); put(44, enc_addi(31, 0, 1));
                    stop_pc = 44;
                end
                8: begin
                    put(0, enc_lw(1, 0, 512)); put(4, enc_addi(2, 0, 2));
                    put(8, enc_sw(2, 0, 520)); put(12, enc_lw(3, 0, 516));
                end
                9: begin
                    put(0, enc_addi(1, 0, -16)); put(4, enc_addi(2, 0, 3));
                    put(8, enc_addi(3, 0, 16)); put(12, enc_addi(4, 0, 0));
                    // 每个被测运算处于真实第二执行槽；第一条NOP不建立RAW/WAW。
                    put(20, enc_lui(5, 20'h80000)); put(28, enc_u(20'h1, 6, 7'h17));
                    put(36, enc_r(0, 2, 3, 1, 7, 7'h33)); put(44, enc_r(0, 2, 1, 5, 8, 7'h33));
                    put(52, enc_r(7'h20, 2, 1, 5, 9, 7'h33)); put(60, enc_r(0, 2, 1, 2, 10, 7'h33));
                    put(68, enc_r(0, 2, 1, 3, 11, 7'h33)); put(76, enc_r(0, 2, 1, 4, 12, 7'h33));
                    put(84, enc_r(0, 2, 1, 6, 13, 7'h33)); put(92, enc_r(0, 2, 1, 7, 14, 7'h33));
                    put(100, enc_r(7'h20, 2, 1, 0, 15, 7'h33)); put(108, enc_slli(16, 2, 4));
                    put(116, enc_srli(17, 1, 4)); put(124, enc_i('h404, 1, 5, 18, 7'h13));
                    put(132, enc_i(0, 1, 2, 19, 7'h13)); put(140, enc_i(3, 1, 3, 20, 7'h13));
                    put(148, enc_i(31, 1, 4, 21, 7'h13)); put(156, enc_i(31, 1, 6, 22, 7'h13));
                    put(164, enc_i(31, 1, 7, 23, 7'h13)); put(172, enc_add(24, 1, 2));
                    alu_cases = 20;
                    if (XLEN == 64) begin
                        put(180, enc_addiw(25, 1, 1)); put(188, enc_r(0, 2, 3, 1, 26, 7'h3b));
                        put(196, enc_r(0, 2, 1, 5, 27, 7'h3b)); put(204, enc_sraw(28, 1, 2));
                        put(212, enc_addw(29, 1, 2)); put(220, enc_subw(30, 1, 2));
                        put(228, enc_slliw(5, 1, 4)); put(236, enc_i(4, 1, 5, 6, 7'h1b));
                        put(244, enc_i('h404, 1, 5, 7, 7'h1b));
                        alu_cases = 29;
                    end
                    put(16+alu_cases*8, enc_csrrs(30, CSR_MINSTRET, 0));
                    stop_pc = 20+alu_cases*8;
                    put(stop_pc, enc_addi(31, 0, 1));
                end
                10: begin
                    put(0, enc_addi(1, 0, 256)); put(4, enc_csrrw(0, CSR_MTVEC, 1));
                    put(8, enc_addi(2, 0, 128)); put(12, enc_csrrw(0, CSR_MIE, 2));
                    put(16, enc_addi(3, 0, 8)); put(20, enc_csrrs(0, CSR_MSTATUS, 3));
                    put(24, enc_lw(4, 0, 512)); put(28, enc_addi(5, 0, 5));
                    for (int i = 0; i < 40; i++) put(32+i*4, enc_addi(5'(6+i%24), 0, i+6));
                    put(256, enc_csrrs(30, CSR_MEPC, 0)); put(260, enc_addi(31, 0, 1));
                    stop_pc = 260;
                end
                default: $fatal(1, "Bad scenario");
            endcase
            repeat (3) @(negedge clk);
            rst = 1'b0;
            for (int timeout = 0; timeout < 4000 && !done; timeout++) @(negedge clk);
            assert (done) else $fatal(1, "Timeout scenario=%0d pc=%h retired=%0d", scenario, reference_pc, retired);
            if (scenario == 0 && ISSUE_WIDTH == 2) begin
                assert (pair_issues > 0 && pair_retires > 0) else $fatal(1, "No real dual events");
                if (RETIRE_ENTRIES >= 8)
                    assert (max_issue_streak >= 8 && max_retire_streak >= 8)
                        else $fatal(1, "No sustained dual throughput issue=%0d retire=%0d", max_issue_streak, max_retire_streak);
            end
            if (scenario == 1) begin
                assert (war_fence_retired == 1) else $fatal(1, "WAR setup FENCE.I coverage");
                if (ISSUE_WIDTH == 2)
                    assert (raw_seen > 0 && waw_seen > 0 && war_seen > 0)
                        else $fatal(1, "Hazard coverage RAW=%0d WAW=%0d WAR=%0d", raw_seen, waw_seen, war_seen);
            end
            if (scenario == 7) begin
                assert (requests == 2 && reads == 1 && stores == 1 && independent_load_done > 0 && independent_mdu_done > 0)
                    else $fatal(1, "Slow owner coverage load=%0d mdu=%0d req=%0d", independent_load_done, independent_mdu_done, requests);
                if (RETIRE_ENTRIES >= 4)
                    assert (load_forward_seen > 0) else $fatal(1, "No registered load full-ID forwarding");
            end
            if (scenario == 8)
                assert (fault_young_done > 0) else $fatal(1, "No young done result before old fault");
            if (scenario == 9 && ISSUE_WIDTH == 2)
                for (int i = 0; i < alu_cases; i++)
                    assert (lane1_alu_seen[i]) else $fatal(1, "ALU operation %0d never issued on lane1", i);
            if (scenario == 10)
                assert (irq_entries == 1 && requests == 1 && reads == 1 && stores == 0)
                    else $fatal(1, "IRQ coverage entries=%0d", irq_entries);
            $display("DUAL scenario=%0d xlen=%0d issue=%0d q=%0d cycles=%0d retired=%0d pair_issue=%0d pair_retire=%0d issue_streak=%0d retire_streak=%0d RAW/WAW/WAR=%0d/%0d/%0d early_load/mdu=%0d/%0d",
                scenario, XLEN, ISSUE_WIDTH, RETIRE_ENTRIES, cycles, retired, pair_issues, pair_retires,
                max_issue_streak, max_retire_streak, raw_seen, waw_seen, war_seen, independent_load_done, independent_mdu_done);
            if (scenario == 7 || scenario == 8 || scenario == 9 || scenario == 10)
                $display("DUAL coverage scenario=%0d load_forward=%0d fault_young_done=%0d lane1_alu=%0d/%0d irq=%0d last_retire_width=%0d mepc=%h",
                    scenario, load_forward_seen, fault_young_done, $countones(lane1_alu_seen), alu_cases,
                    irq_entries, irq_boundary_width, reference_mepc);
        end
        assert (csr_checks == 5) else $fatal(1, "MINSTRET coverage");
        $display("PASS tb_core_dual_issue XLEN=%0d ISSUE_WIDTH=%0d QUEUE=%0d scenarios=11 retire_checks=%0d minstret=%0d",
            XLEN, ISSUE_WIDTH, RETIRE_ENTRIES, total_checks, csr_checks);
        $finish;
    end
endmodule
