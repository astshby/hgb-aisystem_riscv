// Module: tb_soc_peripherals
// Description: Checks MMIO lanes, held responses, timers, GPIO, UART, and claim/complete.
module tb_soc_peripherals;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    logic [1:0] uart_rx, uart_tx, rx_drive = '1;
    logic loopback = 1;
    logic [31:0] gpio_in [3] = '{default:'0};
    logic [31:0] gpio_out [3], gpio_oe [3];
    logic irq_software, irq_timer, irq_external;
    logic [14:4] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [4:14], request;
    bus_rsp_t s_response [4:14], response;
    bus_target_e target;
    bus_error_e error;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    logic [31:0] value;
    logic [63:0] wide_value;
    int checks = 0;
    always #5 clk = ~clk;
    assign uart_rx = loopback ? uart_tx : rx_drive;
    address_decode u_decode (.request, .target, .error);
    logic dma_req_valid, dma_req_ready, dma_rsp_valid, dma_rsp_ready;
    bus_req_t dma_request;
    bus_rsp_t dma_response;
    assign dma_req_ready = 1'b0;
    assign dma_rsp_valid = 1'b0;
    assign dma_response = '0;
    assign s_req_ready[14] = 1'b0;
    assign s_rsp_valid[14] = 1'b0;
    assign s_response[14] = '0;
    soc_peripherals #(.UART_DIVISOR(8)) dut (
        .clk, .rst, .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .irq_software, .irq_timer, .irq_external,
        .dma_req_valid, .dma_req_ready, .dma_request,
        .dma_rsp_valid, .dma_rsp_ready, .dma_response,
        .s_req_valid(s_req_valid[13:4]), .s_req_ready(s_req_ready[13:4]),
        .s_request(s_request[4:13]), .s_rsp_valid(s_rsp_valid[13:4]),
        .s_rsp_ready(s_rsp_ready[13:4]), .s_response(s_response[4:13])
    );

    // 单主端口定向驱动，沿用真实地址译码；非法偏移由各外设返回 SLVERR。
    always_comb begin
        s_req_valid = '0;
        s_rsp_ready = '0;
        req_ready = 0;
        rsp_valid = 0;
        response = '0;
        for (int s = 4; s <= 14; s++) s_request[s] = request;
        if (int'(target) >= 4 && int'(target) <= 14 && error == BUS_OK) begin
            s_req_valid[target] = req_valid;
            s_rsp_ready[target] = rsp_ready;
            req_ready = s_req_ready[target];
            rsp_valid = s_rsp_valid[target];
            response = s_response[target];
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic transfer(input logic [31:0] addr, input bit write,
        input logic [63:0] data, input mem_size_e size, input logic [7:0] strobes,
        input bus_error_e want_error, output logic [63:0] result, input int hold_cycles = 0);
        int timeout_count;
        bus_rsp_t held;
        request = '0;
        request.addr = xlen_t'(addr);
        request.write = write;
        request.size = size;
        request.wdata = xlen_t'(data) << ((addr % DBUS_BYTES)*8);
        request.wstrb = DBUS_BYTES'(strobes << (addr % DBUS_BYTES));
        req_valid = 1;
        #1;
        timeout_count = 0;
        while (!req_ready) begin
            tick(); #1;
            timeout_count++;
            assert (timeout_count < 20) else $fatal(1, "MMIO request timeout addr=%h", addr);
        end
        tick();
        req_valid = 0;
        #1;
        assert (rsp_valid && response.error == want_error)
            else $fatal(1, "MMIO response addr=%h valid=%b error=%0d/%0d", addr, rsp_valid, response.error, want_error);
        held = response;
        repeat (hold_cycles) begin
            tick(); #1;
            assert (rsp_valid && !req_ready && response == held)
                else $fatal(1, "MMIO response changed under backpressure addr=%h", addr);
        end
        result = 64'(response.rdata >> ((addr % DBUS_BYTES)*8));
        rsp_ready = 1;
        tick();
        rsp_ready = 0;
        #1;
        assert (!rsp_valid) else $fatal(1, "MMIO duplicate response");
        checks++;
    endtask
    task automatic wr(input logic [31:0] addr, data, input logic [3:0] mask = 4'hf,
                       input bus_error_e want_error = BUS_OK);
        logic [63:0] ignored;
        transfer(addr, 1, {32'b0,data}, MEM_WORD, {4'b0,mask}, want_error, ignored);
    endtask
    task automatic rd(input logic [31:0] addr, output logic [31:0] data,
                       input int hold_cycles = 0, input bus_error_e want_error = BUS_OK);
        logic [63:0] result;
        transfer(addr, 0, 0, MEM_WORD, 0, want_error, result, hold_cycles);
        data = result[31:0];
    endtask

    initial begin
        request = '0;
        request.addr = xlen_t'(MTIME_BASE);
        req_valid = 0;
        rsp_ready = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;

        wr(MTIME_BASE, 1);
        assert (irq_software) else $fatal(1, "MSIP set");
        rd(MTIME_BASE, value, 4);
        assert (value == 1) else $fatal(1, "MSIP read");
        wr(MTIME_BASE, 0);
        assert (!irq_software) else $fatal(1, "MSIP clear");
        wr(MTIME_BASE + 32'h4004, 0);
        wr(MTIME_BASE + 32'h4000, 0);
        assert (irq_timer) else $fatal(1, "MTIMECMP threshold");
        wr(MTIME_BASE + 32'h4004, '1);
        assert (!irq_timer) else $fatal(1, "MTIMECMP high half clear");
        rd(MTIME_BASE + 32'hbff8, value, 6);
        rd(MTIME_BASE + 8, value, 0, BUS_SLVERR);
        if (XLEN == 64) begin
            transfer(MTIME_BASE + 32'h4000, 1, 64'h1122334455667788, MEM_DWORD, 8'hff,
                     BUS_OK, wide_value);
            transfer(MTIME_BASE + 32'h4000, 0, 0, MEM_DWORD, 0, BUS_OK, wide_value, 3);
            assert (wide_value == 64'h1122334455667788) else $fatal(1, "atomic MTIMECMP");
        end

        // RV64 offset+4 位于上半字通道；字节使能必须只影响被选的字节。
        for (int g = 0; g < 3; g++) begin
            wr(GPIO0_BASE + 32'(g*4096) + 4, 32'h11223344);
            wr(GPIO0_BASE + 32'(g*4096) + 4, 32'haabbccdd, 4'b0101);
            rd(GPIO0_BASE + 32'(g*4096) + 4, value, 3);
            assert (value == 32'h11bb33dd && gpio_out[g] == value) else $fatal(1, "GPIO lane/mask");
            wr(GPIO0_BASE + 32'(g*4096) + 8, '1);
            assert (gpio_oe[g] == '1) else $fatal(1, "GPIO OE");
            wr(GPIO0_BASE + 32'(g*4096) + 12, 1);
            wr(GPIO0_BASE + 32'(g*4096) + 16, 1);
            wr(GPIO0_BASE + 32'(g*4096) + 20, 1);
            gpio_in[g] = 1;
            repeat (4) tick();
            rd(GPIO0_BASE + 32'(g*4096) + 24, value);
            assert (value[0]) else $fatal(1, "GPIO rising pending");
        end
        wr(GPIO0_BASE, 1, 4'hf, BUS_SLVERR);
        rd(GPIO0_BASE + 32'h20, value, 0, BUS_SLVERR);

        // 外部汇聚控制器：阈值、优先级、领取一次、服务中屏蔽、完成后重新挂起。
        wr(IRQ_BASE + 16, 2);
        wr(IRQ_BASE + 20, 3);
        wr(IRQ_BASE + 24, 3);
        wr(IRQ_BASE + 32'h2000, 32'h70);
        wr(IRQ_BASE + 32'h200000, 3);
        assert (!irq_external) else $fatal(1, "IRQ threshold");
        wr(IRQ_BASE + 32'h200000, 0);
        assert (irq_external) else $fatal(1, "IRQ enable");
        rd(IRQ_BASE + 32'h200004, value, 5);
        assert (value == 5) else $fatal(1, "IRQ priority/tie order");
        rd(IRQ_BASE + 32'h200004, value);
        assert (value == 6) else $fatal(1, "claim must not duplicate");
        wr(IRQ_BASE + 32'h200004, 5);
        repeat (2) tick();
        rd(IRQ_BASE + 32'h200004, value);
        assert (value == 5) else $fatal(1, "level source did not repend after completion");
        // 清外设，再完成；未清除的电平会正常重新触发。
        for (int g = 0; g < 3; g++)
            wr(GPIO0_BASE + 32'(g*4096) + 24, 1);
        wr(IRQ_BASE + 32'h200004, 5);
        wr(IRQ_BASE + 32'h200004, 6);
        rd(IRQ_BASE + 32'h200004, value);
        assert (value == 4) else $fatal(1, "pending source preserved");
        wr(IRQ_BASE + 32'h200004, 4);
        repeat (3) tick();
        assert (!irq_external) else $fatal(1, "completed cleared sources remained active");

        wr(TIMER_BASE + 4, 5);
        wr(TIMER_BASE + 8, 5);
        repeat (10) tick();
        rd(TIMER_BASE + 12, value, 3);
        assert (value == 1) else $fatal(1, "general timer event");
        rd(TIMER_BASE + 8, value);
        assert (value == 4) else $fatal(1, "one-shot did not disable");
        wr(TIMER_BASE + 12, 1);
        rd(TIMER_BASE + 12, value);
        assert (value == 0) else $fatal(1, "timer W1C");

        // 两个独立串口均做真实引脚环回，不绕过 TX/RX 状态机。
        for (int u = 0; u < 2; u++) begin
            wr(UART0_BASE + 32'(u*4096) + 16, 1);
            wr(UART0_BASE + 32'(u*4096), 32'ha5 + 32'(u));
            wr(UART0_BASE + 32'(u*4096), 32'hff, 4'hf, BUS_SLVERR);
            repeat (100) tick();
            rd(UART0_BASE + 32'(u*4096) + 8, value);
            assert (value[1:0] == 3) else $fatal(1, "UART ready/received");
            rd(UART0_BASE + 32'(u*4096) + 4, value, 4);
            assert (value == 32'ha5 + 32'(u)) else $fatal(1, "UART loopback data");
        end

        wr(UART0_BASE, 32'h11);
        repeat (100) tick();
        wr(UART0_BASE, 32'h22);
        repeat (100) tick();
        rd(UART0_BASE + 8, value);
        assert (value[2]) else $fatal(1, "UART overrun not reported");
        rd(UART0_BASE + 4, value);
        assert (value == 32'h11) else $fatal(1, "overrun must retain unread byte");
        wr(UART0_BASE + 8, 4);

        wr(UART0_BASE, 32'h33);
        repeat (100) tick();
        wr(UART0_BASE, 32'h44);
        rd(UART0_BASE + 4, value, 120);
        assert (value == 32'h33) else $fatal(1, "held RX response corrupted");
        rd(UART0_BASE + 4, value);
        assert (value == 32'h44) else $fatal(1, "RX pop repeated while held");

        loopback = 0;
        rx_drive[0] = 0;
        repeat (80) tick();
        rx_drive[0] = 1;
        repeat (40) tick();
        rd(UART0_BASE + 8, value);
        assert (value[3]) else $fatal(1, "UART framing error missing");
        wr(UART0_BASE + 8, 8);
        rd(UART0_BASE + 8, value);
        assert (!value[3]) else $fatal(1, "UART frame W1C");
        rd(UART0_BASE + 32'h20, value, 0, BUS_SLVERR);
        rd(SOC_BASE, value);
        assert (value == XLEN) else $fatal(1, "SoC XLEN info");
        wr(SOC_BASE, 1, 4'hf, BUS_SLVERR);
        $display("PASS tb_soc_peripherals RV%0d transfers=%0d", XLEN, checks);
        $finish;
    end
    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "peripheral watchdog");
    end
endmodule
