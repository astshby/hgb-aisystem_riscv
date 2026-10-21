// Module: tb_commit_control
// Description: Exhaustively checks head retirement permissions and canonical results for both XLENs.
module tb_commit_control;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic retire_fire;
    retire_alloc_t head_meta;
    retire_result_t head_result;
    gpr_forward_t gpr_write;
    csr_forward_t csr_write;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;
    int checked_cases = 0;

    always #5 clk = ~clk;
    commit_control dut (.*);

    // 组合模块同样在下降沿驱动，待组合稳定后检查，避免与整核复用时混入竞争。
    // valid=0 同时覆盖气泡和尚未完成的包；异常包仍有 trace，但无架构写入。
    initial begin
        retire_fire = 1'b0;
        head_meta = '0;
        head_result = '0;
        for (int flags = 0; flags < 32; flags++) begin
            for (int selection = 0; selection < 5; selection++) begin
                xlen_t expected_data;
                logic expected_gpr_write;
                logic expected_csr_write;
                @(negedge clk);
                head_meta = '0;
                head_result = '0;
                retire_fire = flags[0];
                head_result.exc.valid = flags[1];
                head_result.exc.cause = EXC_LOAD_ACCESS_FAULT;
                head_meta.gpr_write = flags[2];
                head_result.csr_write = flags[3];
                head_meta.rd = flags[4] ? gpr_addr_t'(31) : '0;
                head_meta.pc = xlen_t'(64'h8000_0000_8000_0010);
                head_meta.inst = 32'h0010_0093;
                head_meta.seq_pc = xlen_t'(64'h8000_0000_8000_0014);
                head_meta.csr_addr = csr_addr_t'(CSR_MSCRATCH);
                head_result.csr_data = xlen_t'(64'hbeef_dead_1357_2468);

                // 保留原五类数据与资格交叉覆盖；实际写回 mux 已迁至 tb_wb_stage 验证。
                // 异常和 x0 只屏蔽写使能，不改变已规范化的完成数据。
                case (wb_sel_e'(selection))
                    WB_LOAD:   expected_data = xlen_t'(64'h8765_4321_1122_3344);
                    WB_SEQ_PC: expected_data = head_meta.seq_pc;
                    WB_CSR:    expected_data = xlen_t'(64'h1234_5678_90ab_cdef);
                    default:   expected_data = xlen_t'(64'hfedc_ba98_7654_3210);
                endcase
                head_result.gpr_data = expected_data;
                expected_gpr_write = flags[0] && !flags[1] && flags[2] && flags[4];
                expected_csr_write = flags[0] && !flags[1] && flags[3];
                #1;
                assert (commit_valid == flags[0] &&
                        commit_exception == (flags[0] && flags[1]))
                    else $fatal(1, "commit event qualification flags=%0d selection=%0d", flags, selection);
                assert (gpr_write.valid == expected_gpr_write &&
                        gpr_write.addr == head_meta.rd && gpr_write.data == expected_data &&
                        commit_rd_we == expected_gpr_write && commit_rd_data == expected_data)
                    else $fatal(1, "GPR commit flags=%0d selection=%0d", flags, selection);
                assert (csr_write.valid == expected_csr_write &&
                        csr_write.addr == csr_addr_t'(CSR_MSCRATCH) && csr_write.data == head_result.csr_data)
                    else $fatal(1, "CSR commit flags=%0d selection=%0d", flags, selection);
                assert (commit_pc == head_meta.pc && commit_inst == head_meta.inst &&
                        commit_rd == head_meta.rd)
                    else $fatal(1, "commit metadata flags=%0d selection=%0d", flags, selection);
                checked_cases++;
            end
        end
        $display("PASS tb_commit_control XLEN=%0d cases=%0d", XLEN, checked_cases);
        $finish;
    end
endmodule
