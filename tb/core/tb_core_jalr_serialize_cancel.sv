// Module: tb_core_jalr_serialize_cancel
// Description: Checks that an older JALR redirect cancels a wrong-path serialization request.
module tb_core_jalr_serialize_cancel;
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

    sim_cpu_top dut (.*);
    store_result_monitor u_result_monitor (.*);

    initial begin
        for (idx = 0; idx < 4096; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();

        dut.u_imem.mem[0] = enc_addi(5'd5, 5'd0, 32);
        dut.u_imem.mem[1] = enc_jalr(5'd1, 5'd5, 0);
        dut.u_imem.mem[2] = enc_addi(5'd3, 5'd0, 1);
        dut.u_imem.mem[3] = enc_sw(5'd3, 5'd0, 0);

        // 短叶子函数返回时，后面的非法填充属于必须被清除的年轻路径。
        dut.u_imem.mem[8] = enc_addi(5'd10, 5'd0, 0);
        dut.u_imem.mem[9] = enc_jalr(5'd0, 5'd1, 0);
        dut.u_imem.mem[10] = 32'h0000_0000;

        result_addr = '0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
            @(negedge clk);
            if (test_done) begin
                assert (test_pass)
                    else $fatal(1, "wrong result after JALR serialization cancellation");
                $display("PASS tb_core_jalr_serialize_cancel RV%0d cycles=%0d",
                         XLEN, cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "JALR serialization cancellation timeout");
        $finish;
    end

    logic unused_commit;
    assign unused_commit = ^{commit_valid, commit_pc, commit_inst, commit_rd,
                             commit_rd_we, commit_rd_data, commit_exception,
                             test_code};
endmodule
