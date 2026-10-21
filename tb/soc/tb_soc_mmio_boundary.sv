// Module: tb_soc_mmio_boundary
// Description: Checks per-endpoint request snapshots, registered response ownership, side effects, and reset.
module tb_soc_mmio_boundary;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;

    logic clk = 0, rst = 1;
    logic [1:0] uart_rx = '1, uart_tx;
    logic [31:0] gpio_in [3] = '{default:'0}, gpio_out [3], gpio_oe [3];
    logic irq_software, irq_timer, irq_external;
    logic cache_command_valid, cache_command_ready = 1, cache_busy = 0, cache_fatal = 0;
    cache_pkg::cache_maint_op_e cache_command;
    cache_pkg::cache_maint_error_e cache_error = cache_pkg::CACHE_OK;
    xlen_t cache_fault_addr = '0;
    logic dma_req_valid, dma_req_ready = 0, dma_rsp_valid = 0, dma_rsp_ready;
    bus_req_t dma_request;
    bus_rsp_t dma_response = '0;
    logic [13:4] s_req_valid = '0, s_req_ready, s_rsp_valid, s_rsp_ready = '0;
    bus_req_t s_request [4:13] = '{default:'0};
    bus_rsp_t s_response [4:13];
    int accepted [4:13], issued [4:13], completed [4:13], accepted_cycle [4:13];
    int cycles = 0, checks = 0, commands = 0, starts = 0, minimum_latency = 10000;
    bus_rsp_t observed;

    always #5 clk = ~clk;
    soc_peripherals #(.UART_DIVISOR(8)) dut (
        .dma_block_rd_cmd_valid(), .dma_block_rd_cmd_ready(1'b0), .dma_block_rd_cmd(),
        .dma_block_rd_valid(1'b0), .dma_block_rd_ready(), .dma_block_rd_data('0),
        .dma_block_wr_cmd_valid(), .dma_block_wr_cmd_ready(1'b0), .dma_block_wr_cmd(),
        .dma_block_wr_valid(), .dma_block_wr_ready(1'b0), .dma_block_wr_data(),
        .dma_block_wr_rsp_valid(1'b0), .dma_block_wr_rsp_ready(), .dma_block_wr_rsp('0),
        .dma_wide_req_valid(), .dma_wide_req_ready(1'b0), .dma_wide_request(),
        .dma_wide_rsp_valid(1'b0), .dma_wide_rsp_ready(), .dma_wide_response('0), .*);

    // 分开统计保存、设备执行和响应交付；valid 保持不能被计成多笔事务。
    always @(posedge clk) begin
        cycles++;
        if (rst) begin
            commands = 0;
            starts = 0;
            for (int s = 4; s <= 13; s++) begin
                accepted[s] = 0;
                issued[s] = 0;
                completed[s] = 0;
                accepted_cycle[s] = 0;
            end
        end else begin
            if (cache_command_valid && cache_command_ready) commands++;
            if (dut.u_dma.start_valid) starts++;
            for (int s = 4; s <= 13; s++) begin
                if (s_req_valid[s] && s_req_ready[s]) begin
                    accepted[s]++;
                    accepted_cycle[s] = cycles;
                end
                if (dut.device_req_valid[s] && dut.device_req_ready[s]) issued[s]++;
                if (s_rsp_valid[s] && s_rsp_ready[s]) begin
                    completed[s]++;
                    assert (cycles - accepted_cycle[s] >= 2)
                        else $fatal(1, "MMIO boundary response bypass target=%0d", s);
                    if (cycles - accepted_cycle[s] < minimum_latency)
                        minimum_latency = cycles - accepted_cycle[s];
                end
                assert (accepted[s] >= issued[s] && issued[s] >= completed[s] &&
                        accepted[s] - completed[s] <= 1)
                    else $fatal(1, "MMIO boundary duplicated/lost ownership target=%0d", s);
            end
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic reset_all;
        rst = 1;
        s_req_valid = '0;
        s_rsp_ready = '0;
        #1;
        assert (!(|s_req_ready) && !(|s_rsp_valid) && !(|dut.device_req_valid))
            else $fatal(1, "MMIO handshake escaped coordinated reset");
        tick();
        rst = 0;
        #1;
        assert (&s_req_ready && !(|s_rsp_valid) && !(|dut.device_req_valid))
            else $fatal(1, "MMIO old request/response replayed after reset");
    endtask

    task automatic begin_request(input int s, input logic [31:0] addr,
        input bit write, input logic [31:0] data, input logic [3:0] mask = 4'hf);
        bus_req_t wanted;
        wanted = '0;
        wanted.addr = xlen_t'(addr);
        wanted.size = MEM_WORD;
        wanted.write = write;
        wanted.wdata = xlen_t'(data) << ((addr % DBUS_BYTES)*8);
        wanted.wstrb = DBUS_BYTES'(mask << (addr % DBUS_BYTES));
        s_request[s] = wanted;
        s_req_valid[s] = 1;
        #1;
        assert (s_req_ready[s] && !dut.device_req_valid[s] && !s_rsp_valid[s])
            else $fatal(1, "MMIO request path not isolated target=%0d", s);
        tick();
        s_req_valid[s] = 0;
        // 地址、权限、数据和 strobe 全部改掉，设备必须继续使用已接受的快照。
        s_request[s] = '1;
        #1;
        assert (!s_req_ready[s] && dut.device_req_valid[s] &&
                dut.device_request[s] == wanted && !s_rsp_valid[s])
            else $fatal(1, "MMIO request snapshot changed target=%0d", s);
    endtask

    task automatic finish_request(input int s, input bus_error_e want_error,
        input int hold_cycles = 0);
        int timeout_count;
        bus_rsp_t held;
        timeout_count = 0;
        while (!s_rsp_valid[s]) begin
            tick(); #1;
            timeout_count++;
            assert (timeout_count < 20) else $fatal(1, "MMIO boundary timeout target=%0d", s);
        end
        held = s_response[s];
        assert (held.error == want_error && !dut.device_req_valid[s])
            else $fatal(1, "MMIO response/error or repeated issue target=%0d", s);
        repeat (hold_cycles) begin
            tick();
            s_request[s] = bus_req_t'('0);
            #1;
            assert (s_rsp_valid[s] && s_response[s] == held && !s_req_ready[s] &&
                    !dut.device_req_valid[s] && !dut.device_rsp_ready[s])
                else $fatal(1, "MMIO held response/owner changed target=%0d", s);
        end
        observed = held;
        s_rsp_ready[s] = 1;
        #1;
        assert (!s_req_ready[s]) else $fatal(1, "S1 boundary unexpectedly enabled turnover");
        tick();
        s_rsp_ready[s] = 0;
        #1;
        assert (s_req_ready[s] && !s_rsp_valid[s] && accepted[s] == completed[s])
            else $fatal(1, "MMIO transaction did not drain target=%0d", s);
        checks++;
    endtask

    initial begin
        repeat (2) tick();
        reset_all();

        // 十个目标逐一读取；包含 RV64 上半字 lane 与动态 mtime 响应快照。
        for (int s = 4; s <= 13; s++) begin
            logic [31:0] addr;
            unique case (s)
                4: addr = MTIME_BASE + 32'hbff8;
                5: addr = IRQ_BASE + 4;
                6: addr = UART0_BASE + 8;
                7: addr = UART1_BASE + 8;
                8: addr = TIMER_BASE + 4;
                9: addr = GPIO0_BASE + 4;
                10: addr = GPIO1_BASE + 4;
                11: addr = GPIO2_BASE + 4;
                12: addr = DMA_BASE + 4;
                default: addr = SOC_BASE;
            endcase
            begin_request(s, addr, 0, 0);
            finish_request(s, BUS_OK, s-3);
        end

        // 一个端点响应被反压时，另一个端点仍可独立完成。
        begin_request(9, GPIO0_BASE + 4, 1, 32'h11223344, 4'b0101);
        begin_request(13, SOC_BASE, 0, 0);
        assert (gpio_out[0] == 32'h00220044 && s_rsp_valid[9])
            else $fatal(1, "GPIO snapshot/lane/side effect failed");
        finish_request(13, BUS_OK, 3);
        assert (observed.rdata == xlen_t'(XLEN) && s_rsp_valid[9] && !s_req_ready[9])
            else $fatal(1, "independent MMIO target blocked or stole owner");
        finish_request(9, BUS_OK, 4);

        // W1C 已清掉旧事件，但写响应仍被反压时，新上升沿必须继续保留。
        // 只检查一次清零不足以发现重复 W1C；这里让新事件落在同一响应占用期内。
        begin_request(9, GPIO0_BASE + 16, 1, 1);
        finish_request(9, BUS_OK);
        gpio_in[0] = 1;
        repeat (4) tick();
        begin_request(9, GPIO0_BASE + 24, 0, 0);
        finish_request(9, BUS_OK);
        assert (observed.rdata == xlen_t'(1)) else $fatal(1, "GPIO initial event missing");
        begin_request(9, GPIO0_BASE + 24, 1, 1);
        tick();
        assert (s_rsp_valid[9] && !s_rsp_ready[9] && dut.g_gpio[0].u_gpio.pending_q == 0)
            else $fatal(1, "GPIO W1C did not execute before held response");
        gpio_in[0] = 0;
        repeat (4) tick();
        gpio_in[0] = 1;
        repeat (4) tick();
        assert (s_rsp_valid[9] && dut.g_gpio[0].u_gpio.pending_q == 1)
            else $fatal(1, "GPIO new event lost during W1C response");
        finish_request(9, BUS_OK, 12);
        begin_request(9, GPIO0_BASE + 24, 0, 0);
        finish_request(9, BUS_OK);
        assert (observed.rdata == xlen_t'(1)) else $fatal(1, "GPIO W1C repeated while response held");

        // 两个同优先级源一起 pending；第一次 claim 保持时不能顺带领取第二个源。
        begin_request(10, GPIO1_BASE + 16, 1, 1);
        finish_request(10, BUS_OK);
        // GPIO 中断输出还需 enable；pending 本身不受 enable 影响。
        begin_request(9, GPIO0_BASE + 12, 1, 1);
        finish_request(9, BUS_OK);
        begin_request(10, GPIO1_BASE + 12, 1, 1);
        finish_request(10, BUS_OK);
        gpio_in[1] = 1;
        repeat (4) tick();
        begin_request(5, IRQ_BASE + 16, 1, 1);
        finish_request(5, BUS_OK);
        begin_request(5, IRQ_BASE + 20, 1, 1);
        finish_request(5, BUS_OK);
        begin_request(5, IRQ_BASE + 32'h2000, 1, 32'h30);
        finish_request(5, BUS_OK);
        begin_request(5, IRQ_BASE + 32'h200004, 0, 0);
        finish_request(5, BUS_OK, 12);
        assert ((observed.rdata >> ((4 % DBUS_BYTES) * 8)) == xlen_t'(4))
            else $fatal(1, "held IRQ claim returned wrong first owner");
        begin_request(5, IRQ_BASE + 32'h200004, 0, 0);
        finish_request(5, BUS_OK, 4);
        assert ((observed.rdata >> ((4 % DBUS_BYTES) * 8)) == xlen_t'(5))
            else $fatal(1, "IRQ claim consumed second source while response held");

        begin_request(13, SOC_BASE + 32'h20, 1, 1);
        finish_request(13, BUS_OK, 12);
        assert (commands == 1) else $fatal(1, "maintenance side effect repeated");
        begin_request(13, SOC_BASE + 32'h20, 1, 1, 0);
        finish_request(13, BUS_OK, 3);
        begin_request(13, SOC_BASE + 32'h20, 1, 4);
        finish_request(13, BUS_SLVERR, 3);
        assert (commands == 1) else $fatal(1, "masked/illegal maintenance executed");
        // 零长度 DMA 由原引擎拒绝；启动脉冲本身必须仅出现一次。
        begin_request(12, DMA_BASE + 12, 1, 1);
        finish_request(12, BUS_OK, 12);
        assert (starts == 1 && !dma_req_valid) else $fatal(1, "DMA start duplicated");

        // 尚未执行的 SEND，以及已有响应的 WAIT_RESPONSE，都检查协调复位不重放。
        begin_request(13, SOC_BASE + 32'h20, 1, 1);
        reset_all();
        repeat (3) tick();
        assert (commands == 0) else $fatal(1, "unissued command escaped reset");
        begin_request(13, SOC_BASE, 0, 0);
        tick();
        assert (s_rsp_valid[13]) else $fatal(1, "missing response before reset");
        reset_all();
        begin_request(13, SOC_BASE, 0, 0);
        finish_request(13, BUS_OK);
        assert (minimum_latency == 2) else $fatal(1, "unnecessary MMIO response register latency");
        $display("PASS tb_soc_mmio_boundary RV%0d cases=%0d endpoints=10 min_latency=%0d reset_states=2", XLEN, checks, minimum_latency);
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "MMIO boundary watchdog");
    end
endmodule
