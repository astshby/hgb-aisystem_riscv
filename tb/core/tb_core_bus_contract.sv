// Module: tb_core_bus_contract
// Description: Checks delayed stores, precise faults and MDU cancellation, fences, and instruction replacement.
module tb_core_bus_contract;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
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

    logic [7:0] memory [0:2047];
    logic pending_q, pending_error_q;
    logic pending_write_q;
    xlen_t pending_data_q;
    int delay_q, requests, scenario;
    int cycles, stores_retired, fences_retired;
    int successful_store_responses, successful_store_commits;
    int mdu_launches;
    logic mdu_busy_before_fault, fault_seen;
    logic mdu_completed_before_fault;
    logic branch_before_fault, branch_operand_wait;
    logic done;
    logic [31:0] replacement;
    localparam int LOAD_BRANCH_PC = RETIRE_ENTRIES == 2 ? 16 : 20;
    localparam int LOAD_BRANCH_WRONG_PC = RETIRE_ENTRIES == 2 ? 20 : 24;
    always #5 clk = ~clk;
    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);

    assign imem_req_ready = !imem_rsp_valid || imem_rsp_ready;
    assign dmem_req_ready = !pending_q && (!dmem_rsp_valid || dmem_rsp_ready);

    // I/D 访问同一份内存，才能观察 Store 后 FENCE.I 的真实指令可见性。
    always_ff @(posedge clk) begin
        if (rst) begin
            imem_rsp_valid <= 1'b0;
            imem_rsp_error <= 1'b0;
        end else begin
            if (imem_rsp_valid && imem_rsp_ready)
                imem_rsp_valid <= 1'b0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1'b1;
                imem_rsp_error <= scenario == 2 && imem_req_addr == xlen_t'(12);
                for (int lane = 0; lane < 4; lane++)
                    imem_rsp_data[8*lane +: 8] <= memory[int'(imem_req_addr) + lane];
            end
        end
    end

    // 读写都延迟完成；错误写不产生副作用，年轻访问不得越过旧访问错误。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            pending_error_q <= 1'b0;
            pending_write_q <= 1'b0;
            pending_data_q <= '0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_error <= 1'b0;
            dmem_rsp_rdata <= '0;
            delay_q <= 0;
            requests <= 0;
            successful_store_responses <= 0;
            successful_store_commits <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready) begin
                dmem_rsp_valid <= 1'b0;
                if (pending_write_q && !dmem_rsp_error)
                    successful_store_responses <= successful_store_responses + 1;
            end
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_error <= pending_error_q;
                    dmem_rsp_rdata <= pending_data_q;
                end else
                    delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (dmem_req_size == MEM_WORD) else $fatal(1, "request size lost");
                requests <= requests + 1;
                pending_q <= 1'b1;
                delay_q <= scenario == 7 ? XLEN + 30 : 6;
                pending_error_q <= scenario < 2 || scenario == 4 || scenario == 5 || scenario == 7;
                pending_write_q <= dmem_req_write;
                for (int lane = 0; lane < DBUS_BYTES; lane++) begin
                    pending_data_q[8*lane +: 8] <=
                        memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1)) + lane];
                    if (dmem_req_write && scenario >= 2 && dmem_req_wstrb[lane])
                        memory[(int'(dmem_req_addr) & ~(DBUS_BYTES-1)) + lane] <=
                            dmem_req_wdata[8*lane +: 8];
                end
            end
            // 响应先握手、WB 下一拍退休；独立记录成功响应，不能依赖当拍总线仍保持 valid。
            // 每次 Store 退休恰好消耗一笔已完成的成功写，提前退休或重复退休都会失败。
            if (commit_valid && !commit_exception && commit_inst[6:0] == 7'h23) begin
                assert (successful_store_responses == successful_store_commits + 1)
                    else $fatal(1, "Store retired without exactly one prior successful response");
                successful_store_commits <= successful_store_commits + 1;
            end
        end
    end

    // 用真实请求握手记录年轻 M 运算，证明测试确实覆盖“旧 Load 错误取消已启动除法”。
    always @(posedge clk) begin
        if (rst) begin
            mdu_launches = 0;
            mdu_busy_before_fault = 1'b0;
            mdu_completed_before_fault = 1'b0;
            branch_before_fault = 1'b0;
            branch_operand_wait = 1'b0;
        end else begin
            if (dut.mdu_req_valid && dut.mdu_req_ready)
                mdu_launches++;
            if ((scenario == 4 || scenario == 7) && mdu_launches == 1 && dut.lsu_wait &&
                !dut.execution_cancel && !dut.mdu_req_ready)
                mdu_busy_before_fault = 1'b1;
            if (scenario == 7 && mdu_launches == 1 && dut.lsu_wait && dut.mdu_complete_valid) begin
                mdu_completed_before_fault = 1'b1;
                assert (dut.mdu_completion.result.gpr_data == xlen_t'(3))
                    else $fatal(1, "held completed division missing before fault");
            end
            // LSU 等待不冻结年轻分支；结果可提前捕获/完成，但老故障仍取消所有年轻架构效果。
            // 覆盖仍要求真实的年轻分支结果，并验证旧故障前不能架构退休，不依赖它固定留在哪级。
            if (scenario == 5 && dut.u_ex_stage.u_branch_result_register.valid_q &&
                ((dut.lsu_request_pending && !dmem_req_write) || dut.lsu_wait)) begin
                branch_before_fault = 1'b1;
                assert (!dut.execution_cancel)
                    else $fatal(1, "young branch cancelled older Load owner");
            end
            if (scenario == 6 && dut.lsu_wait && dut.d2_ex_q.valid && dut.d2_ex_q.pc == xlen_t'(LOAD_BRANCH_PC)) begin
                branch_operand_wait = 1'b1;
                assert (!dut.mdu_operands_ready && !dut.u_ex_stage.u_branch_result_register.valid_q)
                    else $fatal(1, "branch captured outstanding load value");
            end
        end
    end

    task automatic put_inst(input int addr, input logic [31:0] inst);
        for (int lane = 0; lane < 4; lane++)
            memory[addr + lane] = inst[8*lane +: 8];
    endtask

    initial begin
        for (scenario = 0; scenario < 8; scenario++) begin
            @(negedge clk);
            rst = 1'b1;
            for (int addr = 0; addr < 2048; addr += 4)
                put_inst(addr, nop());
            if (scenario < 3 || scenario >= 4) begin
                put_inst(0, enc_addi(1, 0, 256));
                put_inst(4, enc_csrrw(0, CSR_MTVEC, 1));
                put_inst(8, enc_addi(2, 0, 32'h300));
                put_inst(12, scenario == 1 ? enc_sw(0, 2, 0) : enc_lw(3, 2, 0));
                put_inst(16, enc_sw(0, 2, 4));
                put_inst(256, enc_jal(0, 0));
                if (scenario == 4 || scenario == 7) begin
                    // DIVU 与旧 Load 的目的寄存器无依赖，可在错误响应到达前启动。
                    put_inst(16, enc_divu(4, 2, 1));
                    put_inst(20, enc_sw(4, 2, 4));
                    put_inst(256, enc_divu(5, 2, 1));
                    put_inst(260, enc_addi(6, 5, 0));
                    put_inst(264, enc_jal(0, 0));
                end else if (scenario == 5) begin
                    put_inst(16, enc_beq(1, 1, 16));
                    put_inst(20, enc_sw(0, 2, 4));
                    put_inst(256, enc_addi(6, 0, 1));
                    put_inst(260, enc_jal(0, 0));
                end else if (scenario == 6) begin
                    put_inst(32'h300, 32'd17);
                    put_inst(16, enc_addi(4, 0, 17));
                    put_inst(20, enc_beq(3, 4, 12));
                    put_inst(24, enc_sw(0, 2, 4));
                    put_inst(32, enc_addi(6, 0, 1));
                    put_inst(36, enc_jal(0, 0));
                    // 两槽无法同时容纳 Load、无关 ADDI 和 Branch；改用已初始化的 x1，
                    // 仍要求真实覆盖“EX 分支因旧 Load 未返回而不能采样操作数”。四/八槽保留原程序。
                    if (RETIRE_ENTRIES == 2) begin
                        put_inst(32'h300, 32'd256);
                        put_inst(16, enc_beq(3, 1, 16));
                        put_inst(20, enc_sw(0, 2, 4));
                    end
                end
            end else begin
                replacement = enc_addi(5, 0, 7);
                // 先执行旧 JAL，真实训练 BTB；随后把它改成普通 ADDI。
                put_inst(0, enc_jal(10, 128));
                put_inst(4, enc_addi(1, 0, 128));
                put_inst(8, enc_lui(2, replacement[31:12]));
                put_inst(12, enc_addi(2, 2, int'(replacement[11:0])));
                put_inst(16, enc_sw(2, 1, 0));
                put_inst(20, 32'h0ff0_000f); // FENCE 排空已接收的写入。
                put_inst(24, 32'h0000_100f); // FENCE.I 丢弃年轻取指，并清除旧预测。
                put_inst(28, enc_jal(0, 100));
                put_inst(128, enc_jal(0, 8));
                put_inst(132, enc_addi(6, 5, 0));
                put_inst(136, enc_jalr(0, 10, 0));
            end
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            done = 1'b0;
            fault_seen = 1'b0;
            stores_retired = 0;
            fences_retired = 0;
            for (cycles = 0; cycles < 300; cycles++) begin
                @(negedge clk);
                if (commit_valid) begin
                    if ((scenario < 3 || scenario == 4 || scenario == 5 || scenario == 7) && commit_exception) begin
                        assert (commit_pc == xlen_t'(12) && !commit_rd_we && dut.trap_enter)
                            else $fatal(1, "fault not precise scenario=%0d", scenario);
                        assert (dut.trap_cause == ((scenario == 0 || scenario >= 4) ? EXC_LOAD_ACCESS_FAULT :
                                scenario == 1 ? EXC_STORE_ACCESS_FAULT : EXC_INST_ACCESS_FAULT))
                            else $fatal(1, "wrong access fault cause");
                        assert (dut.trap_tval == (scenario == 2 ? xlen_t'(12) : xlen_t'(32'h300)))
                            else $fatal(1, "wrong fault address");
                        assert (requests == (scenario == 2 ? 0 : 1) && !dmem_req_valid)
                            else $fatal(1, "younger side effect escaped fault");
                        assert (dut.execution_cancel) else $fatal(1, "synchronous fault did not cancel execution");
                        if (scenario == 4 || scenario == 7) begin
                            assert (!fault_seen && mdu_busy_before_fault && mdu_launches == 1)
                                else $fatal(1, "younger division was not active before old Load fault");
                            if (scenario == 7)
                                // 独立完成可先进入队列，但老 Load 故障前不能架构退休。
                                assert (mdu_completed_before_fault &&
                                        dut.retire_query_result.any_unretired_mdu)
                                    else $fatal(1, "completed younger division lost before precise cancellation");
                            fault_seen = 1'b1;
                        end else if (scenario == 5) begin
                            assert (!fault_seen && branch_before_fault)
                                else $fatal(1, "branch cancellation coverage missing");
                            fault_seen = 1'b1;
                        end else begin
                            done = 1'b1;
                            break;
                        end
                    end
                    if (scenario == 5 && !commit_exception) begin
                        assert (commit_pc < 12 || commit_pc >= 256)
                            else $fatal(1, "cancelled branch or wrong-path instruction retired");
                        if (commit_pc == 256) begin
                            assert (fault_seen && commit_rd_we && commit_rd_data == xlen_t'(1) &&
                                    requests == 1 && !dut.u_ex_stage.u_branch_result_register.valid_q)
                                else $fatal(1, "branch snapshot survived precise fault");
                            done = 1'b1;
                            break;
                        end
                    end
                    if (scenario == 6) begin
                        assert (!commit_exception && commit_pc != xlen_t'(LOAD_BRANCH_WRONG_PC))
                            else $fatal(1, "load-dependent branch used stale data");
                        if (commit_pc == 32) begin
                            assert (branch_operand_wait && requests == 1 &&
                                    commit_rd_we && commit_rd_data == xlen_t'(1))
                                else $fatal(1, "load-dependent branch wait not covered");
                            done = 1'b1;
                            break;
                        end
                    end
                    if ((scenario == 4 || scenario == 7) && !commit_exception) begin
                        assert (commit_pc < 12 || commit_pc >= 256)
                            else $fatal(1, "cancelled younger instruction retired");
                        if (commit_pc == 260) begin
                            assert (fault_seen && commit_rd_we && commit_rd_data == xlen_t'(3) &&
                                    mdu_launches == 2 && requests == 1)
                                else $fatal(1, "MDU did not recover cleanly after precise fault");
                            done = 1'b1;
                            break;
                        end
                    end
                    if (scenario == 3) begin
                        assert (!commit_exception) else $fatal(1, "unexpected fence trap");
                        if (commit_pc == xlen_t'(16)) begin
                            stores_retired++;
                            assert (dut.u_predictor.u_btb.valid_q[32])
                                else $fatal(1, "old code did not train BTB");
                        end
                        if (commit_pc == xlen_t'(20) || commit_pc == xlen_t'(24)) begin
                            fences_retired++;
                            assert (stores_retired == 1 && !pending_q && !dmem_rsp_valid)
                                else $fatal(1, "fence passed an incomplete write");
                        end
                        if (commit_pc == xlen_t'(132)) begin
                            assert (commit_rd_data == xlen_t'(7) && requests == 1 && fences_retired == 2)
                                else $fatal(1, "FENCE.I observed stale instruction or duplicate Store");
                            done = 1'b1;
                            break;
                        end
                    end
                end
            end
            assert (done) else $fatal(1, "bus contract timeout scenario=%0d", scenario);
        end
        $display("PASS tb_core_bus_contract RV%0d scenarios=8", XLEN);
        $finish;
    end
endmodule
