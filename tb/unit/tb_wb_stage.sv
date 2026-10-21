// Module: tb_wb_stage
// Description: Checks ordinary WB selection, precise early exceptions and completion metadata.
module tb_wb_stage;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    mem_wb_t in_packet;
    retire_completion_t completion, held_completion;
    logic completion_valid, completion_ready;
    retire_alloc_t head_meta;
    gpr_forward_t gpr_write;
    csr_forward_t csr_write;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    int checks = 0;
    wb_stage dut (.*);

    // 保留原 WB 写口/trace 检查，由独立提交模块观察规范完成包；年龄在整核 TB 检查。
    // 原响应登记、lane 扩展、总线错误、协调复位和反压属性迁至 tb_lsu_transaction。
    always_comb begin
        head_meta = '0;
        head_meta.pc = in_packet.pc;
        head_meta.seq_pc = in_packet.seq_pc;
        head_meta.inst = in_packet.inst;
        head_meta.rd = in_packet.rd;
        head_meta.gpr_write = in_packet.uop.gpr_write;
        head_meta.csr_addr = in_packet.csr_addr;
        head_meta.sys_op = in_packet.uop.sys_op;
    end
    commit_control u_commit_control (
        .retire_fire(completion_valid && completion_ready), .head_meta, .head_result(completion.result),
        .gpr_write, .csr_write, .commit_valid, .commit_pc, .commit_inst,
        .commit_rd, .commit_rd_we, .commit_rd_data, .commit_exception
    );

    initial begin
        in_packet = '0;
        completion_ready = 1;
        // 穷举有效位、异常、GPR/CSR 写资格及 x0，保留架构副作用门控的独立真值表。
        for (int bits = 0; bits < 32; bits++) begin
            in_packet = '0;
            in_packet.valid = bits[0];
            in_packet.exc = '{valid:bits[1], cause:EXC_LOAD_ADDR_MISALIGNED, tval:xlen_t'(3)};
            in_packet.uop.gpr_write = bits[2];
            in_packet.csr_we = bits[3];
            in_packet.rd = bits[4] ? gpr_addr_t'(1) : '0;
            in_packet.pc = xlen_t'(64'h8000_0000_0000_0040);
            in_packet.inst = 32'h12345678;
            in_packet.csr_addr = CSR_MSCRATCH;
            in_packet.csr_new = xlen_t'(32'h1234);
            #1;
            assert (completion_valid == bits[0] && commit_valid == bits[0] &&
                    commit_exception == (bits[0] && bits[1]) &&
                    csr_write.valid == (bits[0] && !bits[1] && bits[3]) &&
                    gpr_write.valid == (bits[0] && !bits[1] && bits[2] && bits[4]) &&
                    completion.result.exc == in_packet.exc &&
                    (!commit_valid || (commit_pc == in_packet.pc && commit_inst == in_packet.inst)))
                else $fatal(1, "ordinary WB truth table %0d", bits);
            checks++;
        end

        // 写回选择仍逐类检查高位、链接地址和 CSR 旧值，ID 不得串包。
        for (int selection = 0; selection < 5; selection++) begin
            xlen_t expected;
            in_packet = '0;
            in_packet.valid = 1;
            in_packet.retire_id = retire_id_t'(selection + 1);
            in_packet.rd = 7;
            in_packet.uop.gpr_write = 1;
            in_packet.uop.wb_sel = wb_sel_e'(selection);
            in_packet.result = xlen_t'(64'hfedc_ba98_7654_3210);
            in_packet.seq_pc = xlen_t'(64'h8000_0000_8000_0014);
            in_packet.next_pc = xlen_t'(64'h8000_0000_8000_0040);
            // 不依赖 next_pc 反推分支方向，完成包必须保留 EX 提供的完整实际结果。
            in_packet.branch = '{taken:selection[0], target:xlen_t'(64'hfedc_ba98_8000_0080) + xlen_t'(selection * 4)};
            in_packet.csr_old = xlen_t'(64'h1234_5678_90ab_cdef);
            case (wb_sel_e'(selection))
                WB_LOAD: begin
                    // 正常 Load 不再到 WB；早期异常无需响应且不能写架构 GPR。
                    in_packet.exc.valid = 1;
                    expected = '0;
                end
                WB_SEQ_PC: expected = in_packet.seq_pc;
                WB_CSR: expected = in_packet.csr_old;
                default: expected = in_packet.result;
            endcase
            #1;
            assert (completion_valid && completion.id == in_packet.retire_id &&
                    completion.result.next_pc == in_packet.next_pc &&
                    completion.result.branch == in_packet.branch &&
                    completion.result.gpr_data == expected)
                else $fatal(1, "WB canonical result selection=%0d", selection);
            completion_ready = 0;
            held_completion = completion;
            repeat (3) begin
                #10;
                assert (completion_valid && completion == held_completion && !commit_valid)
                    else $fatal(1, "WB source metadata changed during completion backpressure");
            end
            completion_ready = 1;
            #1;
            assert (commit_valid && commit_exception == in_packet.exc.valid)
                else $fatal(1, "WB added an extra result stage");
            in_packet = '0;
            #1;
            assert (!completion_valid && !commit_valid) else $fatal(1, "empty WB owns a completion");
            checks++;
        end
        $display("PASS tb_wb_stage RV%0d truth_cases=32 selections=5 hold_checks=15 checks=%0d", XLEN, checks);
        $finish;
    end
endmodule
