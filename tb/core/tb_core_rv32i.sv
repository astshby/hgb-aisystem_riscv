// Module: tb_core_rv32i
// Description: Runs a directed RV32I program covering RAW, load-use, branch, JAL, and JALR.
module tb_core_rv32i;
    // 显式时间声明避免 #5 依赖仿真器默认值；老式等价写法为 `timescale 1ns/1ps。
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

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;

    // dut:device under test:待测试设备，使用sim_top模块实例化，
    // .*表示端口自动连接(也就是把sim_cpu_top存在端口与tb定义的端口对应连接)
    sim_cpu_top dut (.*);
    assign result_addr = xlen_t'(TEST_RESULT_ADDR);
    store_result_monitor u_result_monitor (.*);

    initial begin
        if (XLEN != 32) begin
            $display("PASS tb_core_rv32i SKIP RV%0d", XLEN);
            $finish;
        end
        for (idx = 0; idx < 128; idx = idx + 1)
            dut.u_imem.mem[idx] = nop();
        // 进行多方面冒险测试
        dut.u_imem.mem[0]  = enc_addi(5'd1, 5'd0, 5);
        dut.u_imem.mem[1]  = enc_addi(5'd2, 5'd1, 7);
        dut.u_imem.mem[2]  = enc_add(5'd3, 5'd2, 5'd1);
        dut.u_imem.mem[3]  = enc_sw(5'd3, 5'd0, 0);
        dut.u_imem.mem[4]  = enc_lw(5'd4, 5'd0, 0);
        dut.u_imem.mem[5]  = enc_addi(5'd5, 5'd4, 1);
        dut.u_imem.mem[6]  = enc_addi(5'd6, 5'd0, 18);
        dut.u_imem.mem[7]  = enc_bne(5'd5, 5'd6, 56);
        dut.u_imem.mem[8]  = enc_beq(5'd5, 5'd6, 8);
        dut.u_imem.mem[9]  = enc_jal(5'd0, 48);
        dut.u_imem.mem[10] = enc_jal(5'd7, 8);
        dut.u_imem.mem[11] = enc_addi(5'd9, 5'd0, -1);
        dut.u_imem.mem[12] = enc_addi(5'd9, 5'd0, 60);
        dut.u_imem.mem[13] = enc_jalr(5'd8, 5'd9, 0);
        dut.u_imem.mem[14] = enc_addi(5'd10, 5'd0, -1);
        dut.u_imem.mem[15] = enc_addi(5'd10, 5'd0, 56);
        dut.u_imem.mem[16] = enc_bne(5'd8, 5'd10, 20);
        dut.u_imem.mem[17] = enc_lui(5'd11, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[18] = enc_addi(5'd12, 5'd0, 1);
        dut.u_imem.mem[19] = enc_sw(5'd12, 5'd11, 0);
        dut.u_imem.mem[20] = enc_jal(5'd0, 0);
        dut.u_imem.mem[21] = enc_lui(5'd11, TEST_RESULT_ADDR[31:12]);
        dut.u_imem.mem[22] = enc_addi(5'd12, 5'd0, 2);
        dut.u_imem.mem[23] = enc_sw(5'd12, 5'd11, 0);
        dut.u_imem.mem[24] = enc_jal(5'd0, 0);

        // repeat：重复执行,始终上升沿执行，下降沿保证事件模型可靠
        repeat (4) @(posedge clk); // 保持复位跨过 4 个上升沿，确保所有时序状态完成复位
        @(negedge clk); // 在非采样边沿撤销复位，避免与 DUT 的 posedge always_ff 竞争
        rst = 1'b0;  //rst没有清除imem和dmem的内容
        for (cycles = 0; cycles < 500; cycles = cycles + 1) begin
            @(negedge clk); // 在上升沿的 NBA 更新和组合逻辑稳定后采样
            if (commit_exception && commit_valid) //异常要与有效位结合
                $fatal(1, "unexpected exception at pc=%h inst=%h", commit_pc, commit_inst);
            if (test_done) begin
                assert (test_pass) else $fatal(1, "directed program failed code=%0d", test_code);
                $display("PASS tb_core_rv32i cycles=%0d", cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "directed program timeout");
        $finish;
    end
endmodule
