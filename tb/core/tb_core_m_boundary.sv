// Module: tb_core_m_boundary
// Description: Checks tagged MDU issue/completion/retirement, shortest results, and younger redirects.
module tb_core_m_boundary;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic dmem_store_fire;
    xlen_t dmem_store_addr, dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    int cycles = 0;
    int launches = 0;
    int responses = 0;
    int retired = 0;
    int next_pc = 0;
    logic launch_q, single_cycle_q;
    logic dsp_launch_q, dsp_capture_q;
    logic branch_wait_seen = 1'b0;
    retire_id_t launch_id_q;
    xlen_t launch_pc_q;
    logic tracked_live [RETIRE_ENTRIES];
    logic tracked_complete [RETIRE_ENTRIES];
    retire_id_t tracked_id [RETIRE_ENTRIES];
    xlen_t tracked_pc [RETIRE_ENTRIES];
    int m_retired = 0;
    xlen_t expected [20];
    logic complete = 1'b0;

    always #5 clk = ~clk;
    pipeline_pkg::retire_trace_t commit_trace [2], sampled_trace [2];
    sim_cpu_top dut (.*);
    // 上升沿记录本拍真实退休，下降沿按年龄遍历两个端口。
    always_ff @(posedge clk) begin
        if (rst) begin sampled_trace[0] <= '0; sampled_trace[1] <= '0; end
        else sampled_trace <= commit_trace;
    end

    // 独立记分板只从真实握手接纳 ID；完整代次必须贯穿完成与退休。
    // 完成可与退休同沿，先登记完成再检查退休，不能要求 M 经过 MEM/WB。
    always @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            launches <= 0;
            responses <= 0;
            launch_q <= 1'b0;
            single_cycle_q <= 1'b0;
            dsp_launch_q <= 1'b0;
            dsp_capture_q <= 1'b0;
            m_retired = 0;
            for (int i = 0; i < RETIRE_ENTRIES; i++) begin
                tracked_live[i] = 1'b0;
                tracked_complete[i] = 1'b0;
                tracked_id[i] = '0;
                tracked_pc[i] = '0;
            end
        end else begin
            cycles <= cycles + 1;
            launch_q <= dut.u_core.mdu_req_valid && dut.u_core.mdu_req_ready;
            dsp_capture_q <= launch_q && dsp_launch_q;
            if (dut.u_core.mdu_req_valid && dut.u_core.mdu_req_ready) begin
                launches <= launches + 1;
                launch_pc_q <= dut.observed_mdu_packet.pc;
                launch_id_q <= dut.observed_mdu_packet.retire_id;
                assert (dut.observed_mdu_packet.pc inside {xlen_t'(24), xlen_t'(32),
                        xlen_t'(48), xlen_t'(52), xlen_t'(56), xlen_t'(60)})
                    else $fatal(1, "wrong-path or unexpected MDU request");
                assert (!tracked_live[dut.observed_mdu_packet.retire_id.slot])
                    else $fatal(1, "MDU slot reused before retirement");
                tracked_live[dut.observed_mdu_packet.retire_id.slot] = 1'b1;
                tracked_complete[dut.observed_mdu_packet.retire_id.slot] = 1'b0;
                tracked_id[dut.observed_mdu_packet.retire_id.slot] = dut.observed_mdu_packet.retire_id;
                tracked_pc[dut.observed_mdu_packet.retire_id.slot] = dut.observed_mdu_packet.pc;
                // PC=48 是除零，所有后端都在请求沿寄存特殊结果。
                single_cycle_q <= (dut.observed_mdu_packet.pc == xlen_t'(48));
                dsp_launch_q <= (MUL_IMPL == MUL_DSP) &&
                    (dut.observed_mdu_packet.uop.muldiv_op == MD_MUL);
            end
            if (dut.observed_mdu_complete_valid && dut.observed_mdu_complete_ready) begin
                responses <= responses + 1;
                assert (tracked_live[dut.observed_mdu_completion.id.slot] &&
                        tracked_id[dut.observed_mdu_completion.id.slot] == dut.observed_mdu_completion.id &&
                        !tracked_complete[dut.observed_mdu_completion.id.slot])
                    else $fatal(1, "stale, duplicate, or unissued MDU completion");
                assert (!dut.observed_mdu_completion.result.exc.valid &&
                        dut.observed_mdu_completion.result.gpr_data ==
                        expected[int'(tracked_pc[dut.observed_mdu_completion.id.slot] >> 2)])
                    else $fatal(1, "MDU completion ID/data mismatch");
                tracked_complete[dut.observed_mdu_completion.id.slot] = 1'b1;
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (commit_trace[lane].valid && commit_trace[lane].inst[31:25] == 7'b0000001 &&
                    commit_trace[lane].inst[6:0] inside {7'h33, 7'h3b}) begin
                    assert (tracked_live[commit_trace[lane].id.slot] &&
                            tracked_complete[commit_trace[lane].id.slot] &&
                            tracked_id[commit_trace[lane].id.slot] == commit_trace[lane].id &&
                            tracked_pc[commit_trace[lane].id.slot] == commit_trace[lane].pc &&
                            commit_trace[lane].rd_data == expected[int'(commit_trace[lane].pc >> 2)])
                        else $fatal(1, "MDU retired without its unique tagged completion");
                    tracked_live[commit_trace[lane].id.slot] = 1'b0;
                    m_retired++;
                end
            end
            assert (!dut.observed_ordinary_mdu)
                else $fatal(1, "MDU result leaked into the ordinary completion path");
        end
    end

    initial begin
        for (int i = 0; i < 64; i++) dut.u_imem.mem[i] = nop();
        for (int i = 0; i < 20; i++) expected[i] = '0;
        dut.u_imem.mem[0] = enc_addi(1, 0, 7); expected[0] = xlen_t'(7);
        dut.u_imem.mem[1] = enc_addi(2, 0, 3); expected[1] = xlen_t'(3);
        dut.u_imem.mem[6] = enc_mul(3, 1, 2); expected[6] = xlen_t'(21);
        dut.u_imem.mem[7] = enc_addi(4, 3, 1); expected[7] = xlen_t'(22);
        dut.u_imem.mem[8] = enc_div(5, 4, 2); expected[8] = xlen_t'(7);
        dut.u_imem.mem[9] = enc_beq(0, 0, 12);
        dut.u_imem.mem[10] = enc_div(6, 1, 0); // 错误路径不得发射。
        dut.u_imem.mem[11] = enc_sw(1, 0, 0);  // 错误路径不得有存储副作用。
        dut.u_imem.mem[12] = enc_div(7, 1, 0); expected[12] = '1;
        dut.u_imem.mem[13] = enc_mul(8, 3, 2); expected[13] = xlen_t'(63);
        dut.u_imem.mem[14] = enc_mul(9, 8, 2); expected[14] = xlen_t'(189);
        dut.u_imem.mem[15] = enc_rem(10, 9, 2); expected[15] = '0;
        dut.u_imem.mem[16] = enc_addi(11, 0, 1); expected[16] = xlen_t'(1);
        dut.u_imem.mem[17] = enc_jal(0, 0);
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (1000) begin
            @(negedge clk);
            assert (!dmem_store_fire) else $fatal(1, "wrong-path Store executed");
            if (launch_q) begin
                if (single_cycle_q)
                    assert (dut.observed_mdu_complete_valid &&
                            dut.observed_mdu_completion.id == launch_id_q &&
                            dut.observed_mdu_completion.result.gpr_data == '1)
                        else $fatal(1, "special division gained an extra transfer cycle");
                // DSP 后端 E0 完成，但统一结果槽在 E1 锁存，不能同拍前递未隔离的算术。
                if (dsp_launch_q)
                    assert (!dut.observed_mdu_complete_valid)
                        else $fatal(1, "DSP result bypassed the completion register");
            end
            if (dsp_capture_q)
                assert (dut.observed_mdu_complete_valid &&
                        dut.observed_mdu_completion.id == launch_id_q &&
                        dut.observed_mdu_completion.result.gpr_data == expected[int'(launch_pc_q >> 2)])
                    else $fatal(1, "registered DSP result gained more than one extra cycle");
            if (dut.observed_branch_packet.valid && dut.observed_branch_packet.pc == xlen_t'(36) &&
                launches > m_retired) begin
                branch_wait_seen = 1'b1;
                assert (!dut.u_core.execution_cancel)
                    else $fatal(1, "younger branch cancelled an unretired MDU");
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (sampled_trace[lane].valid) begin
                    assert (!sampled_trace[lane].exception && sampled_trace[lane].pc == xlen_t'(next_pc) &&
                            sampled_trace[lane].inst == dut.u_imem.mem[next_pc / 4])
                        else $fatal(1, "boundary retirement pc=%h expected=%0d", sampled_trace[lane].pc, next_pc);
                    if (next_pc < 8 || (next_pc >= 24 && next_pc != 36))
                        assert (sampled_trace[lane].rd_we && sampled_trace[lane].rd_data == expected[next_pc / 4])
                            else $fatal(1, "boundary data pc=%h got=%h expected=%h", sampled_trace[lane].pc,
                                        sampled_trace[lane].rd_data, expected[next_pc / 4]);
                    retired++;
                    if (next_pc == 64) begin
                        assert (launches == 6 && responses == 6 && m_retired == 6 && branch_wait_seen)
                            else $fatal(1, "boundary coverage launches=%0d responses=%0d branch_wait=%b",
                                        launches, responses, branch_wait_seen);
                        complete = 1'b1;
                        break;
                    end
                    next_pc = (next_pc == 36) ? 48 : next_pc + 4;
                end
            end
            if (complete) break;
        end
        assert (complete) else $fatal(1, "boundary program timeout");
        $display("PASS tb_core_m_boundary RV%0d cycles=%0d launches=%0d", XLEN, cycles, launches);
        $finish;
    end
endmodule
