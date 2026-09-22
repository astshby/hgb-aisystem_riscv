// Module: tb_core_trap
// Description: Exercises precise synchronous traps and MRET recovery through a machine handler.
module tb_core_trap;
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
    integer exception_count;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    sim_cpu_top dut (.*);
    assign result_addr = xlen_t'(TEST_RESULT_ADDR);
    store_result_monitor u_result_monitor (.*);

    always_ff @(posedge clk) begin
        if (rst)
            exception_count <= 0;
        else if (commit_valid && commit_exception)
            exception_count <= exception_count + 1;
    end

    initial begin
        for (idx = 0; idx < 128; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();
        dut.u_imem.mem[0]  = enc_addi(5'd1, 5'd0, 16'h100);
        dut.u_imem.mem[1]  = enc_csrrw(5'd0, CSR_MTVEC, 5'd1);
        dut.u_imem.mem[2]  = enc_addi(5'd20, 5'd0, 0);
        dut.u_imem.mem[3]  = enc_addi(5'd21, 5'd0, 0);
        dut.u_imem.mem[4]  = enc_ecall();
        dut.u_imem.mem[5]  = enc_ebreak();
        dut.u_imem.mem[6]  = 32'hffff_ffff;
        dut.u_imem.mem[7]  = enc_csrrw(5'd0, CSR_MISA, 5'd0);
        dut.u_imem.mem[8]  = enc_lw(5'd2, 5'd0, 1);
        dut.u_imem.mem[9]  = enc_sw(5'd0, 5'd0, 2);
        dut.u_imem.mem[10] = enc_jal(5'd0, 2);
        dut.u_imem.mem[11] = enc_addi(5'd22, 5'd0, 7);
        dut.u_imem.mem[12] = enc_bne(5'd20, 5'd22, 28);
        dut.u_imem.mem[13] = enc_addi(5'd22, 5'd0, 28);
        dut.u_imem.mem[14] = enc_bne(5'd21, 5'd22, 20);
        dut.u_imem.mem[15] = enc_lui(5'd23, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[16] = enc_addi(5'd24, 5'd0, 1);
        dut.u_imem.mem[17] = enc_sw(5'd24, 5'd23, 0);
        dut.u_imem.mem[18] = enc_jal(5'd0, 0);
        dut.u_imem.mem[19] = enc_lui(5'd23, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[20] = enc_addi(5'd24, 5'd0, 2);
        dut.u_imem.mem[21] = enc_sw(5'd24, 5'd23, 0);
        dut.u_imem.mem[22] = enc_jal(5'd0, 0);

        dut.u_imem.mem[64] = enc_csrrs(5'd10, CSR_MCAUSE, 5'd0);
        dut.u_imem.mem[65] = enc_add(5'd21, 5'd21, 5'd10);
        dut.u_imem.mem[66] = enc_csrrs(5'd11, CSR_MEPC, 5'd0);
        dut.u_imem.mem[67] = enc_addi(5'd11, 5'd11, 4);
        dut.u_imem.mem[68] = enc_csrrw(5'd0, CSR_MEPC, 5'd11);
        dut.u_imem.mem[69] = enc_addi(5'd20, 5'd20, 1);
        dut.u_imem.mem[70] = enc_mret();

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 1600; cycles = cycles + 1) begin
            // 下降沿采样，避开 DUT 在上升沿通过非阻塞赋值更新状态的调度竞争。
            @(negedge clk);
            if (test_done) begin
                assert (test_pass) else $fatal(1, "trap program failed code=%0d", test_code);
                assert (exception_count == 7)
                    else $fatal(1, "expected seven committed exceptions, got %0d", exception_count);
                $display("PASS tb_core_trap RV%0d exceptions=%0d cycles=%0d",
                         XLEN, exception_count, cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "trap directed program timeout exceptions=%0d", exception_count);
        $finish;
    end
endmodule
