// Module: tb_soc_benchmark
// Description: Runs a bare-metal C image and passively observes console and tohost Stores.
module tb_soc_benchmark #(
    parameter int unsigned DDR_BYTES = 0,
    parameter bit DCACHE_ENABLE = 1'b1
);
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;

    localparam int unsigned BYTE_OFFSET_W = $clog2(DBUS_BYTES);

    logic [1:0] uart_rx;
    logic uart_loopback, gpio_loopback;
    logic [1:0] uart_tx;
    logic [31:0] gpio_in [3];
    logic [31:0] gpio_out [3], gpio_oe [3];
    logic ddr_req_valid, ddr_req_ready, ddr_rsp_valid, ddr_rsp_ready;
    bus_types_pkg::bus_req_t ddr_request;
    bus_types_pkg::bus_rsp_t ddr_response;
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
    logic [31:0] fault_read_addr = 32'hffffffff, fault_write_addr = 32'hffffffff;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;
    assign uart_rx = uart_loopback ? uart_tx : 2'b11;
    for (genvar g = 0; g < 3; g++) begin : g_gpio_loopback
        assign gpio_in[g] = gpio_loopback ? (gpio_out[g] & gpio_oe[g]) : '0;
    end

    soc_top #(.DDR_BYTES(DDR_BYTES), .DCACHE_ENABLE(DCACHE_ENABLE)) dut (.*);
    if (DDR_BYTES != 0) begin : g_external
        logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
        logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
        logic [31:0] awaddr, araddr;
        logic [7:0] awlen, arlen;
        logic [2:0] awsize, arsize, awprot, arprot;
        logic [1:0] awburst, arburst, bresp, rresp;
        logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
        logic [XLEN-1:0] wdata, rdata;
        logic [DBUS_BYTES-1:0] wstrb;
        local_to_axi u_bridge (
            .clk, .rst, .req_valid(ddr_req_valid), .req_ready(ddr_req_ready),
            .request(ddr_request), .rsp_valid(ddr_rsp_valid),
            .rsp_ready(ddr_rsp_ready), .response(ddr_response),
            .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
            .awlock, .awcache, .awqos, .awregion, .awprot,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
            .arlock, .arcache, .arqos, .arregion, .arprot,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
        axi_memory_model #(.BYTES(DDR_BYTES)) u_external (
            .clk, .rst, .fault_read_addr,
            .fault_write_addr,
            .awvalid, .awready, .awaddr, .awsize,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .araddr, .arsize,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
    end else begin : g_no_external
        assign ddr_req_ready = 1'b0;
        assign ddr_rsp_valid = 1'b0;
        assign ddr_response = '0;
    end
    store_result_monitor u_result_monitor (.*);

    // Core 一笔在途的约束保证接收缓冲不会被第二个 I 响应覆盖。
    always @(posedge clk) begin
        if (!rst && dut.m_rsp_valid[0])
            assert (!dut.u_icache.u_port.buffer_valid_q)
                else $fatal(1, "instruction response buffer overwritten");
    end

    // Cache 统计来自真实 DDR 取指事务，而非 TCM 软件是否 PASS。
    integer cache_hits = 0, ddr_fetches = 0, fence_commits = 0;
    integer dcache_hits = 0, dcache_commands = 0;
    integer fatal_cycles = 0;
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (dut.u_icache.touch && !dut.u_icache.install) cache_hits <= cache_hits + 1;
            if (ddr_req_valid && ddr_req_ready && ddr_request.execute) ddr_fetches <= ddr_fetches + 1;
            if (dut.u_dcache.touch && !dut.u_dcache.install) dcache_hits <= dcache_hits + 1;
            if (dut.cache_command_valid && dut.cache_command_ready) dcache_commands <= dcache_commands + 1;
            if (dut.fence_i_commit) fence_commits <= fence_commits + 1;
        end
    end

    // 输出 Store 仍写入物理 TCM；TB 只把指定地址的字节镜像到仿真日志。
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
        void'($value$plusargs("FAULT_READ=%h", fault_read_addr));
        void'($value$plusargs("FAULT_WRITE=%h", fault_write_addr));
        trace_enable = $test$plusargs("TRACE");
        uart_loopback = $test$plusargs("UART_LOOPBACK");
        gpio_loopback = $test$plusargs("GPIO_LOOPBACK");

        $readmemh(imem_path, dut.u_itcm.mem);
        $readmemh(dmem_path, dut.u_dtcm.mem);
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
            @(negedge clk);
            if (trace_enable && commit_valid)
                $display("COMMIT pc=%h inst=%h rd=%0d we=%0b data=%h exc=%0b",
                         commit_pc, commit_inst, commit_rd, commit_rd_we,
                         commit_rd_data, commit_exception);
            if ($test$plusargs("EXPECT_CACHE_FATAL") && dut.cache_fatal) begin
                assert (dut.fetch_block && !dut.imem_req_ready && !commit_valid &&
                        dut.cache_error == cache_pkg::CACHE_WRITEBACK_ERROR &&
                        dut.cache_fault_addr == XLEN'(fault_write_addr) && fence_commits != 0)
                    else $fatal(1, "FENCE.I writeback failure did not stop younger execution");
                fatal_cycles++;
                if (fatal_cycles == 32) begin
                    $display("PASS soc-cache-fatal RV%0d cycles=%0d fault=%h", XLEN, cycles, dut.cache_fault_addr);
                    completed = 1; break;
                end
            end
            if (test_done) begin
                assert (!$test$plusargs("EXPECT_CACHE_FATAL")) else $fatal(1, "missing expected cache failure");
                assert (test_pass)
                    else $fatal(1, "FAIL %s code=%0d pc=%h inst=%h",
                                test_name, test_code, commit_pc, commit_inst);
                if ($test$plusargs("CACHE_CHECKS")) begin
                    assert (cache_hits >= 16 && ddr_fetches >= 24 && fence_commits >= 3)
                        else $fatal(1, "missing cache coverage hits=%0d reads=%0d fences=%0d",
                                    cache_hits, ddr_fetches, fence_commits);
                    $display("CACHE hits=%0d DDR_fetches=%0d FENCE.I=%0d",
                             cache_hits, ddr_fetches, fence_commits);
                end
                if ($test$plusargs("DCACHE_CHECKS")) begin
                    assert ((!DCACHE_ENABLE || dcache_hits >= 8) && dcache_commands >= 2)
                        else $fatal(1, "missing D-cache coverage hits=%0d commands=%0d",
                                    dcache_hits, dcache_commands);
                    $display("DCACHE enabled=%0d hits=%0d commands=%0d",
                             DCACHE_ENABLE, dcache_hits, dcache_commands);
                end
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
