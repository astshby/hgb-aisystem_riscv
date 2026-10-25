// Module: tb_core_load_pipeline
// Description: Checks load data/dependencies, dual retirement and legacy single-issue load timing.
module tb_core_load_pipeline;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
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
    integer first_load_cycle;
    integer second_load_cycle;
    logic dependent_source_seen = 0;
    logic dual_retired_seen = 0;
`ifdef CORE_SCOREBOARD
    always @(posedge clk) if (!rst) begin
        if (commit_trace[0].valid && commit_trace[1].valid) dual_retired_seen = 1;
        for (int lane = 0; lane < 2; lane++)
            if (dut.u_core.issue_fire[lane] && dut.u_core.scheduled[lane].pc == xlen_t'(16)) begin
                assert (dut.u_core.scheduled[lane].rs1_data == xlen_t'(50))
                    else $fatal(1, "dependent ALU issued before capturing its Load value");
                dependent_source_seen = 1;
            end
    end
`endif

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    pipeline_pkg::retire_trace_t commit_trace [2], sampled_trace [2];
    sim_cpu_top dut (.*);
    // 上升沿记录本拍真实退休，下降沿按年龄遍历两个端口。
    always_ff @(posedge clk) begin
        if (rst) begin sampled_trace[0] <= '0; sampled_trace[1] <= '0; end
        else sampled_trace <= commit_trace;
    end
    assign result_addr = xlen_t'(TEST_RESULT_ADDR);
    // 结果 Store 的总线所有者与退休 ID 从 TB 层级读取，不扩展 FPGA 接口。
    store_result_monitor u_result_monitor (
`ifdef CORE_SCOREBOARD
        .store_request_id(dut.u_core.store_request_id),
        .store_response_fire(dut.u_core.store_response_fire),
        .store_response_error(dut.u_core.store_response_error),
        .store_response_id(dut.u_core.store_response_id),
`else
        .store_request_id(dut.u_core.lsu_owner_id),
        .store_response_fire(dut.u_core.dmem_rsp_valid && dut.u_core.dmem_rsp_ready &&
                             dut.u_core.lsu_owner_valid && dut.u_core.dmem_req_write),
        .store_response_error(dut.u_core.dmem_rsp_error),
        .store_response_id(dut.u_core.lsu_owner_id),
`endif
        .store_retire_fire(dut.u_core.queue_retire_fire &&
                           dut.u_core.head_meta.kind == pipeline_pkg::RET_STORE),
        .store_retire_error(dut.u_core.head_result.exc.valid),
        .store_retire_id(dut.u_core.head_id),
        .cancel(dut.u_core.wb_redirect.valid), .*
    );

    initial begin
        for (idx = 0; idx < 64; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();

        // 前三条验证 load 后无关指令连续流动；第二个 load 紧跟真实消费者。
        dut.u_imem.mem[0]  = enc_lw(5'd1, 5'd0, 0);
        dut.u_imem.mem[1]  = enc_addi(5'd2, 5'd0, 7);
        dut.u_imem.mem[2]  = enc_addi(5'd3, 5'd0, 8);
        dut.u_imem.mem[3]  = enc_lw(5'd4, 5'd0, 4);
        dut.u_imem.mem[4]  = enc_addi(5'd5, 5'd4, 1);
        dut.u_imem.mem[5]  = enc_addi(5'd6, 5'd0, 9);
        dut.u_imem.mem[6]  = enc_addi(5'd7, 5'd0, 41);
        dut.u_imem.mem[7]  = enc_bne(5'd1, 5'd7, 28);
        dut.u_imem.mem[8]  = enc_addi(5'd8, 5'd0, 51);
        dut.u_imem.mem[9]  = enc_bne(5'd5, 5'd8, 20);
        dut.u_imem.mem[10] = enc_lui(5'd11, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[11] = enc_addi(5'd12, 5'd0, 1);
        dut.u_imem.mem[12] = enc_sw(5'd12, 5'd11, 0);
        dut.u_imem.mem[13] = enc_jal(5'd0, 0);
        dut.u_imem.mem[14] = enc_lui(5'd11, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[15] = enc_addi(5'd12, 5'd0, 2);
        dut.u_imem.mem[16] = enc_sw(5'd12, 5'd11, 0);
        dut.u_imem.mem[17] = enc_jal(5'd0, 0);

        if (XLEN == 64)
            dut.u_dmem.mem[0] = xlen_t'(64'h0000_0032_0000_0029);
        else begin
            dut.u_dmem.mem[0] = xlen_t'(41);
            dut.u_dmem.mem[1] = xlen_t'(50);
        end
        first_load_cycle = -1;
        second_load_cycle = -1;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
            @(negedge clk);
            for (int lane = 0; lane < 2; lane++) begin
                if (sampled_trace[lane].exception && sampled_trace[lane].valid)
                    $fatal(1, "unexpected exception at pc=%h", sampled_trace[lane].pc);
                if (sampled_trace[lane].valid) begin
                    unique case (sampled_trace[lane].pc)
                        xlen_t'(0): begin
                            first_load_cycle = cycles;
                            assert (sampled_trace[lane].rd_data == xlen_t'(41))
                                else $fatal(1, "first load data");
                        end
                        xlen_t'(4): begin
`ifndef CORE_SCOREBOARD
                            assert (cycles == first_load_cycle + 1)
                                else $fatal(1, "independent instruction stalled after load");
`endif
                        end
                        xlen_t'(8): begin
`ifndef CORE_SCOREBOARD
                            assert (cycles == first_load_cycle + 2)
                                else $fatal(1, "load hit did not sustain one instruction per cycle");
`endif
                        end
                        xlen_t'(12): second_load_cycle = cycles;
                        xlen_t'(16): begin
`ifndef CORE_SCOREBOARD
                            assert (cycles == second_load_cycle + 2)
                                else $fatal(1, "load-use must insert exactly one bubble");
`endif
                            assert (sampled_trace[lane].rd_data == xlen_t'(51))
                                else $fatal(1, "load-use WB forwarding data");
                        end
                        default: ;
                    endcase
                end
            end
            if (test_done) begin
`ifdef CORE_SCOREBOARD
                assert (dependent_source_seen && dual_retired_seen && first_load_cycle >= 0 && second_load_cycle >= 0)
                    else $fatal(1, "missing dual-retirement/Load dependency coverage");
`endif
                assert (test_pass) else $fatal(1, "load pipeline program failed code=%0d", test_code);
                $display("PASS tb_core_load_pipeline cycles=%0d", cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "load pipeline timeout");
        $finish;
    end
endmodule
