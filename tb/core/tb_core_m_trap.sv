// Module: tb_core_m_trap
// Description: Checks younger ECALL/EBREAK serialization, older M retirement, and MRET resumption.
module tb_core_m_trap;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;
    logic dmem_store_fire;
    xlen_t dmem_store_addr;
    xlen_t dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    int traps = 0;
    logic div_retired = 1'b0;
    logic mul_retired = 1'b0;
    logic young_exception_waited = 1'b0;
    logic completed = 1'b0;
    logic m_live [RETIRE_ENTRIES];
    logic m_complete [RETIRE_ENTRIES];
    retire_id_t m_id [RETIRE_ENTRIES];
    xlen_t m_pc [RETIRE_ENTRIES];
    int m_launches = 0, m_completions = 0, m_retirements = 0, mrets = 0, m_cancellations = 0;

    always #5 clk = ~clk;
    pipeline_pkg::retire_trace_t commit_trace [2], sampled_trace [2];
    sim_cpu_top dut (.*);
    // 上升沿记录本拍真实退休，下降沿按年龄遍历两个端口。
    always_ff @(posedge clk) begin
        if (rst) begin sampled_trace[0] <= '0; sampled_trace[1] <= '0; end
        else sampled_trace <= commit_trace;
    end

    // 同步异常可以先暂停前端，真正 trap 只能在老 M 的完整 ID 完成并退休后提交。
    always @(posedge clk) begin
        if (rst) begin
            m_launches = 0;
            m_completions = 0;
            m_retirements = 0;
            mrets = 0;
            m_cancellations = 0;
            for (int i = 0; i < RETIRE_ENTRIES; i++) begin
                m_live[i] = 1'b0;
                m_complete[i] = 1'b0;
                m_id[i] = '0;
                m_pc[i] = '0;
            end
        end else begin
            if (dut.u_core.mdu_req_valid && dut.u_core.mdu_req_ready) begin
                assert (!m_live[dut.observed_mdu_packet.retire_id.slot] &&
                        dut.observed_mdu_packet.pc inside {xlen_t'(16), xlen_t'(24), xlen_t'(32)})
                    else $fatal(1, "unexpected/repeated trap-test MDU request");
                m_live[dut.observed_mdu_packet.retire_id.slot] = 1'b1;
                m_complete[dut.observed_mdu_packet.retire_id.slot] = 1'b0;
                m_id[dut.observed_mdu_packet.retire_id.slot] = dut.observed_mdu_packet.retire_id;
                m_pc[dut.observed_mdu_packet.retire_id.slot] = dut.observed_mdu_packet.pc;
                m_launches++;
            end
            if (dut.observed_mdu_complete_valid && dut.observed_mdu_complete_ready) begin
                assert (m_live[dut.observed_mdu_completion.id.slot] &&
                        !m_complete[dut.observed_mdu_completion.id.slot] &&
                        m_id[dut.observed_mdu_completion.id.slot] == dut.observed_mdu_completion.id &&
                        !dut.observed_mdu_completion.result.exc.valid)
                    else $fatal(1, "stale or repeated trap-test MDU completion");
                m_complete[dut.observed_mdu_completion.id.slot] = 1'b1;
                m_completions++;
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (commit_trace[lane].valid && commit_trace[lane].inst[31:25] == 7'b0000001 &&
                    commit_trace[lane].inst[6:0] inside {7'h33, 7'h3b}) begin
                    assert (m_live[commit_trace[lane].id.slot] && m_complete[commit_trace[lane].id.slot] &&
                            m_id[commit_trace[lane].id.slot] == commit_trace[lane].id &&
                            m_pc[commit_trace[lane].id.slot] == commit_trace[lane].pc)
                        else $fatal(1, "trap-test MDU retired without its completion");
                    m_live[commit_trace[lane].id.slot] = 1'b0;
                    m_retirements++;
                end
                if (commit_trace[lane].valid && commit_trace[lane].pc == xlen_t'(144)) begin
                    assert (!commit_trace[lane].exception && m_retirements == mrets + 1)
                        else $fatal(1, "MRET crossed older MDU work");
                    mrets++;
                end
            end
            // scoreboard 可在较老异常退休前执行年轻 M；重定向取消这些完整 ID，随后可重新发射。
            if (dut.u_core.wb_redirect.valid)
                for (int slot = 0; slot < RETIRE_ENTRIES; slot++)
                    if (m_live[slot]) begin
                        m_live[slot] = 0;
                        m_cancellations++;
                    end
        end
    end

    initial begin
        for (int idx = 0; idx < 64; idx++) dut.u_imem.mem[idx] = nop();
        dut.u_imem.mem[0] = enc_addi(1, 0, 128);
        dut.u_imem.mem[1] = enc_csrrw(0, CSR_MTVEC, 1);
        dut.u_imem.mem[2] = enc_addi(2, 0, -21);
        dut.u_imem.mem[3] = enc_addi(3, 0, 3);
        dut.u_imem.mem[4] = enc_div(4, 2, 3);
        dut.u_imem.mem[5] = enc_ecall();
        dut.u_imem.mem[6] = enc_mul(5, 4, 3);
        dut.u_imem.mem[7] = enc_ebreak();
        dut.u_imem.mem[8] = enc_rem(6, 5, 3);
        dut.u_imem.mem[9] = enc_addi(7, 0, 1);
        dut.u_imem.mem[10] = enc_jal(0, 0);
        dut.u_imem.mem[32] = enc_csrrs(8, CSR_MCAUSE, 0);
        dut.u_imem.mem[33] = enc_csrrs(9, CSR_MEPC, 0);
        dut.u_imem.mem[34] = enc_addi(9, 9, 4);
        dut.u_imem.mem[35] = enc_csrrw(0, CSR_MEPC, 9);
        dut.u_imem.mem[36] = enc_mret();
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (int cycles = 0; cycles < 1000; cycles++) begin
            @(negedge clk);
            assert (!dmem_store_fire) else $fatal(1, "unexpected trap test Store");
            for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
                if (m_live[slot] && dut.observed_serial_pending) young_exception_waited = 1'b1;
                for (int lane = 0; lane < 2; lane++)
                    if (commit_trace[lane].valid && commit_trace[lane].exception && m_live[slot])
                        assert (!((commit_trace[lane].pc == xlen_t'(20) && m_pc[slot] == xlen_t'(16)) ||
                                  (commit_trace[lane].pc == xlen_t'(28) && m_pc[slot] == xlen_t'(24))))
                            else $fatal(1, "younger exception before its older MDU retired");
            end
            for (int lane = 0; lane < 2; lane++) begin
                if (sampled_trace[lane].valid) begin
                    unique case (sampled_trace[lane].pc)
                        xlen_t'(16): begin
                            assert (!sampled_trace[lane].exception && sampled_trace[lane].rd_we && sampled_trace[lane].rd_data == xlen_t'(-7))
                                else $fatal(1, "older DIV result");
                            div_retired = 1'b1;
                        end
                        xlen_t'(20): begin
                            assert (div_retired && sampled_trace[lane].exception && traps == 0)
                                else $fatal(1, "ECALL before older DIV or repeated trap");
                            traps++;
                        end
                        xlen_t'(24): begin
                            assert (!sampled_trace[lane].exception && sampled_trace[lane].rd_we && sampled_trace[lane].rd_data == xlen_t'(-21))
                                else $fatal(1, "MUL did not resume after MRET");
                            mul_retired = 1'b1;
                        end
                        xlen_t'(28): begin
                            assert (mul_retired && sampled_trace[lane].exception && traps == 1)
                                else $fatal(1, "EBREAK before older MUL");
                            traps++;
                        end
                        xlen_t'(32): assert (!sampled_trace[lane].exception && sampled_trace[lane].rd_we && sampled_trace[lane].rd_data == '0)
                            else $fatal(1, "REM after second MRET");
                        xlen_t'(128): assert (sampled_trace[lane].rd_we && sampled_trace[lane].rd_data ==
                            ((traps == 1) ? xlen_t'(EXC_ECALL_M) : xlen_t'(EXC_BREAKPOINT)))
                            else $fatal(1, "M trap MCAUSE");
                        xlen_t'(132): assert (sampled_trace[lane].rd_we && sampled_trace[lane].rd_data ==
                            ((traps == 1) ? xlen_t'(20) : xlen_t'(28)))
                            else $fatal(1, "M trap MEPC");
                        xlen_t'(36): begin
                            assert (traps == 2 && div_retired && mul_retired && young_exception_waited &&
                                    m_retirements == 3 && m_launches == m_retirements + m_cancellations &&
                                    m_completions >= m_retirements && m_completions <= m_launches && mrets == 2)
                                else $fatal(1, "M trap coverage incomplete");
                            $display("PASS tb_core_m_trap RV%0d traps=%0d cycles=%0d launched=%0d completed=%0d retired=%0d cancelled=%0d",
                                     XLEN, traps, cycles, m_launches, m_completions, m_retirements, m_cancellations);
                            completed = 1'b1;
                        end
                        default: assert (!sampled_trace[lane].exception) else $fatal(1, "unexpected M trap pc=%h", sampled_trace[lane].pc);
                    endcase
                    if (completed) break;
                end
            end
            if (completed) break;
        end
        assert (completed) else $fatal(1, "M trap program timeout");
        $finish;
    end
endmodule
