// Module: tb_core_branch_serialize_cancel
// Description: Checks that an older Branch redirect cancels wrong-path serialization.
module tb_core_branch_serialize_cancel;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
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
    xlen_t result_addr;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;
    integer idx;
    integer cycles;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;

    sim_cpu_top dut (.commit_trace(), .*);
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
        for (idx = 0; idx < 4096; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();

        dut.u_imem.mem[0] = enc_addi(5'd1, 5'd0, 1);
        dut.u_imem.mem[1] = enc_beq(5'd1, 5'd1, 28);
        dut.u_imem.mem[2] = 32'h0000_0000;

        // Taken Branch 必须取消顺序错误路径上已经登记的非法指令序列化。
        dut.u_imem.mem[8] = enc_addi(5'd3, 5'd0, 1);
        dut.u_imem.mem[9] = enc_sw(5'd3, 5'd0, 0);

        result_addr = '0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
            @(negedge clk);
            if (test_done) begin
                assert (test_pass)
                    else $fatal(1, "wrong result after Branch serialization cancellation");
                $display("PASS tb_core_branch_serialize_cancel RV%0d cycles=%0d",
                         XLEN, cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "Branch serialization cancellation timeout");
        $finish;
    end

    logic unused_commit;
    assign unused_commit = ^{commit_valid, commit_pc, commit_inst, commit_rd,
                             commit_rd_we, commit_rd_data, commit_exception,
                             test_code};
endmodule
