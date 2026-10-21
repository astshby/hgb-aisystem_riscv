// Module: tb_core_predictor
// Description: Runs a branch-heavy loop and checks that trained prediction reduces redirects.
module tb_core_predictor;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_unpriv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid;
    logic [XLEN-1:0] commit_pc;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic commit_rd_we;
    logic [XLEN-1:0] commit_rd_data;
    logic commit_exception;
    logic dmem_store_fire;
    logic [XLEN-1:0] dmem_store_addr;
    logic [XLEN-1:0] dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    logic [XLEN-1:0] result_addr;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;
    integer idx;
    integer cycles;
    integer branch_count;
    integer redirect_count;
    integer loop_resolutions, late_correct;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    sim_cpu_top dut (.commit_trace(), .*);
    assign result_addr = xlen_t'(TEST_RESULT_ADDR);
    // 结果 Store 的总线所有者与退休 ID 从 TB 层级读取，不扩展 FPGA 接口。
    store_result_monitor u_result_monitor (
        .store_request_id(dut.u_core.lsu_owner_id),
        .store_response_fire(dut.u_core.dmem_rsp_valid && dut.u_core.dmem_rsp_ready &&
                             dut.u_core.lsu_owner_valid && dut.u_core.dmem_req_write),
        .store_response_error(dut.u_core.dmem_rsp_error),
        .store_response_id(dut.u_core.lsu_owner_id),
        .store_retire_fire(dut.u_core.queue_retire_fire &&
                           dut.u_core.head_meta.kind == pipeline_pkg::RET_STORE),
        .store_retire_error(dut.u_core.head_result.exc.valid),
        .store_retire_id(dut.u_core.head_id),
        .cancel(dut.u_core.wb_redirect.valid), .*
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            branch_count <= 0;
            redirect_count <= 0;
            loop_resolutions <= 0;
            late_correct <= 0;
        end else begin
            if (commit_valid && (commit_inst[6:0] == OPCODE_BRANCH))
                branch_count <= branch_count + 1;
            if (dut.u_core.selected_redirect.valid)
                redirect_count <= redirect_count + 1;
            // 退休训练比 EX 训练晚，短窗的冷启动重定向数应原样报告，不绑旧时序阈值。
            // 独立软件迭代序号决定方向：前 19 次跳回 PC8，最后一次顺序退出。
            if (dut.u_core.ex_stage_advance && dut.u_core.d2_ex_q.pc == 12) begin
                assert (dut.u_core.ex_packet.branch.taken == (loop_resolutions < 19) &&
                        dut.u_core.ex_packet.branch.target == 8)
                    else $fatal(1, "branch-loop execution differs from software iteration model");
                loop_resolutions <= loop_resolutions + 1;
                if (loop_resolutions >= 14 && loop_resolutions < 19) begin
                    assert (dut.u_core.d2_ex_q.pred.hit && dut.u_core.d2_ex_q.pred.taken &&
                            dut.u_core.d2_ex_q.pred.target == 8 && !dut.u_core.ex_redirect.valid)
                        else $fatal(1, "steady-state branch prediction did not converge iteration=%0d", loop_resolutions);
                    late_correct <= late_correct + 1;
                end
            end
        end
    end

    initial begin
        for (idx = 0; idx < 128; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();
        dut.u_imem.mem[0]  = enc_addi(5'd1, 5'd0, 0);
        dut.u_imem.mem[1]  = enc_addi(5'd2, 5'd0, 20);
        dut.u_imem.mem[2]  = enc_addi(5'd1, 5'd1, 1);
        dut.u_imem.mem[3]  = enc_blt(5'd1, 5'd2, -4);
        dut.u_imem.mem[4]  = enc_bne(5'd1, 5'd2, 24);
        dut.u_imem.mem[5]  = enc_jal(5'd3, 8);
        dut.u_imem.mem[6]  = enc_jal(5'd0, 16);
        dut.u_imem.mem[7]  = enc_lui(5'd4, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[8]  = enc_addi(5'd5, 5'd0, 1);
        dut.u_imem.mem[9]  = enc_sw(5'd5, 5'd4, 0);
        dut.u_imem.mem[10] = enc_lui(5'd4, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[11] = enc_addi(5'd5, 5'd0, 2);
        dut.u_imem.mem[12] = enc_sw(5'd5, 5'd4, 0);
        dut.u_imem.mem[13] = enc_jal(5'd0, 0);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 800; cycles = cycles + 1) begin
            @(negedge clk);
            if (commit_exception && commit_valid)
                $fatal(1, "unexpected exception at pc=%h", commit_pc);
            if (test_done) begin
                assert (test_pass) else $fatal(1, "predictor program failed code=%0d", test_code);
                assert (branch_count == 21 && loop_resolutions == 20 && late_correct == 5)
                    else $fatal(1, "branch loop or independently checked steady-state window did not execute");
                assert (redirect_count < branch_count)
                    else $fatal(1, "predictor did not converge redirects=%0d", redirect_count);
                $display("PASS tb_core_predictor branches=%0d redirects=%0d late_correct=%0d/5",
                         branch_count, redirect_count, late_correct);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "predictor program timeout");
        $finish;
    end
endmodule
