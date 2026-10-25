// Module: tb_scoreboard_core
// Description: Compares both retirement lanes with an instruction-level model and measures sustained issue.
module tb_scoreboard_core;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    xlen_t imem_req_addr;
    logic [63:0] imem_rsp_data;
    logic [1:0] mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready, issue_fire;
    memory_request_t mem_request [2];
    memory_response_t mem_response [2];
    logic commit_valid, commit_rd_we, commit_exception, fence_i_commit;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    retire_trace_t commit_trace [2];
    logic [31:0] rom [4096];
    logic [7:0] ram [4096], reference_ram [4096];
    xlen_t registers [32], reference_pc;
    int length, stop_pc, cycles, retired, issue_streak, retire_streak, max_issue_streak, max_retire_streak;
    int live_waw, background_alu, branches, requests, dual_requests, pair_counts [5][5];
    int decode_jals [2], frontend_jumps;
    int store_stall_cycles;
    int store_hint_count [2], zero_hint_count, reused_hint_count;
    int rob_slot_allocations [RETIRE_ENTRIES];
    int integer_bypasses = 0;
    bit fence_executed = 0;
    logic [31:0] random_state = 32'h6532af01;
    bit done;
    always #5 clk = ~clk;
    if (LIMITED_INTEGER_OOO && SPLIT_ISSUE_QUEUE) begin : g_ooo_coverage
        always @(posedge clk) if (!rst && !done) begin
            for (int lane = 0; lane < 2; lane++) begin
                for (int slot = 0; slot < ISSUE_QUEUE_ENTRIES; slot++) begin
                    if (int'(dut.issue_enqueue_count) > lane && schedule_class(dut.queued[lane]) == SCHED_ALU &&
                        dut.g_split_iq.u_scoreboard.g_ready_integer.u_integer.valid_q[slot] &&
                        (dut.g_split_iq.u_scoreboard.g_ready_integer.u_integer.operand_view[slot].rs1_dependency.pending ||
                         dut.g_split_iq.u_scoreboard.g_ready_integer.u_integer.operand_view[slot].rs2_dependency.pending) &&
                        younger_than(dut.queued[lane].retire_id,
                            dut.g_split_iq.u_scoreboard.g_ready_integer.u_integer.packet_q[slot].retire_id, dut.head_slot))
                        integer_bypasses++;
                end
            end
        end
    end
    scoreboard_core dut (.irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0),
        .imem_rsp_error(1'b0), .imem_rsp_error_1(1'b0), .*);
    assign imem_req_ready = !rst && (!imem_rsp_valid || imem_rsp_ready);
    for (genvar lane = 0; lane < 2; lane++) begin : g_memory_ready
        assign mem_req_ready[lane] = !rst && (!mem_rsp_valid[lane] || mem_rsp_ready[lane]) &&
                                     (cycles % 7 != 3) &&
                                     !(mem_request[lane].write && mem_request[lane].address == 600 &&
                                       store_stall_cycles < 24);
    end
    // 对一条 Store 施加固定反压，让 x0 Load 和普通 Load 真正从 SQ 捕获数据。
    always_ff @(posedge clk) begin
        if (rst) store_stall_cycles <= 0;
        else if (mem_req_valid[0] && !mem_req_ready[0] && mem_request[0].write &&
                 mem_request[0].address == 600) store_stall_cycles <= store_stall_cycles + 1;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 0; mem_rsp_valid <= 0;
        end else begin
            if (imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                assert (imem_req_addr < 16376) else $fatal(1, "IF outside test ROM");
                imem_rsp_valid <= 1;
                imem_rsp_data <= {rom[int'(imem_req_addr)/4 + 1], rom[int'(imem_req_addr)/4]};
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (mem_rsp_ready[lane]) mem_rsp_valid[lane] <= 0;
                if (mem_req_valid[lane] && mem_req_ready[lane]) begin
                    assert (mem_request[lane].address < 4096) else $fatal(1, "data address outside test RAM");
                    mem_rsp_valid[lane] <= 1;
                    mem_response[lane].id <= mem_request[lane].id;
                    mem_response[lane].error <= 0;
                    for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++) begin
                        mem_response[lane].data[8*byte_no +: 8] <=
                            ram[(int'(mem_request[lane].address) & ~(DBUS_BYTES-1)) + byte_no];
                        if (mem_request[lane].write && mem_request[lane].wstrb[byte_no])
                            ram[(int'(mem_request[lane].address) & ~(DBUS_BYTES-1)) + byte_no] <=
                                mem_request[lane].wdata[8*byte_no +: 8];
                    end
                end
            end
        end
    end
    task automatic emit(input logic [31:0] inst);
        rom[length] = inst; length++;
    endtask
    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13; random_state ^= random_state >> 17; random_state ^= random_state << 5;
        return random_state;
    endfunction
    task automatic check_retire(input retire_trace_t item);
        logic [31:0] inst, word_value;
        int rd, rs1, rs2, shift, addr;
        xlen_t value, immediate, next_pc;
        bit writes, take;
        inst = rom[int'(reference_pc)/4];
        assert (item.pc == reference_pc && item.inst == inst && !item.exception)
            else $fatal(1, "trace PC/exception got pc=%h inst=%h exc=%0d expected pc=%h inst=%h cause=%h",
                        item.pc, item.inst, item.exception, reference_pc, inst, dut.trap_cause);
        rd = int'(inst[11:7]); rs1 = int'(inst[19:15]); rs2 = int'(inst[24:20]);
        immediate = xlen_t'($signed(inst[31:20]));
        next_pc = reference_pc + 4; value = 0; writes = 0; take = 0; addr = 0; word_value = 0;
        unique case (inst[6:0])
            7'h13: begin
                writes = 1;
                shift = int'(inst[20 +: $clog2(XLEN)]);
                unique case (inst[14:12])
                    0: value = registers[rs1] + immediate;
                    1: value = registers[rs1] << shift;
                    2: value = xlen_t'($signed(registers[rs1]) < $signed(immediate));
                    3: value = xlen_t'(registers[rs1] < immediate);
                    4: value = registers[rs1] ^ immediate;
                    5: value = inst[30] ? xlen_t'($signed(registers[rs1]) >>> shift) : registers[rs1] >> shift;
                    6: value = registers[rs1] | immediate;
                    default: value = registers[rs1] & immediate;
                endcase
            end
            7'h33: begin
                writes = 1; shift = int'(registers[rs2][$clog2(XLEN)-1:0]);
                if (inst[31:25] == 1) begin
                    if (inst[14:12] == 0) value = registers[rs1] * registers[rs2];
                    else if (inst[14:12] == 5) value = registers[rs2] == 0 ? '1 : registers[rs1] / registers[rs2];
                    else $fatal(1, "unsupported test M opcode");
                end else begin
                    unique case (inst[14:12])
                        0: value = inst[30] ? registers[rs1] - registers[rs2] : registers[rs1] + registers[rs2];
                        1: value = registers[rs1] << shift;
                        2: value = xlen_t'($signed(registers[rs1]) < $signed(registers[rs2]));
                        3: value = xlen_t'(registers[rs1] < registers[rs2]);
                        4: value = registers[rs1] ^ registers[rs2];
                        5: value = inst[30] ? xlen_t'($signed(registers[rs1]) >>> shift) : registers[rs1] >> shift;
                        6: value = registers[rs1] | registers[rs2];
                        default: value = registers[rs1] & registers[rs2];
                    endcase
                end
            end
            7'h1b: begin writes = 1; word_value = registers[rs1][31:0] + 32'(immediate); value = xlen_t'($signed(word_value)); end
            7'h03: begin
                writes = 1; addr = int'(registers[rs1] + immediate);
                for (int byte_no = 0; byte_no < 4; byte_no++) word_value[8*byte_no +: 8] = reference_ram[addr+byte_no];
                value = xlen_t'($signed(word_value));
            end
            7'h23: begin
                immediate = xlen_t'($signed({inst[31:25], inst[11:7]}));
                addr = int'(registers[rs1] + immediate);
                for (int byte_no = 0; byte_no < 4; byte_no++) begin
                    reference_ram[addr+byte_no] = registers[rs2][8*byte_no +: 8];
                    assert (ram[addr+byte_no] == reference_ram[addr+byte_no])
                        else $fatal(1, "Store retired before side effect");
                end
            end
            7'h63: begin
                immediate = xlen_t'($signed({inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}));
                take = inst[14:12] == 0 ? registers[rs1] == registers[rs2] : registers[rs1] != registers[rs2];
                if (take) next_pc = reference_pc + immediate;
                branches++;
            end
            7'h6f: begin
                writes = 1; value = next_pc;
                immediate = xlen_t'($signed({inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}));
                next_pc = reference_pc + immediate; branches++;
            end
            7'h67: begin
                writes = 1; value = next_pc;
                next_pc = (registers[rs1] + immediate) & ~xlen_t'(1); branches++;
            end
            7'h73: begin
                writes = 1;
                assert (inst[31:20] == 12'(CSR_MINSTRET)) else $fatal(1, "test CSR unsupported");
                value = xlen_t'(retired);
            end
            7'h0f: assert (inst == 32'h0ff0000f) else $fatal(1, "unsupported fence encoding");
            default: $fatal(1, "reference unsupported instruction=%h", inst);
        endcase
        assert (item.rd_we == (writes && rd != 0)) else $fatal(1, "write-enable pc=%h", reference_pc);
        if (writes && rd != 0) begin
            assert (item.rd == gpr_addr_t'(rd) && item.rd_data == value)
                else $fatal(1, "value pc=%h x%0d got=%h expected=%h", reference_pc, rd, item.rd_data, value);
            registers[rd] = value;
        end
        assert (item.next_pc == next_pc)
            else $fatal(1, "next_pc pc=%h inst=%h got=%h expected=%h", reference_pc, inst, item.next_pc, next_pc);
        if (reference_pc == xlen_t'(stop_pc)) done = 1;
        reference_pc = next_pc;
        retired++;
    endtask
    always @(posedge clk) if (!rst && !done) begin
        cycles++;
        issue_streak = issue_fire == 3 ? issue_streak + 1 : 0;
        retire_streak = commit_trace[1].valid ? retire_streak + 1 : 0;
        if (issue_streak > max_issue_streak) max_issue_streak = issue_streak;
        if (retire_streak > max_retire_streak) max_retire_streak = retire_streak;
        if (issue_fire == 3) pair_counts[int'(dut.lane_class[0])][int'(dut.lane_class[1])]++;
        if ((mem_req_valid & mem_req_ready) == 3) dual_requests++;
        if (|issue_fire && !dut.mdu_req_ready && dut.lane_class[0] == SCHED_ALU) background_alu++;
        for (int lane = 0; lane < 2; lane++) begin
            if (dut.alloc_fire[lane]) rob_slot_allocations[dut.alloc_id[lane].slot]++;
            if (dut.lsu_store_forward_hint[lane].valid && !dut.selected_redirect.valid) begin
                store_hint_count[lane]++;
                if (dut.producers[dut.lsu_store_forward_hint[lane].id.slot].rd == 0) zero_hint_count++;
                // 独立统计槽分配次数，必须超过完整代次周期；非零 generation 本身不代表回卷。
                if (rob_slot_allocations[dut.lsu_store_forward_hint[lane].id.slot] > (1 << RETIRE_GEN_W))
                    reused_hint_count++;
            end
            if (issue_fire[lane] && dut.scheduled[lane].uop.sys_op == SYS_FENCE) begin
                assert (!dut.lsu_busy) else $fatal(1, "FENCE executed before LSU drain");
                fence_executed = 1;
            end
            if ($test$plusargs("DEBUG") && issue_fire[lane] && dut.scheduled[lane].uop.branch_op != BR_NONE)
                $display("BR issue cycle=%0d lane=%0d pc=%h op=%0d taken=%0d target=%h computed_next=%h",
                    cycles, lane, dut.scheduled[lane].pc, dut.scheduled[lane].uop.branch_op,
                    dut.branch_taken[lane], dut.branch_target[lane], dut.computed[lane].result.next_pc);
            for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
                if (dut.alloc_fire[lane] && dut.alloc_meta[lane].gpr_write && dut.alloc_meta[lane].rd != 0 &&
                    dut.producers[slot].valid && dut.producers[slot].gpr_write &&
                    dut.producers[slot].rd == dut.alloc_meta[lane].rd) live_waw++;
            end
            if (mem_req_valid[lane] && mem_req_ready[lane]) begin
                requests++;
                if (mem_request[lane].address == 548)
                    assert (fence_executed) else $fatal(1, "younger memory crossed FENCE");
            end
            if (commit_trace[lane].valid) check_retire(commit_trace[lane]);
        end
        assert (cycles < 20000) else $fatal(1, "timeout pc=%h ROB=%0d IQ=%0d", reference_pc, dut.rob_occupancy, dut.iq_occupancy);
    end
    always @(posedge clk) if (!rst && !done) begin
        for (int lane = 0; lane < 2; lane++)
            if (int'(dut.fetch_pop_count) > lane && dut.d1_redirect[lane].valid) decode_jals[lane]++;
        if (dut.decode_jump_q.valid && !dut.selected_redirect.valid) begin
            frontend_jumps++;
            assert (dut.frontend_redirect.valid && dut.frontend_redirect.pc == dut.decode_jump_q.pc &&
                    dut.fetch_pop_count == 0 && !imem_req_valid)
                else $fatal(1, "registered JAL redirect leaked younger fetch/decode");
        end
    end
    initial begin
        length = 0; cycles = 0; retired = 0; reference_pc = 0; done = 0;
        store_hint_count[0] = 0; store_hint_count[1] = 0; zero_hint_count = 0; reused_hint_count = 0;
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) rob_slot_allocations[slot] = 0;
        decode_jals[0] = 0; decode_jals[1] = 0; frontend_jumps = 0;
        for (int regno = 0; regno < 32; regno++) registers[regno] = 0;
        for (int idx = 0; idx < 4096; idx++) begin rom[idx] = nop(); ram[idx] = 0; reference_ram[idx] = 0; end
        // 低槽 JAL 取消高槽非法指令，高槽 JAL 取消目标之前的 Store。
        emit(enc_jal(1, 8)); emit(32'hffffffff);
        emit(enc_addi(2, 1, 4)); emit(enc_jal(5, 8));
        emit(enc_sw(2, 0, 544)); emit(enc_addi(6, 5, 4));
        for (int i = 0; i < 256; i++) emit(enc_addi(gpr_addr_t'(1+i%30), 0, i));
        emit(enc_addi(1, 0, 2003)); emit(enc_addi(2, 0, 7)); emit(enc_divu(3, 1, 2));
        // RAW 消费者在前，独立 ALU 在后，局部乱序须在除法结果前推进独立项。
        emit(enc_addi(4, 3, 1));
        for (int i = 0; i < 8; i++) emit(enc_addi(gpr_addr_t'(10+i), 0, i+9));
        emit(enc_addi(1, 0, 13)); emit(enc_addi(3, 3, 4)); emit(enc_addi(3, 3, 2));
        emit(enc_mul(4, 1, 2)); emit(enc_addi(4, 0, 71)); emit(enc_add(5, 4, 3));
        emit(enc_sw(5, 0, 512)); emit(enc_lw(6, 0, 512)); emit(enc_addi(7, 6, 1));
        emit(32'h0ff0000f); emit(enc_lw(29, 0, 548));
        // Store 未得到外部 ready 时，两个 Load 仍须完成转发；x0 不能成为依赖者。
        emit(32'h0ff0000f); emit(enc_addi(25, 0, 90)); emit(enc_sw(25, 0, 600));
        emit(enc_lw(0, 0, 600)); emit(enc_lw(26, 0, 600));
        emit(enc_addi(27, 26, 1)); emit(enc_addi(28, 0, 7));
        // 错路的同名写者、访存与 MDU 都必须被恢复取消。
        emit(enc_beq(7, 7, 16)); emit(enc_addi(7, 0, 999)); emit(enc_sw(7, 0, 516)); emit(enc_divu(8, 7, 2));
        emit(enc_addi(8, 7, 2)); emit(enc_addi(9, 0, 1));
        emit(enc_beq(9, 0, 8)); emit(enc_addi(9, 9, 3));
        emit(enc_jal(10, 12)); emit(enc_addi(10, 0, 99)); emit(enc_sw(10, 0, 520));
        emit(enc_addi(11, 10, 4));
        for (int i = 0; i < 500; i++) begin
            emit(enc_r(0, gpr_addr_t'(random_word()%30), gpr_addr_t'(random_word()%30),
                       3'(random_word()%8), gpr_addr_t'(1+random_word()%30), 7'h33));
        end
        for (int i = 0; i < 8; i++) begin
            emit(enc_lw(10, 0, 512)); emit(enc_addi(20, 0, 100));
            emit(enc_addi(21, 0, 200)); emit(enc_lw(11, 0, 512 + DBUS_BYTES));
        end
        emit(enc_jal(1, 12)); emit(enc_addi(22, 0, 5)); emit(enc_jal(0, 16));
        emit(enc_addi(23, 0, 4)); emit(enc_jalr(0, 1, 0)); emit(enc_sw(23, 0, 524));
        if (XLEN == 64) begin
            emit(enc_i(-1, 0, 0, 12, 7'h1b)); emit(enc_i(3, 12, 0, 12, 7'h1b));
        end
        emit(enc_csrrs(28, CSR_MINSTRET, 0));
        stop_pc = length * 4; emit(enc_addi(31, 0, 1234)); emit(enc_jal(0, 0));
        repeat (3) @(negedge clk); rst = 0;
        wait (done); @(negedge clk);
        assert (max_issue_streak >= 64 && max_retire_streak >= 64)
            else $fatal(1, "sustained dual throughput issue=%0d retire=%0d", max_issue_streak, max_retire_streak);
        assert (live_waw > 0 && background_alu > 0 && branches >= 3) else $fatal(1, "coverage WAW/MDU/branch missing");
        if (LIMITED_INTEGER_OOO) assert (integer_bypasses > 0) else $fatal(1, "integer bypass coverage missing");
        assert (fence_executed) else $fatal(1, "FENCE coverage missing");
        assert (store_hint_count[0] + store_hint_count[1] >= 2 && zero_hint_count > 0 && reused_hint_count > 0)
            else $fatal(1, "Store hint coverage lane0=%0d lane1=%0d x0=%0d reused=%0d",
                        store_hint_count[0], store_hint_count[1], zero_hint_count, reused_hint_count);
        assert (dual_requests > 0 && pair_counts[int'(SCHED_MEMORY)][int'(SCHED_MEMORY)] > 0)
            else $fatal(1, "dual LSU issue/request coverage missing");
        assert (ram[516] == 0 && ram[520] == 0 && ram[544] == 0) else $fatal(1, "wrong-path Store");
        assert (decode_jals[0] > 0 && decode_jals[1] > 0 && frontend_jumps > 0 &&
                frontend_jumps <= decode_jals[0] + decode_jals[1]) else $fatal(1, "D1 JAL lane coverage");
        $display("FRONTEND JAL lane0=%0d lane1=%0d redirects=%0d", decode_jals[0], decode_jals[1], frontend_jumps);
        $display("SCHEDULER integer_bypasses=%0d", integer_bypasses);
        $display("PASS tb_scoreboard_core XLEN=%0d retired=%0d cycles=%0d issue_streak=%0d retire_streak=%0d live_waw=%0d background_alu=%0d",
                 XLEN, retired, cycles, max_issue_streak, max_retire_streak, live_waw, background_alu);
        for (int a = 0; a < 5; a++)
            for (int b = 0; b < 5; b++)
                if (pair_counts[a][b] > 0) $display("PAIR class=%0d/%0d count=%0d", a, b, pair_counts[a][b]);
        $display("LSU requests=%0d dual_request_cycles=%0d", requests, dual_requests);
        $display("LSU Store hints lane0=%0d lane1=%0d x0=%0d reused=%0d stalled=%0d",
                 store_hint_count[0], store_hint_count[1], zero_hint_count, reused_hint_count, store_stall_cycles);
        $finish;
    end
endmodule
