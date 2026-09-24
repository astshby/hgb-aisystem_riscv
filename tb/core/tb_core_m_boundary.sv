// Module: tb_core_m_boundary
// Description: Checks request-edge metadata, MEM result joining, dependent uses, and younger redirects.
module tb_core_m_boundary;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
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
    logic launch_q, consume_q, single_cycle_q;
    logic branch_wait_seen = 1'b0;
    xlen_t launch_pc_q, consume_pc_q, consume_data_q;
    xlen_t expected [20];
    logic complete = 1'b0;

    always #5 clk = ~clk;
    sim_cpu_top dut (.*);

    // 上升沿记录真实握手，下降沿检查对应寄存器，不依赖仿真事件队列先后顺序。
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            launches <= 0;
            responses <= 0;
            launch_q <= 1'b0;
            consume_q <= 1'b0;
            single_cycle_q <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            launch_q <= dut.u_core.u_ex_stage.u_ex_mdu.req_fire;
            consume_q <= dut.u_core.mdu_rsp_valid && dut.u_core.mdu_rsp_ready;
            if (dut.u_core.u_ex_stage.u_ex_mdu.req_fire) begin
                launches <= launches + 1;
                launch_pc_q <= dut.u_core.d2_ex_q.pc;
                // PC=48 是除零，所有后端都在请求沿寄存特殊结果。
                single_cycle_q <= (dut.u_core.d2_ex_q.pc == xlen_t'(48)) ||
                    ((MUL_IMPL == MUL_DSP) && dut.u_core.d2_ex_q.uop.muldiv_op == MD_MUL);
                assert (dut.u_core.ex_stage_advance)
                    else $fatal(1, "boundary test unexpectedly blocked metadata");
            end
            if (dut.u_core.mdu_rsp_valid && dut.u_core.mdu_rsp_ready) begin
                responses <= responses + 1;
                consume_pc_q <= dut.u_core.ex_mem_q.pc;
                consume_data_q <= dut.u_core.mdu_rsp_data;
            end
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
                assert (dut.u_core.ex_mem_q.valid && dut.u_core.ex_mem_q.pc == launch_pc_q)
                    else $fatal(1, "M metadata did not enter MEM on request edge");
                if (single_cycle_q)
                    assert (dut.u_core.mem_input_packet.valid && dut.u_core.mdu_rsp_valid)
                        else $fatal(1, "single-cycle M result gained an extra transfer cycle");
            end
            if (consume_q)
                assert (dut.u_core.mem_wb_q.valid && dut.u_core.mem_wb_q.pc == consume_pc_q &&
                        dut.u_core.mem_wb_q.result == consume_data_q)
                    else $fatal(1, "M response not paired with its WB metadata");
            if (dut.u_core.mem_result_stall && dut.u_core.ex_redirect.valid) begin
                branch_wait_seen = 1'b1;
                assert (!dut.u_core.selected_redirect.valid)
                    else $fatal(1, "younger EX branch overtook MEM M result");
            end
            if (commit_valid) begin
                assert (!commit_exception && commit_pc == xlen_t'(next_pc) &&
                        commit_inst == dut.u_imem.mem[next_pc / 4])
                    else $fatal(1, "boundary retirement pc=%h expected=%0d", commit_pc, next_pc);
                if (next_pc < 8 || (next_pc >= 24 && next_pc != 36))
                    assert (commit_rd_we && commit_rd_data == expected[next_pc / 4])
                        else $fatal(1, "boundary data pc=%h got=%h expected=%h", commit_pc,
                                    commit_rd_data, expected[next_pc / 4]);
                retired++;
                if (next_pc == 64) begin
                    assert (launches == 6 && responses == 6 && branch_wait_seen)
                        else $fatal(1, "boundary coverage launches=%0d responses=%0d branch_wait=%b",
                                    launches, responses, branch_wait_seen);
                    complete = 1'b1;
                    break;
                end
                next_pc = (next_pc == 36) ? 48 : next_pc + 4;
            end
        end
        assert (complete) else $fatal(1, "boundary program timeout");
        $display("PASS tb_core_m_boundary RV%0d cycles=%0d launches=%0d", XLEN, cycles, launches);
        $finish;
    end
endmodule
