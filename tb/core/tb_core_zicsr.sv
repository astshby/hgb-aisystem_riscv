// Module: tb_core_zicsr
// Description: Runs dependent register and immediate Zicsr operations through the full pipeline.
module tb_core_zicsr;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;
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

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    sim_cpu_top dut (.*);
    assign result_addr = xlen_t'(TEST_RESULT_ADDR);
    store_result_monitor u_result_monitor (.*);

    initial begin
        for (idx = 0; idx < 128; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();
        dut.u_imem.mem[0]  = enc_addi(5'd1, 5'd0, 16'h55);
        dut.u_imem.mem[1]  = enc_csrrw(5'd2, CSR_MSCRATCH, 5'd1);
        dut.u_imem.mem[2]  = enc_csrrs(5'd3, CSR_MSCRATCH, 5'd1);
        dut.u_imem.mem[3]  = enc_addi(5'd4, 5'd0, 16'h0f);
        dut.u_imem.mem[4]  = enc_csrrc(5'd5, CSR_MSCRATCH, 5'd4);
        dut.u_imem.mem[5]  = enc_csrrs(5'd6, CSR_MSCRATCH, 5'd0);
        dut.u_imem.mem[6]  = enc_addi(5'd7, 5'd0, 16'h50);
        dut.u_imem.mem[7]  = enc_bne(5'd6, 5'd7, 76);
        dut.u_imem.mem[8]  = enc_csrrwi(5'd8, CSR_MSCRATCH, 5'd3);
        dut.u_imem.mem[9]  = enc_csrrsi(5'd9, CSR_MSCRATCH, 5'd4);
        dut.u_imem.mem[10] = enc_csrrci(5'd10, CSR_MSCRATCH, 5'd1);
        dut.u_imem.mem[11] = enc_csrrs(5'd11, CSR_MSCRATCH, 5'd0);
        dut.u_imem.mem[12] = enc_addi(5'd12, 5'd0, 6);
        dut.u_imem.mem[13] = enc_bne(5'd11, 5'd12, 52);
        dut.u_imem.mem[14] = enc_addi(5'd12, 5'd0, 16'h50);
        dut.u_imem.mem[15] = enc_bne(5'd8, 5'd12, 44);
        dut.u_imem.mem[16] = enc_addi(5'd12, 5'd0, 3);
        dut.u_imem.mem[17] = enc_bne(5'd9, 5'd12, 36);
        dut.u_imem.mem[18] = enc_addi(5'd12, 5'd0, 7);
        dut.u_imem.mem[19] = enc_bne(5'd10, 5'd12, 28);
        dut.u_imem.mem[20] = enc_csrrs(5'd13, CSR_MCYCLE, 5'd0);
        dut.u_imem.mem[21] = enc_beq(5'd13, 5'd0, 20);
        dut.u_imem.mem[22] = enc_lui(5'd14, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[23] = enc_addi(5'd15, 5'd0, 1);
        dut.u_imem.mem[24] = enc_sw(5'd15, 5'd14, 0);
        dut.u_imem.mem[25] = enc_jal(5'd0, 0);
        dut.u_imem.mem[26] = enc_lui(5'd14, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[27] = enc_addi(5'd15, 5'd0, 2);
        dut.u_imem.mem[28] = enc_sw(5'd15, 5'd14, 0);
        dut.u_imem.mem[29] = enc_jal(5'd0, 0);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 800; cycles = cycles + 1) begin
            // 下降沿采样，避开 DUT 在上升沿更新提交状态的调度竞争。
            @(negedge clk);
            if (commit_valid && commit_exception)
                $fatal(1, "unexpected exception at pc=%h inst=%h", commit_pc, commit_inst);
            if (test_done) begin
                assert (test_pass) else $fatal(1, "Zicsr program failed code=%0d", test_code);
                $display("PASS tb_core_zicsr RV%0d cycles=%0d", XLEN, cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "Zicsr directed program timeout");
        $finish;
    end
endmodule
