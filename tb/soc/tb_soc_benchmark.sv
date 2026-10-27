// Module: tb_soc_benchmark
// Description: Runs a bare-metal C image and passively observes console and tohost Stores.
module tb_soc_benchmark #(
    parameter int unsigned DDR_BYTES = 0,
    parameter int unsigned DDR_MODEL_BYTES = DDR_BYTES,
    parameter logic [31:0] CLOCK_HZ = 50000000,
    parameter logic [31:0] UART_DIVISOR = 434,
    parameter bit DMA_WIDE_ENABLE = 1'b0,
    parameter bit DMA_BLOCK_ENABLE = 1'b0,
    parameter bit CACHE_BLOCK_ENABLE = 1'b0,
    parameter bit DCACHE_ENABLE = 1'b1,
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL,
    parameter int unsigned RESULT_BYTES = 4
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
    logic dma_wide_req_valid, dma_wide_req_ready, dma_wide_rsp_valid, dma_wide_rsp_ready;
    bus_types_pkg::ddr_req_t dma_wide_request;
    bus_types_pkg::ddr_rsp_t dma_wide_response;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready;
    logic [1:0] cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_types_pkg::block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_types_pkg::block_r_t cache_rd_data [2];
    block_types_pkg::block_w_t cache_wr_data [2];
    block_types_pkg::block_b_t cache_wr_rsp [2];
    logic dma_block_rd_cmd_valid, dma_block_rd_cmd_ready, dma_block_rd_valid, dma_block_rd_ready;
    logic dma_block_wr_cmd_valid, dma_block_wr_cmd_ready, dma_block_wr_valid, dma_block_wr_ready;
    logic dma_block_wr_rsp_valid, dma_block_wr_rsp_ready;
    block_types_pkg::block_cmd_t dma_block_rd_cmd, dma_block_wr_cmd;
    block_types_pkg::block_r_t dma_block_rd_data;
    block_types_pkg::block_w_t dma_block_wr_data;
    block_types_pkg::block_b_t dma_block_wr_rsp;
    logic dma_axi_read_pending_q, dma_axi_write_pending_q;
    integer dma_axi_reads = 0, dma_axi_writes = 0, dma_axi_read_beats = 0, dma_axi_write_beats = 0;
    integer dma_axi_read_bursts = 0, dma_axi_write_bursts = 0, dma_axi_overlap_cycles = 0;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic commit_valid;
    logic [XLEN-1:0] commit_pc;
    logic [31:0] commit_inst;
    logic [4:0] commit_rd;
    logic commit_rd_we;
    logic [XLEN-1:0] commit_rd_data;
    logic commit_exception;
    pipeline_pkg::retire_trace_t commit_trace [2];
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

    soc_top #(.DDR_BYTES(DDR_BYTES), .DMA_WIDE_ENABLE(DMA_WIDE_ENABLE), .DMA_BLOCK_ENABLE(DMA_BLOCK_ENABLE), .CACHE_BLOCK_ENABLE(CACHE_BLOCK_ENABLE), .DCACHE_ENABLE(DCACHE_ENABLE),
              .LOCAL_TCM_ENABLE(LOCAL_TCM_ENABLE), .SOC_PROFILE(SOC_PROFILE),
              .CLOCK_HZ(CLOCK_HZ), .UART_DIVISOR(UART_DIVISOR)) dut (.*);
    if (DDR_BYTES != 0) begin : g_external
        logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
        logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
        logic [31:0] awaddr, araddr;
        logic [7:0] awlen, arlen;
        logic [2:0] awsize, arsize, awprot, arprot;
        logic [1:0] awburst, arburst, bresp, rresp;
        logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
        logic [255:0] wdata, rdata;
        logic [31:0] wstrb;
        logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
        logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
        block_types_pkg::block_cmd_t rd_cmd, wr_cmd;
        block_types_pkg::block_r_t rd_data;
        block_types_pkg::block_w_t wr_data;
        block_types_pkg::block_b_t wr_rsp;
        ddr_block_fabric #(.DDR_BYTES(DDR_BYTES)) u_port (
            .clk, .rst, .cpu_req_valid(ddr_req_valid), .cpu_req_ready(ddr_req_ready), .cpu_request(ddr_request),
            .cpu_rsp_valid(ddr_rsp_valid), .cpu_rsp_ready(ddr_rsp_ready), .cpu_response(ddr_response),
            .dma_req_valid(dma_wide_req_valid), .dma_req_ready(dma_wide_req_ready), .dma_request(dma_wide_request),
            .dma_rsp_valid(dma_wide_rsp_valid), .dma_rsp_ready(dma_wide_rsp_ready), .dma_response(dma_wide_response),
            .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
            .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
            .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp,
            .dma_block_rd_cmd_valid, .dma_block_rd_cmd_ready, .dma_block_rd_cmd,
            .dma_block_rd_valid, .dma_block_rd_ready, .dma_block_rd_data,
            .dma_block_wr_cmd_valid, .dma_block_wr_cmd_ready, .dma_block_wr_cmd,
            .dma_block_wr_valid, .dma_block_wr_ready, .dma_block_wr_data,
            .dma_block_wr_rsp_valid, .dma_block_wr_rsp_ready, .dma_block_wr_rsp,
            .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
            .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
            .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
        );
        block_to_axi #(.DDR_BYTES(DDR_BYTES)) u_bridge (
            .clk, .rst, .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
            .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
            .wr_rsp_valid, .wr_rsp_ready, .wr_rsp,
            .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
            .awlock, .awcache, .awqos, .awregion, .awprot,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
            .arlock, .arcache, .arqos, .arregion, .arprot,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
        // 地址译码/桥保持完整 DDR 容量；仿真可只分配用于本次负载的低地址窗口，
        // 窗口之外由模型返回错误，不能据此宣称验证了全部物理 DDR。
        axi_block_memory_model #(.BYTES(DDR_MODEL_BYTES)) u_external (
            .clk, .rst, .fault_read_addr,
            .fault_write_addr,
            .awvalid, .awready, .awid, .awaddr, .awsize, .awlen,
            .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
            .arvalid, .arready, .arid, .araddr, .arsize, .arlen,
            .rvalid, .rready, .rid, .rdata, .rresp, .rlast
        );
        // backend每方向只有一笔，DMA块owner尚在时出现的AXI地址/数据只能属于该DMA。
        // 物理在途窗口与块接口的缓冲/交付窗口分开计数，不把后端暂存时间算成DDR并行。
        always_ff @(posedge clk) begin
            if (rst) begin
                dma_axi_read_pending_q <= 1'b0;
                dma_axi_write_pending_q <= 1'b0;
                dma_axi_reads <= 0;
                dma_axi_writes <= 0;
                dma_axi_read_beats <= 0;
                dma_axi_write_beats <= 0;
                dma_axi_read_bursts <= 0;
                dma_axi_write_bursts <= 0;
                dma_axi_overlap_cycles <= 0;
            end else begin
                if (dma_axi_read_pending_q && dma_axi_write_pending_q)
                    dma_axi_overlap_cycles <= dma_axi_overlap_cycles + 1;
                if (arvalid && arready && dma_read_pending_q) begin
                    dma_axi_read_pending_q <= 1'b1;
                    dma_axi_reads <= dma_axi_reads + 1;
                    if (arlen != 0) dma_axi_read_bursts <= dma_axi_read_bursts + 1;
                end
                if (rvalid && rready && dma_axi_read_pending_q) begin
                    dma_axi_read_beats <= dma_axi_read_beats + 1;
                    if (rlast) dma_axi_read_pending_q <= 1'b0;
                end
                if (awvalid && awready && dma_write_pending_q) begin
                    dma_axi_write_pending_q <= 1'b1;
                    dma_axi_writes <= dma_axi_writes + 1;
                    if (awlen != 0) dma_axi_write_bursts <= dma_axi_write_bursts + 1;
                end
                if (wvalid && wready && dma_write_pending_q)
                    dma_axi_write_beats <= dma_axi_write_beats + 1;
                if (bvalid && bready && dma_axi_write_pending_q)
                    dma_axi_write_pending_q <= 1'b0;
            end
        end
        int native_reads = 0, native_writes = 0;
        always @(posedge clk) begin
            if (!rst) begin
                if (arvalid && arready && arsize == 5) native_reads++;
                if (awvalid && awready && awsize == 5) native_writes++;
                // 旧单拍DMA专项不可用于Cache突发；通常块传输由模型保存的AW逐拍核对。
                if ($test$plusargs("DMA_WIDE_CHECK") && !CACHE_BLOCK_ENABLE && !DMA_BLOCK_ENABLE &&
                    wvalid && wready && awsize == 5)
                    assert (wstrb == 32'hffffffff && wlast && awlen == 0)
                        else $fatal(1, "native DMA write was not a complete 256-bit AXI beat");
            end
        end
        final begin
            if ($test$plusargs("DMA_WIDE_CHECK")) begin
                assert (test_pass && DMA_WIDE_ENABLE && !CACHE_BLOCK_ENABLE && !DMA_BLOCK_ENABLE &&
                        native_reads == 4 && native_writes == 4)
                    else $fatal(1, "missing native DMA software evidence reads=%0d writes=%0d", native_reads, native_writes);
                $display("PASS DMA_NATIVE_AXI RV%0d data_bits=256 ARSIZE5=%0d AWSIZE5=%0d LEN=0",
                         XLEN, native_reads, native_writes);
            end
        end
    end else begin : g_no_external
        assign dma_axi_read_pending_q = 1'b0;
        assign dma_axi_write_pending_q = 1'b0;
        assign cache_rd_cmd_ready = '0;
        assign cache_rd_valid = '0;
        assign cache_rd_data = '{default:'0};
        assign cache_wr_cmd_ready = '0;
        assign cache_wr_ready = '0;
        assign cache_wr_rsp_valid = '0;
        assign cache_wr_rsp = '{default:'0};
        assign dma_block_rd_cmd_ready = 1'b0;
        assign dma_block_rd_valid = 1'b0;
        assign dma_block_rd_data = '0;
        assign dma_block_wr_cmd_ready = 1'b0;
        assign dma_block_wr_ready = 1'b0;
        assign dma_block_wr_rsp_valid = 1'b0;
        assign dma_block_wr_rsp = '0;
        assign ddr_req_ready = 1'b0;
        assign ddr_rsp_valid = 1'b0;
        assign ddr_response = '0;
        assign dma_wide_req_ready = 1'b0;
        assign dma_wide_rsp_valid = 1'b0;
        assign dma_wide_response = '0;
    end

    // 被动记录DMA真实块握手；与CPU/Cache的AXI流量分开，不能只凭enable声称宽搬运。
    logic dma_read_pending_q, dma_write_pending_q;
    logic [31:0] dma_write_bytes_q;
    integer dma_block_reads = 0, dma_block_writes = 0, dma_multi_reads = 0, dma_multi_writes = 0;
    integer dma_overlap_cycles = 0, dma_success_bytes = 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            dma_read_pending_q <= 1'b0;
            dma_write_pending_q <= 1'b0;
            dma_write_bytes_q <= '0;
            dma_block_reads <= 0;
            dma_block_writes <= 0;
            dma_multi_reads <= 0;
            dma_multi_writes <= 0;
            dma_overlap_cycles <= 0;
            dma_success_bytes <= 0;
        end else begin
            if (dma_read_pending_q && dma_write_pending_q) dma_overlap_cycles <= dma_overlap_cycles + 1;
            if (dma_block_rd_cmd_valid && dma_block_rd_cmd_ready) begin
                assert (!dma_read_pending_q && dma_block_rd_cmd.size == 5 && dma_block_rd_cmd.addr[4:0] == 0)
                    else $fatal(1, "DMA read block owner/alignment");
                dma_read_pending_q <= 1'b1;
                dma_block_reads <= dma_block_reads + 1;
                if (dma_block_rd_cmd.len != 0) dma_multi_reads <= dma_multi_reads + 1;
            end
            if (dma_block_rd_valid && dma_block_rd_ready && dma_block_rd_data.last)
                dma_read_pending_q <= 1'b0;
            if (dma_block_wr_cmd_valid && dma_block_wr_cmd_ready) begin
                assert (!dma_write_pending_q && dma_block_wr_cmd.size == 5 && dma_block_wr_cmd.addr[4:0] == 0)
                    else $fatal(1, "DMA write block owner/alignment");
                dma_write_pending_q <= 1'b1;
                dma_block_writes <= dma_block_writes + 1;
                dma_write_bytes_q <= (32'(dma_block_wr_cmd.len) + 32'd1) << dma_block_wr_cmd.size;
                if (dma_block_wr_cmd.len != 0) dma_multi_writes <= dma_multi_writes + 1;
            end
            if (dma_block_wr_rsp_valid && dma_block_wr_rsp_ready) begin
                assert (dma_write_pending_q) else $fatal(1, "DMA B without accepted write owner");
                dma_write_pending_q <= 1'b0;
                if (dma_block_wr_rsp.error == bus_types_pkg::BUS_OK)
                    dma_success_bytes <= dma_success_bytes + int'(dma_write_bytes_q);
            end
        end
    end
    final begin
        if ($test$plusargs("DMA_BLOCK_CHECK")) begin
            assert (test_pass && DMA_WIDE_ENABLE && DMA_BLOCK_ENABLE && DDR_BYTES != 0 &&
                    dma_block_reads > 0 && dma_block_writes > 0 && dma_multi_reads > 0 &&
                    dma_multi_writes > 0 && dma_overlap_cycles > 0 &&
                    dma_axi_overlap_cycles > 0 && dma_axi_read_bursts > 0 && dma_axi_write_bursts > 0 &&
                    !dma_read_pending_q && !dma_write_pending_q &&
                    !dma_axi_read_pending_q && !dma_axi_write_pending_q)
                else $fatal(1, "missing DMA block/multiple beat/overlap/drain evidence");
            $display("PASS DMA_BLOCK_AXI RV%0d read_commands=%0d write_commands=%0d multiread=%0d multiwrite=%0d block_overlap=%0d confirmed_bytes=%0d axi_read_bursts=%0d axi_write_bursts=%0d axi_R_beats=%0d axi_W_beats=%0d axi_overlap=%0d",
                XLEN, dma_block_reads, dma_block_writes, dma_multi_reads, dma_multi_writes,
                dma_overlap_cycles, dma_success_bytes, dma_axi_read_bursts, dma_axi_write_bursts,
                dma_axi_read_beats, dma_axi_write_beats, dma_axi_overlap_cycles);
        end
    end
    // 结果 Store 的总线所有者与退休 ID 从 TB 层级读取，不扩展 FPGA 接口。
    store_result_monitor #(.RESULT_BYTES(RESULT_BYTES)) u_result_monitor (
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

`ifndef CORE_SCOREBOARD
    // 旧 Core 一笔在途的约束保证接收缓冲不会被第二个 I 响应覆盖。
    always @(posedge clk) begin
        if (!rst && dut.m_rsp_valid[0])
            assert (!dut.u_icache.u_port.buffer_valid_q)
                else $fatal(1, "instruction response buffer overwritten");
    end
`endif

    // Cache 统计来自真实 DDR 取指事务，而非 TCM 软件是否 PASS。
    integer cache_hits = 0, ddr_fetches = 0, fence_commits = 0;
    integer dcache_hits = 0, dcache_commands = 0;
    integer fatal_cycles = 0;
    always_ff @(posedge clk) begin
        if (!rst) begin
`ifdef CORE_SCOREBOARD
            if (dut.u_memory.u_icache.touch && !dut.u_memory.u_icache.install) cache_hits <= cache_hits + 1;
            dcache_hits <= dcache_hits +
                int'(dut.u_memory.u_dcache.g_bank[0].u_cache.touch && !dut.u_memory.u_dcache.g_bank[0].u_cache.install) +
                int'(dut.u_memory.u_dcache.g_bank[1].u_cache.touch && !dut.u_memory.u_dcache.g_bank[1].u_cache.install);
`else
            if (dut.u_icache.touch && !dut.u_icache.install) cache_hits <= cache_hits + 1;
            if (dut.u_dcache.touch && !dut.u_dcache.install) dcache_hits <= dcache_hits + 1;
`endif
            if (ddr_req_valid && ddr_req_ready && ddr_request.execute) ddr_fetches <= ddr_fetches + 1;
            if (cache_rd_cmd_valid[0] && cache_rd_cmd_ready[0]) ddr_fetches <= ddr_fetches + 1;
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
        assert (DDR_MODEL_BYTES <= DDR_BYTES && (DDR_BYTES == 0 || DDR_MODEL_BYTES >= 32))
            else $fatal(1, "invalid simulated DDR backing size");
        $display("SOC_CONFIG profile=%0d presence=%h DDR_BYTES=%0d DDR_MODEL_BYTES=%0d DMA_WIDE=%0d CACHE_BLOCK=%0d CLOCK_HZ=%0d UART_DIVISOR=%0d",
                 SOC_PROFILE, dut.DEVICE_PRESENT, DDR_BYTES, DDR_MODEL_BYTES, DMA_WIDE_ENABLE, CACHE_BLOCK_ENABLE, CLOCK_HZ, UART_DIVISOR);
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

`ifdef CORE_SCOREBOARD
        dut.u_memory.u_itcm.load_image(imem_path);
        dut.u_memory.u_dtcm.load_image(dmem_path);
`else
        $readmemh(imem_path, dut.u_itcm.mem);
        $readmemh(dmem_path, dut.u_dtcm.mem);
`endif
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
            @(negedge clk);
            if (trace_enable)
                for (int lane = 0; lane < 2; lane++)
                    if (commit_trace[lane].valid)
                        $display("COMMIT pc=%h inst=%h rd=%0d we=%0b data=%h exc=%0b lane=%0d",
                                 commit_trace[lane].pc, commit_trace[lane].inst, commit_trace[lane].rd,
                                 commit_trace[lane].rd_we, commit_trace[lane].rd_data,
                                 commit_trace[lane].exception, lane);
            if ($test$plusargs("EXPECT_CACHE_FATAL") && dut.cache_fatal) begin
                assert (dut.fetch_block && !dut.imem_req_ready &&
                        !commit_trace[0].valid && !commit_trace[1].valid &&
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
                    assert (cache_hits >= 16 && ddr_fetches >= (CACHE_BLOCK_ENABLE ? 3 : 24) && fence_commits >= 3)
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
