// Module: tb_core_nonblocking
// Description: Checks independent MDU completion, retained early jumps, strict age barriers, and precise faults.
module tb_core_nonblocking;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    logic imem_rsp_error = 0;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic bus_pending;
    int bus_delay, requests, scenario, finish_pc, expected_pc;
    int mdu_cycles, early_alu, launches, finishes, jal_pairs, jal_trains, jal_correct, jal_wrong;
    int raw_waits, waw_waits, lsu_age_waits, csr_head_waits, collisions, traps;
    int young_lsu_owner_waits, total_owner_waits = 0;
    int expected_loop, completed_scenarios = 0;
    int total_early = 0, total_lsu = 0, total_csr = 0, total_raw = 0, total_waw = 0;
    int max_mdu_cycles = 0;
    int alu_issue_run, max_alu_issue_run, alu_retire_run, max_alu_retire_run;
    int measured_alu_issue_run = 0, measured_alu_retire_run = 0;
    int completed_alu_unretired, max_completed_alu;
    logic load_backlog_seen, csr_backlog_seen;
    logic old_mdu_retired;
    int post_mdu_lsu_waits, post_mdu_csr_waits;
    int measured_backlog = 0, total_post_mdu_lsu = 0, total_post_mdu_csr = 0;
    logic done;
    xlen_t expected_data [128];
    logic check_data [128];
    always #5 clk = ~clk;

    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    sim_imem #(.DEPTH_WORDS(128)) u_imem (
        .clk, .rst, .req_valid(imem_req_valid), .req_addr(imem_req_addr),
        .req_ready(imem_req_ready), .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready),
        .rsp_error(), .rsp_error_1()
    );

    // 合法单槽数据总线：请求后延迟响应，响应保持到 fire；MMIO 读也算不可撤销请求。
    assign dmem_req_ready = !bus_pending && !dmem_rsp_valid;
    always @(posedge clk) begin
        if (rst) begin
            bus_pending <= 0; bus_delay <= 0; requests = 0;
            dmem_rsp_valid <= 0; dmem_rsp_error <= 0; dmem_rsp_rdata <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
            if (bus_pending) begin
                if (bus_delay == 0) begin
                    bus_pending <= 0;
                    dmem_rsp_valid <= 1;
                    dmem_rsp_error <= scenario == 2 || scenario == 3;
                    dmem_rsp_rdata <= xlen_t'(73);
                end else bus_delay <= bus_delay - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (!dmem_req_write && requests == 0 &&
                        dmem_req_addr == ((scenario == 5) ? xlen_t'(8) : xlen_t'(512)))
                    else $fatal(1, "C2 side effect escaped age scenario=%0d addr=%h", scenario, dmem_req_addr);
                requests++; bus_pending <= 1; bus_delay <= 5;
            end
        end
    end

    // 与队列监视器分工：这里独立查指令语义和实际重叠，监视器查完整 ID/年龄/总线所有权。
    always @(posedge clk) begin
        if (rst) begin
            mdu_cycles = 0; early_alu = 0; launches = 0; finishes = 0;
            jal_pairs = 0; jal_trains = 0; jal_correct = 0; jal_wrong = 0;
            raw_waits = 0; waw_waits = 0; lsu_age_waits = 0; csr_head_waits = 0; collisions = 0;
            young_lsu_owner_waits = 0;
            alu_issue_run = 0; max_alu_issue_run = 0; alu_retire_run = 0; max_alu_retire_run = 0;
            completed_alu_unretired = 0; max_completed_alu = 0;
            load_backlog_seen = 0; csr_backlog_seen = 0;
            old_mdu_retired = 0; post_mdu_lsu_waits = 0; post_mdu_csr_waits = 0;
        end else begin
            // 独立按软件指定的五条 ALU 的完成/退休事件计数，不读取 DUT done 数组。
            if (scenario inside {2, 3, 4}) begin
                if (dut.wb_complete_valid && dut.wb_complete_ready &&
                    dut.mem_wb_q.pc >= 36 && dut.mem_wb_q.pc <= 52) completed_alu_unretired++;
                if (commit_valid && commit_pc >= 36 && commit_pc <= 52) completed_alu_unretired--;
                assert (completed_alu_unretired >= 0) else $fatal(1, "ALU retired before its completion");
                if (completed_alu_unretired > max_completed_alu) max_completed_alu = completed_alu_unretired;
                if (dut.mem_age_stall && !dmem_req_write && completed_alu_unretired >= 2)
                    load_backlog_seen = 1;
                if (dut.d2_ex_q.valid && dut.d2_ex_q.uop.csr_valid &&
                    !dut.csr_is_head && completed_alu_unretired >= 2) csr_backlog_seen = 1;
                // 只用软件指定 DIV 的退休事件证明旧 M 已离开，而非拿 DUT 的 M 忙信号作答案。
                // 标志在本段最后更新，计数严格发生在 M 退休后的下一拍或更晚。
                if (old_mdu_retired && completed_alu_unretired >= 2) begin
                    if (dut.mem_age_stall && !dmem_req_write) post_mdu_lsu_waits++;
                    if (dut.d2_ex_q.valid && dut.d2_ex_q.uop.csr_valid && !dut.csr_is_head)
                        post_mdu_csr_waits++;
                end
                if (commit_valid && commit_pc == xlen_t'(32) && !commit_exception)
                    old_mdu_retired = 1;
            end
            if (scenario == 7 && dut.dispatch_valid && dut.dispatch_ready &&
                dut.alloc_meta.pc >= 32 && dut.alloc_meta.pc <= 100) begin
                alu_issue_run++;
                if (alu_issue_run > max_alu_issue_run) max_alu_issue_run = alu_issue_run;
            end else alu_issue_run = 0;
            if (scenario == 7 && commit_valid && commit_pc >= 32 && commit_pc <= 100) begin
                alu_retire_run++;
                if (alu_retire_run > max_alu_retire_run) max_alu_retire_run = alu_retire_run;
            end else alu_retire_run = 0;
            if (dut.mdu_req_valid && dut.mdu_req_ready) launches++;
            if (dut.mdu_complete_valid && dut.mdu_complete_ready) finishes++;
            if (!dut.mdu_req_ready && !dut.mdu_complete_valid) mdu_cycles++;
            if (scenario != 7 && dut.wb_complete_valid && dut.wb_complete_ready &&
                dut.retire_query_result.any_unretired_mdu &&
                dut.mem_wb_q.pc > 32 && dut.mem_wb_q.uop.fu == FU_ALU && !dut.mem_wb_q.exc.valid) early_alu++;
            if (dut.mdu_complete_valid && dut.wb_complete_valid) collisions++;
            if (dut.d2_ex_q.valid && !dut.mdu_operands_ready && !dut.d2_ex_q.exc.valid) raw_waits++;
            if (dut.dispatch_waw_stall) waw_waits++;
            if (dut.mem_age_stall) begin
                lsu_age_waits++;
                assert (!dmem_req_valid && !dut.mem_packet.valid)
                    else $fatal(1, "age-stalled MEM entered WB or bus");
            end
            // C3b 只有一个描述符：旧错误 Load 已被独立总线模型接受时，年轻 LSU 留在 EX。
            // 这属于 owner 容量等待，不冒充 MEM 队头等待；两者都必须阻止错误路径副作用。
            if ((scenario == 2 || scenario == 3) && bus_pending &&
                dut.d2_ex_q.valid && dut.d2_ex_q.pc == 60) begin
                young_lsu_owner_waits++;
                assert (!dut.lsu_issue_valid && !dut.lsu_issue_ready && !dmem_req_valid)
                    else $fatal(1, "younger LSU replaced the accepted faulting owner");
            end
            if (dut.d2_ex_q.valid && dut.d2_ex_q.uop.csr_valid && !dut.csr_is_head)
                csr_head_waits++;
            if (dut.d2_ex_q.valid && dut.d2_ex_q.uop.csr_valid && dut.ex_stage_advance)
                assert (dut.csr_is_head || dut.d2_ex_q.exc.valid)
                    else $fatal(1, "CSR executed before architectural predecessors");
            if (scenario == 1 && dut.d1_d2_q.valid && dut.d1_d2_q.pc == 32 &&
                dut.d1_packet.valid && dut.d1_packet.pc == 36 && dut.dispatch_valid && dut.dispatch_ready) begin
                jal_pairs++;
                if (dut.d1_packet.pred.taken && dut.d1_packet.pred.target == 48) jal_correct++;
                else jal_wrong++;
                assert (dut.pipeline_actions.d1_d2 == PIPE_ADVANCE && !dut.execution_cancel)
                    else $fatal(1, "D2 MDU plus D1 JAL was lost or cancelled the older instruction");
            end
            // JAL 的解析与训练已分开：同 PC 的每次正常退休各训练一次。
            if (scenario == 1 && dut.predictor_update.valid && dut.predictor_update.pc == 36) begin
                assert (commit_valid && !commit_exception && commit_pc == 36)
                    else $fatal(1, "JAL trained before normal retirement");
                jal_trains++;
            end
            if (scenario == 5 && dut.d2_ex_q.valid && dut.d2_ex_q.uop.mem_read && !dut.mdu_operands_ready)
                assert (!dut.ex_serialize_req && !dut.ex_packet.exc.valid)
                    else $fatal(1, "unresolved load source raised a false alignment trap");
        end
    end

    task automatic put(input int pc, input logic [31:0] inst);
        u_imem.mem[pc/4] = inst;
    endtask
    task automatic value(input int pc, input logic [31:0] inst, input xlen_t result);
        put(pc, inst); check_data[pc/4] = 1; expected_data[pc/4] = result;
    endtask

    initial begin
        for (scenario = 0; scenario < 8; scenario++) begin
            @(negedge clk); rst = 1;
            for (int i = 0; i < 128; i++) begin
                u_imem.mem[i] = nop(); check_data[i] = 0; expected_data[i] = 0;
            end
            value(0, enc_addi(1, 0, 42), 42);
            value(4, enc_addi(14, 0, -1), '1);
            value(8, enc_addi(2, 0, 3), 3);
            value(12, enc_addi(11, 0, 512), 512);
            value(16, enc_addi(12, 0, 256), 256);
            put(20, enc_csrrw(0, CSR_MTVEC, 12));
            value(24, enc_addi(15, 0, 2), 2);
            value(32, enc_divu(3, 14, 2), {XLEN{1'b1}} / xlen_t'(3));
            for (int i = 0; i < 5; i++) value(36+4*i, enc_addi(gpr_addr_t'(16+i), 0, i+1), xlen_t'(i+1));
            finish_pc = 72;
            unique case (scenario)
                0: begin
                    // 同名写者不得与旧 MDU 同时分配；独立 ALU 已提前完成，不得提前退休。
                    value(56, enc_addi(3, 0, 9), 9);
                    value(60, enc_add(13, 3, 16), 10);
                end
                1: begin
                    // 第二次取指可能先于首次 JAL 退休训练；第三轮保留真实热预测覆盖。
                    value(24, enc_addi(15, 0, 3), 3);
                    put(36, enc_jal(4, 12)); check_data[9] = 1; expected_data[9] = 40;
                    put(40, enc_sw(0, 11, 0)); put(44, enc_sw(0, 11, 4));
                    check_data[10] = 0; check_data[11] = 0;
                    put(48, enc_addi(15, 15, -1)); check_data[12] = 0;
                    put(52, enc_bne(15, 0, -20)); check_data[13] = 0;
                    expected_loop = 3;
                end
                2, 3: begin
                    put(56, enc_lw(13, 11, 0));
                    put(60, scenario == 2 ? enc_sw(1, 11, 4) : enc_lw(21, 11, 4));
                    finish_pc = 256;
                end
                4: begin
                    put(56, enc_csrrw(0, CSR_MSCRATCH, 1));
                    value(60, enc_addi(21, 0, 6), 6); value(64, enc_addi(22, 0, 7), 7);
                    value(68, enc_csrrs(13, CSR_MSCRATCH, 0), 42);
                end
                5: begin
                    value(28, enc_addi(14, 0, 18), 18);
                    value(32, enc_divu(5, 14, 2), 6);
                    // pending 时 resolver 输出 0，0+2 未对齐，但真实 6+2 对齐，不能提前报错。
                    value(36, enc_lw(6, 5, 2), 73);
                    for (int i = 10; i < 14; i++) begin put(i*4, nop()); check_data[i] = 0; end
                end
                6: begin
                    // 两槽也能真正覆盖 WAW：同名写者紧跟旧 DIV，不依赖更大的 ALU 积压窗口。
                    value(36, enc_addi(3, 0, 9), 9);
                    value(40, enc_addi(13, 3, 1), 10);
                    for (int i = 11; i < 14; i++) begin put(i*4, nop()); check_data[i] = 0; end
                end
                7: begin
                    // 不同 rd 的真实 RAW 链必须每拍使用 MEM 前递；同名 WAW 不属于此吞吐承诺。
                    for (int i = 0; i < 18; i++)
                        value(32+4*i, enc_addi(gpr_addr_t'(3+i), i == 0 ? gpr_addr_t'(0) : gpr_addr_t'(2+i), 1), xlen_t'(i+1));
                    value(104, enc_mul(25, 3, 20), 18);
                    finish_pc = 108;
                end
                default: ;
            endcase
            value(finish_pc, enc_addi(31, scenario == 7 ? gpr_addr_t'(25) : gpr_addr_t'(0), scenario == 7 ? -17 : 1), 1);
            put(finish_pc+4, enc_jal(0, 0));
            repeat (4) @(posedge clk);
            @(negedge clk); rst = 0; done = 0; expected_pc = 0; traps = 0;
            for (int cycle = 0; cycle < 2000 && !done; cycle++) begin
                @(negedge clk);
                if (commit_valid) begin
                    assert (commit_pc == xlen_t'(expected_pc) && commit_inst == u_imem.mem[expected_pc/4])
                        else $fatal(1, "C2 commit order scenario=%0d pc=%h expected=%0d", scenario, commit_pc, expected_pc);
                    if (commit_exception) begin
                        assert ((scenario == 2 || scenario == 3) && expected_pc == 56 &&
                                dut.trap_cause == EXC_LOAD_ACCESS_FAULT && !commit_rd_we && requests == 1)
                            else $fatal(1, "C2 unexpected or imprecise trap scenario=%0d pc=%h", scenario, commit_pc);
                        traps++; expected_pc = 256;
                    end else begin
                        if (check_data[expected_pc/4])
                            assert (commit_rd_we && commit_rd_data == expected_data[expected_pc/4])
                                else $fatal(1, "C2 value scenario=%0d pc=%0d got=%h expected=%h", scenario,
                                            expected_pc, commit_rd_data, expected_data[expected_pc/4]);
                        done = expected_pc == finish_pc;
                        if (scenario == 1 && expected_pc == 36) expected_pc = 48;
                        else if (scenario == 1 && expected_pc == 52) begin
                            expected_loop--; expected_pc = expected_loop == 0 ? 56 : 32;
                        end else expected_pc += 4;
                    end
                end
            end
            assert (done && launches == (scenario == 1 ? 3 : 1) && finishes == launches)
                else $fatal(1, "C2 timeout or repeated MDU scenario=%0d req=%0d done=%0d", scenario, launches, finishes);
            if (scenario == 0)
                assert (early_alu > 0 && mdu_cycles >= 5)
                    else $fatal(1, "C2 no independent completion/WAW coverage early=%0d cycles=%0d waw=%0d", early_alu, mdu_cycles, waw_waits);
            if (scenario == 1)
                assert (jal_pairs == 3 && jal_trains == 3 && jal_correct > 0 && jal_wrong > 0 && requests == 0)
                    else $fatal(1, "C2 JAL coverage pair=%0d train=%0d correct=%0d wrong=%0d", jal_pairs, jal_trains, jal_correct, jal_wrong);
            if (scenario == 2 || scenario == 3)
                assert (traps == 1 && requests == 1 && (lsu_age_waits > 0 || young_lsu_owner_waits > 0))
                    else $fatal(1, "fault barrier coverage age=%0d owner=%0d", lsu_age_waits, young_lsu_owner_waits);
            if (scenario == 4) assert (csr_head_waits > 0) else $fatal(1, "C2 CSR age not exercised");
            if (RETIRE_ENTRIES == 8 && (scenario == 2 || scenario == 3))
                assert (load_backlog_seen && max_completed_alu >= 2 && post_mdu_lsu_waits > 0)
                    else $fatal(1, "eight-entry load counterexample lacked backlog after old MDU retirement");
            if (RETIRE_ENTRIES == 8 && scenario == 4)
                assert (csr_backlog_seen && max_completed_alu >= 2 && post_mdu_csr_waits > 0)
                    else $fatal(1, "eight-entry CSR counterexample lacked backlog after old MDU retirement");
            if (scenario inside {2, 3, 4}) begin
                $display("COVER backlog scenario=%0d peak=%0d post_mdu_lsu=%0d post_mdu_csr=%0d",
                         scenario, max_completed_alu, post_mdu_lsu_waits, post_mdu_csr_waits);
                if (max_completed_alu > measured_backlog) measured_backlog = max_completed_alu;
                total_post_mdu_lsu += post_mdu_lsu_waits;
                total_post_mdu_csr += post_mdu_csr_waits;
            end
            if (scenario == 5) assert (raw_waits > 0 && requests == 1) else $fatal(1, "C2 real operand wait not exercised");
            if (scenario == 6) assert (waw_waits > 0) else $fatal(1, "C2 real WAW wait not exercised");
            if (scenario == 7) begin
                // 两槽的结构容量不足以覆盖三段普通执行；这里只要求四/八槽保持 II=1。
                if (RETIRE_ENTRIES >= 4)
                    assert (max_alu_issue_run >= 8 && max_alu_retire_run >= 8)
                        else $fatal(1, "C2 ordinary ALU lost II1 issue=%0d retire=%0d", max_alu_issue_run, max_alu_retire_run);
                measured_alu_issue_run = max_alu_issue_run;
                measured_alu_retire_run = max_alu_retire_run;
            end
            total_early += early_alu; total_lsu += lsu_age_waits; total_csr += csr_head_waits;
            total_raw += raw_waits; total_waw += waw_waits;
            total_owner_waits += young_lsu_owner_waits;
            if (mdu_cycles > max_mdu_cycles) max_mdu_cycles = mdu_cycles;
            completed_scenarios++;
        end
        $display("PASS tb_core_nonblocking RV%0d entries=%0d scenarios=%0d early_alu=%0d mdu_cycles=%0d raw=%0d waw=%0d lsu_head=%0d csr_head=%0d alu_issue_run=%0d alu_retire_run=%0d backlog=%0d post_mdu_lsu=%0d post_mdu_csr=%0d lsu_owner_wait=%0d",
                 XLEN, RETIRE_ENTRIES, completed_scenarios, total_early, max_mdu_cycles,
                 total_raw, total_waw, total_lsu, total_csr, measured_alu_issue_run, measured_alu_retire_run,
                 measured_backlog, total_post_mdu_lsu, total_post_mdu_csr, total_owner_waits);
        $finish;
    end
endmodule
