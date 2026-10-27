// Module: tb_soc_profile
// Description: Checks profile discovery, absent-window errors and preserved IRQ identities through the real fabric.
module tb_soc_profile #(
    parameter int unsigned SOC_PROFILE = 0,
    parameter int unsigned DDR_BYTES = 0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    // 独立期望表，不能从 DUT 读到的 mask 推导同一测试的期望值。
    localparam logic [15:0] EXPECT_PRESENT = (SOC_PROFILE == 0 ? 16'h3fff : 16'h327f) |
                                           (DDR_BYTES == 0 ? 16'h0000 : 16'h4000);
    localparam logic [31:0] OPTIONAL_BASE [4] = '{UART1_BASE, TIMER_BASE, GPIO1_BASE, GPIO2_BASE};
    logic clk = 0, rst = 1;
    logic [1:0] m_req_valid = '0, m_req_ready, m_rsp_valid, m_rsp_ready = '0;
    bus_req_t m_request [2];
    bus_rsp_t m_response [2];
    logic [15:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [16];
    bus_rsp_t s_response [16];
    bus_error_e s_error [16];
    logic [1:0] uart_rx = '1, uart_tx;
    logic [31:0] gpio_in [3] = '{default:'0}, gpio_out [3], gpio_oe [3];
    logic irq_software, irq_timer, irq_external;
    logic cache_command_valid;
    cache_pkg::cache_maint_op_e cache_command;
    logic dma_req_valid, dma_rsp_ready;
    bus_req_t dma_request;
    int checks = 0, requests = 0, responses = 0, maint_commands = 0;
    logic [31:0] value;
    always #5 clk = ~clk;

    bus_interconnect #(.MASTERS(2), .DDR_BYTES(DDR_BYTES), .PRESENT(EXPECT_PRESENT),
                       .DATA_PRIORITY(1'b1)) u_fabric (
        .clk, .rst, .m_req_valid, .m_req_ready, .m_request, .m_rsp_valid, .m_rsp_ready, .m_response,
        .s_req_valid, .s_req_ready, .s_request, .s_error, .s_rsp_valid, .s_rsp_ready, .s_response
    );
    soc_peripherals #(.DDR_BYTES(DDR_BYTES), .SOC_PROFILE(SOC_PROFILE),
                      .PRESENT(EXPECT_PRESENT), .UART_DIVISOR(8)) dut (
        .dma_block_rd_cmd_valid(), .dma_block_rd_cmd_ready(1'b0), .dma_block_rd_cmd(),
        .dma_block_rd_valid(1'b0), .dma_block_rd_ready(), .dma_block_rd_data('0),
        .dma_block_wr_cmd_valid(), .dma_block_wr_cmd_ready(1'b0), .dma_block_wr_cmd(),
        .dma_block_wr_valid(), .dma_block_wr_ready(1'b0), .dma_block_wr_data(),
        .dma_block_wr_rsp_valid(1'b0), .dma_block_wr_rsp_ready(), .dma_block_wr_rsp('0),
        .clk, .rst, .uart_rx, .uart_tx, .gpio_in, .gpio_out, .gpio_oe,
        .irq_software, .irq_timer, .irq_external, .cache_command_valid, .cache_command,
        .cache_command_ready(1'b1), .cache_busy(1'b0), .cache_fatal(1'b0),
        .cache_error(cache_pkg::CACHE_OK), .cache_fault_addr('0),
        .dma_req_valid, .dma_req_ready(1'b0), .dma_request,
        .dma_rsp_valid(1'b0), .dma_rsp_ready, .dma_response('0),
        .dma_wide_req_valid(), .dma_wide_req_ready(1'b0), .dma_wide_request(),
        .dma_wide_rsp_valid(1'b0), .dma_wide_rsp_ready(), .dma_wide_response('0),
        .s_req_valid(s_req_valid[13:4]), .s_req_ready(s_req_ready[13:4]),
        .s_request(s_request[4:13]), .s_rsp_valid(s_rsp_valid[13:4]),
        .s_rsp_ready(s_rsp_ready[13:4]), .s_response(s_response[4:13])
    );
    bus_error_slave u_error (
        .clk, .rst, .req_valid(s_req_valid[0]), .req_ready(s_req_ready[0]), .req_error(s_error[0]),
        .rsp_valid(s_rsp_valid[0]), .rsp_ready(s_rsp_ready[0]), .response(s_response[0])
    );
    // 此从端仅检查 DDR window 的存在性路由，不代表 DDR 数据或板级验证。
    bus_error_slave u_ddr_stub (
        .clk, .rst, .req_valid(s_req_valid[14]), .req_ready(s_req_ready[14]), .req_error(BUS_OK),
        .rsp_valid(s_rsp_valid[14]), .rsp_ready(s_rsp_ready[14]), .response(s_response[14])
    );
    for (genvar s = 1; s <= 3; s++) begin : g_unused_memory
        assign s_req_ready[s] = 1'b0;
        assign s_rsp_valid[s] = 1'b0;
        assign s_response[s] = '0;
    end

    // 源计数、缺失端点与外部引脚同时观察，防止“只屏蔽读回”冒充实际裁剪。
    always @(posedge clk) if (!rst) begin
        if (m_req_valid[1] && m_req_ready[1]) requests++;
        if (m_rsp_valid[1] && m_rsp_ready[1]) responses++;
        assert (requests >= responses && requests - responses <= 1) else $fatal(1, "transaction cardinality");
        if (cache_command_valid) maint_commands++;
        assert ((s_req_valid & ~EXPECT_PRESENT) == 0) else $fatal(1, "absent target selected");
        if (SOC_PROFILE == 1) begin
            assert (uart_tx[1] && gpio_out[1] == 0 && gpio_oe[1] == 0 &&
                    gpio_out[2] == 0 && gpio_oe[2] == 0) else $fatal(1, "absent pins not tied off");
            assert (!dut.uart_irq[1] && !dut.timer_irq && dut.gpio_irq[2:1] == 0)
                else $fatal(1, "absent IRQ source active");
            assert ((s_req_ready[13:4] & ~EXPECT_PRESENT[13:4]) == 0 &&
                    (s_rsp_valid[13:4] & ~EXPECT_PRESENT[13:4]) == 0)
                else $fatal(1, "absent endpoint has a transaction slot");
        end
    end

    task automatic transfer(input xlen_t address, input bit write, input logic [31:0] data,
                            input mem_size_e size, input bit execute, input logic [3:0] strobe,
                            input bus_error_e expected_error, output logic [31:0] result);
        bus_rsp_t held;
        int lane;
        @(negedge clk);
        lane = int'(address % xlen_t'(DBUS_BYTES));
        m_request[1] = '0;
        m_request[1].addr = address;
        m_request[1].write = write;
        m_request[1].execute = execute;
        m_request[1].size = size;
        m_request[1].wdata = xlen_t'(data) << (lane * 8);
        m_request[1].wstrb = DBUS_BYTES'(strobe) << lane;
        m_req_valid[1] = 1'b1;
        m_rsp_ready[1] = 1'b0;
        do @(posedge clk); while (!m_req_ready[1]);
        @(negedge clk);
        m_req_valid[1] = 1'b0;
        // 接受后改载荷，返回仍必须属于旧请求；反压期间每笔副作用只能执行一次。
        m_request[1] = '1;
        while (!m_rsp_valid[1]) @(negedge clk);
        held = m_response[1];
        assert (held.error == expected_error)
            else $fatal(1, "profile=%0d addr=%h error=%0d expected=%0d", SOC_PROFILE, address, held.error, expected_error);
        repeat (3) begin
            @(negedge clk);
            assert (m_rsp_valid[1] && m_response[1] === held) else $fatal(1, "held response changed");
        end
        result = 32'(held.rdata >> (lane * 8));
        m_rsp_ready[1] = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_rsp_ready[1] = 1'b0;
        checks++;
    endtask

    task automatic read32(input logic [31:0] address, input logic [31:0] expected);
        transfer(xlen_t'(address), 0, 0, MEM_WORD, 0, 4'hf, BUS_OK, value);
        assert (value == expected) else $fatal(1, "addr=%h read=%h expected=%h", address, value, expected);
    endtask
    task automatic write32(input logic [31:0] address, input logic [31:0] data);
        transfer(xlen_t'(address), 1, data, MEM_WORD, 0, 4'hf, BUS_OK, value);
    endtask

    initial begin
        m_request[0] = '0; m_request[1] = '0;
        repeat (4) @(negedge clk);
        rst = 0;
        read32(SOC_BASE, 32'(XLEN));
        read32(SOC_BASE + 8, 65536);
        read32(SOC_BASE + 12, 65536);
        read32(SOC_BASE + 'h38, {16'b0, EXPECT_PRESENT});
        read32(SOC_BASE + 'h3c, 32'h00010000 | SOC_PROFILE);
        transfer(xlen_t'(SOC_BASE + 'h38), 1, '1, MEM_WORD, 0, 4'hf, BUS_SLVERR, value);
        transfer(xlen_t'(SOC_BASE + 'h3c), 1, '1, MEM_WORD, 0, 4'hf, BUS_SLVERR, value);
        transfer(xlen_t'(DDR_BASE), 0, 0, MEM_WORD, 0, 4'hf,
                 DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, value);
        for (int n = 0; n < 4; n++) begin
            transfer(xlen_t'(OPTIONAL_BASE[n]), 0, 0, MEM_WORD, 0, 4'hf,
                     SOC_PROFILE == 0 ? BUS_OK : BUS_DECERR, value);
            // 窗口是否安装不影响格式/执行权限错误的优先级。
            transfer(xlen_t'(OPTIONAL_BASE[n]), 0, 0, MEM_BYTE, 0, 4'h1, BUS_SLVERR, value);
            transfer(xlen_t'(OPTIONAL_BASE[n]), 0, 0, MEM_HALF, 0, 4'h3, BUS_SLVERR, value);
            transfer(xlen_t'(OPTIONAL_BASE[n]), 0, 0, MEM_DWORD, 0, 4'hf, BUS_SLVERR, value);
            transfer(xlen_t'(OPTIONAL_BASE[n] + 1), 0, 0, MEM_WORD, 0, 4'hf, BUS_SLVERR, value);
            transfer(xlen_t'(OPTIONAL_BASE[n]), 0, 0, MEM_WORD, 1, 4'hf, BUS_SLVERR, value);
            if (SOC_PROFILE == 1) begin
                transfer(xlen_t'(OPTIONAL_BASE[n]), 1, '1, MEM_WORD, 0, 4'hf, BUS_DECERR, value);
                transfer(xlen_t'(OPTIONAL_BASE[n]), 1, '1, MEM_WORD, 0, 4'h0, BUS_DECERR, value);
                transfer(xlen_t'(OPTIONAL_BASE[n] + 'hffc), 0, 0, MEM_WORD, 0, 4'hf, BUS_DECERR, value);
            end
        end
        if (XLEN == 64)
            transfer(xlen_t'(64'h0000000110001000), 0, 0, MEM_WORD, 0, 4'hf, BUS_DECERR, value);

        write32(GPIO0_BASE + 4, 32'h12345678);
        transfer(xlen_t'(GPIO0_BASE + 4), 1, '1, MEM_WORD, 0, 4'h0, BUS_OK, value);
        read32(GPIO0_BASE + 4, 32'h12345678);
        write32(SOC_BASE + 'h20, 3);
        assert (maint_commands == 1) else $fatal(1, "cache command repeated under backpressure");
        transfer(xlen_t'(SOC_BASE + 'h20), 1, 3, MEM_WORD, 0, 4'h0, BUS_OK, value);
        assert (maint_commands == 1) else $fatal(1, "zero-strobe cache command executed");
        read32(DMA_BASE + 'h10, 0);
        write32(MTIME_BASE, 1);
        assert (irq_software) else $fatal(1, "software IRQ absent");
        write32(MTIME_BASE, 0);
        assert (!irq_software) else $fatal(1, "software IRQ did not clear");

        for (int id = 1; id <= 7; id++) write32(IRQ_BASE + 32'(4 * id), 1);
        write32(IRQ_BASE + 'h2000, 'hfe);
        write32(GPIO0_BASE + 12, 1);
        write32(GPIO0_BASE + 16, 1);
        gpio_in[0] = 1;
        gpio_in[1] = '1; gpio_in[2] = '1; uart_rx[1] = 0;
        repeat (5) @(negedge clk);
        read32(IRQ_BASE + 'h200004, 4);
        write32(GPIO0_BASE + 24, 1);
        write32(IRQ_BASE + 'h200004, 4);
        read32(IRQ_BASE + 'h200004, 0);
        read32(IRQ_BASE + 'h1000, 0);
        repeat (5) @(negedge clk);
        assert (requests == checks && responses == checks) else $fatal(1, "profile transactions did not drain");
        $display("PASS tb_soc_profile RV%0d profile=%0d DDR_BYTES=%0d presence=%h checks=%0d req/rsp=%0d/%0d maint_commands=%0d",
                 XLEN, SOC_PROFILE, DDR_BYTES, EXPECT_PRESENT, checks, requests, responses, maint_commands);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "profile test timeout");
    end
endmodule
