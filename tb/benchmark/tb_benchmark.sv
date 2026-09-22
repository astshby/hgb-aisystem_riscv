// Module: tb_benchmark
// Description: Runs a bare-metal C image and passively observes console and tohost Stores.
module tb_benchmark;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;

    localparam int unsigned IMEM_DEPTH_WORDS = 32768;
    localparam int unsigned DMEM_DEPTH_WORDS = 131072 / DBUS_BYTES;
    localparam int unsigned BYTE_OFFSET_W = $clog2(DBUS_BYTES);

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
    logic [XLEN-1:0] console_addr;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;
    string imem_path;
    string dmem_path;
    string test_name;
    integer max_cycles;
    integer cycles;
    logic trace_enable;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;

    sim_cpu_top #(
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .DMEM_DEPTH_WORDS(DMEM_DEPTH_WORDS)
    ) dut (.*);
    store_result_monitor u_result_monitor (.*);

    // 输出 Store 仍写入 DMem；TB 只把指定地址的字节镜像到仿真日志。
    always_ff @(posedge clk) begin
        if (!rst && dmem_store_fire && (dmem_store_addr == console_addr) &&
            dmem_store_strb[dmem_store_addr[BYTE_OFFSET_W-1:0]]) begin
            $write("%c", dmem_store_data[8*dmem_store_addr[BYTE_OFFSET_W-1:0] +: 8]);
        end
    end

    initial begin
        if (!$value$plusargs("IMEM=%s", imem_path))
            $fatal(1, "missing +IMEM=<path>");
        if (!$value$plusargs("DMEM=%s", dmem_path))
            $fatal(1, "missing +DMEM=<path>");
        if (!$value$plusargs("TOHOST=%h", result_addr))
            $fatal(1, "missing +TOHOST=<address>");
        if (!$value$plusargs("CONSOLE=%h", console_addr))
            $fatal(1, "missing +CONSOLE=<address>");
        if (!$value$plusargs("TEST=%s", test_name))
            test_name = "benchmark";
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 1000000;
        trace_enable = $test$plusargs("TRACE");

        $readmemh(imem_path, dut.u_imem.mem);
        $readmemh(dmem_path, dut.u_dmem.mem);
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
            @(negedge clk);
            if (trace_enable && commit_valid)
                $display("COMMIT pc=%h inst=%h rd=%0d we=%0b data=%h exc=%0b",
                         commit_pc, commit_inst, commit_rd, commit_rd_we,
                         commit_rd_data, commit_exception);
            if (test_done) begin
                assert (test_pass)
                    else $fatal(1, "FAIL %s code=%0d pc=%h inst=%h",
                                test_name, test_code, commit_pc, commit_inst);
                $display("PASS %s RV%0d cycles=%0d", test_name, XLEN, cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "TIMEOUT %s cycles=%0d pc=%h inst=%h",
               test_name, max_cycles, commit_pc, commit_inst);
        $finish;
    end

    logic unused_commit;
    assign unused_commit = ^{commit_rd, commit_rd_we, commit_rd_data,
                             commit_exception};
endmodule
