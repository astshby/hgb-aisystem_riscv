// Module: tb_soc_clock_contract
// Description: Clock-discovery ABI, peripheral timer/UART timing and system-clock SPI cadence.
module tb_soc_clock_contract #(
    parameter int CLOCK_PROFILE = 1
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import axi_types_pkg::*;
    localparam int CORE_HZ = CLOCK_PROFILE == 9 ? 88750000 :
        (CLOCK_PROFILE == 10 ? 83806818 : 100000000);
    localparam int SYS_HZ = CLOCK_PROFILE == 9 ? 98611111 :
        (CLOCK_PROFILE == 10 ? 102430556 : 80000000);
    localparam int PERIPH_HZ = CLOCK_PROFILE == 9 ? 68269231 :
        (CLOCK_PROFILE == 10 ? 65848214 : 25000000);
    localparam real SYS_PERIOD_NS = CLOCK_PROFILE == 9 ? 720.0/71.0 :
        (CLOCK_PROFILE == 10 ? 576.0/59.0 : 12.5);
    localparam real PERIPH_PERIOD_NS = CLOCK_PROFILE == 9 ? 1040.0/71.0 :
        (CLOCK_PROFILE == 10 ? 896.0/59.0 : 40.0);
    logic clk = 0, sys_clk = 0, rst = 1;
    // 绝对边沿累计保留分数周期，不能每半拍四舍五入后持续漂移。
    initial begin
        longint unsigned edge_count = 0;
        realtime edge_time;
        forever begin
            edge_count++;
            edge_time = real'(edge_count) * PERIPH_PERIOD_NS / 2.0;
            #(edge_time-$realtime); clk = !clk;
        end
    end
    initial begin
        longint unsigned edge_count = 0;
        realtime edge_time;
        forever begin
            edge_count++;
            edge_time = real'(edge_count) * SYS_PERIOD_NS / 2.0;
            #(edge_time-$realtime); sys_clk = !sys_clk;
        end
    end
    axil_req_t axi_req = '0;
    axil_rsp_t axi_rsp;
    logic [1:0] uart_tx;
    logic [31:0] gpio_in [3] = '{default:0};
    logic cache_command_valid;
    mmio_bus #(.CLOCK_HZ(125000000), .CLOCK_INFO_ENABLE(1),
        .CORE_CLOCK_HZ(CORE_HZ), .SYS_CLOCK_HZ(SYS_HZ),
        .DDR_CLOCK_HZ(125000000), .PERIPH_CLOCK_HZ(PERIPH_HZ)) dut (
        .clk, .rst, .ddr_ready(1'b1), .axi_req, .axi_rsp, .uart_rx(2'b11), .uart_tx,
        .gpio_in, .gpio_out(), .gpio_oe(), .irq_software(), .irq_timer(), .irq_external(),
        .cache_command_valid, .cache_command(), .cache_command_ready(1'b1),
        .cache_busy(1'b0), .cache_fatal(1'b0), .cache_error(cache_pkg::CACHE_OK), .cache_fault_addr('0),
        .dma_req_valid(), .dma_req_ready(1'b0), .dma_request(), .dma_rsp_valid(1'b0),
        .dma_rsp_ready(), .dma_response('0), .dma_irq(1'b0),
        .flash_req_valid(), .flash_req_ready(1'b0), .flash_request(), .flash_rsp_valid(1'b0),
        .flash_rsp_ready(), .flash_response('0)
    );
    logic old_req_valid = 0, old_req_ready, old_rsp_valid;
    bus_req_t old_request = '0;
    bus_rsp_t old_response;
    soc_info #(.CLOCK_HZ(50000000)) legacy (
        .clk, .rst, .req_valid(old_req_valid), .req_ready(old_req_ready), .request(old_request),
        .rsp_valid(old_rsp_valid), .rsp_ready(1'b1), .response(old_response),
        .cache_command_valid(), .cache_command(), .cache_command_ready(1'b1),
        .cache_busy(1'b0), .cache_fatal(1'b0), .cache_error(cache_pkg::CACHE_OK), .cache_fault_addr('0)
    );
    logic spi_req_valid = 0, spi_req_ready, spi_rsp_valid, spi_sck, spi_cs_n;
    bus_req_t spi_request = '0;
    bus_rsp_t spi_response;
    spi_flash_reader spi (
        .clk(sys_clk), .rst, .req_valid(spi_req_valid), .req_ready(spi_req_ready), .request(spi_request),
        .rsp_valid(spi_rsp_valid), .rsp_ready(1'b1), .response(spi_response),
        .command(8'h03), .address_four_bytes(1'b0), .dummy_bits(8'd0), .divider(16'd4),
        .busy(), .spi_cs_n, .spi_sck, .spi_mosi(), .spi_miso(1'b0)
    );
    realtime timer_sample_time;
    always @(posedge clk) begin
        if (!rst && dut.device_req_valid[4] && dut.device_req_ready[4] &&
            !dut.device_request[4].write && dut.device_request[4].addr[15:0] == 16'hbff8)
            timer_sample_time = $realtime;
        if (!rst && cache_command_valid) $fatal(1, "clock access emitted cache command");
    end
    task automatic read_word(input logic [31:0] addr, output logic [31:0] data,
                             input axi_resp_e expected = AXI_OKAY, input int stall = 0);
        axil_r_t held;
        @(negedge clk);
        axi_req.ar_valid = 1;
        axi_req.ar.addr = addr;
        axi_req.r_ready = 0;
        do @(posedge clk); while (!axi_rsp.ar_ready);
        @(negedge clk); axi_req.ar_valid = 0;
        while (!axi_rsp.r_valid) @(negedge clk);
        held = axi_rsp.r;
        repeat (stall) begin
            @(negedge clk);
            if (!axi_rsp.r_valid || axi_rsp.r !== held) $fatal(1, "stalled read changed %x", addr);
        end
        if (axi_rsp.r.resp != expected) $fatal(1, "read response %x got %d expected %d", addr, axi_rsp.r.resp, expected);
        data = 32'(axi_rsp.r.data >> (addr[2] * 32));
        axi_req.r_ready = 1;
        @(posedge clk); @(negedge clk); axi_req.r_ready = 0;
    endtask
    task automatic write_word(input logic [31:0] addr, input logic [31:0] data,
                              input axi_resp_e expected = AXI_OKAY);
        bit aw_done, w_done;
        aw_done = 0; w_done = 0;
        @(negedge clk);
        axi_req.aw_valid = 1; axi_req.aw.addr = addr;
        axi_req.w_valid = 1; axi_req.w.data = 64'(data) << (addr[2] * 32);
        axi_req.w.strb = 8'h0f << (addr[2] * 4);
        axi_req.b_ready = 0;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            aw_done |= axi_rsp.aw_ready; w_done |= axi_rsp.w_ready;
            @(negedge clk);
            axi_req.aw_valid = !aw_done; axi_req.w_valid = !w_done;
        end
        while (!axi_rsp.b_valid) @(negedge clk);
        if (axi_rsp.b != expected) $fatal(1, "write response %x", addr);
        repeat (3) begin
            @(negedge clk);
            if (!axi_rsp.b_valid || axi_rsp.b != expected) $fatal(1, "stalled write changed");
        end
        axi_req.b_ready = 1;
        @(posedge clk); @(negedge clk); axi_req.b_ready = 0;
    endtask
    task automatic expect_word(input logic [31:0] offset, input logic [31:0] expected);
        logic [31:0] actual;
        read_word(32'h10040000 + offset, actual, AXI_OKAY, 3);
        if (actual !== expected) $fatal(1, "ABI offset %x got %x expected %x", offset, actual, expected);
    endtask
    task automatic legacy_read(input logic [11:0] offset, input bus_error_e expected,
                               input logic [31:0] data);
        @(negedge clk);
        old_request = '0; old_request.addr = xlen_t'(32'h10040000) + xlen_t'(offset);
        old_request.size = MEM_WORD; old_req_valid = 1;
        do @(posedge clk); while (!old_req_ready);
        @(negedge clk); old_req_valid = 0;
        if (!old_rsp_valid || old_response.error != expected) $fatal(1, "legacy response %x", offset);
        if (expected == BUS_OK && 32'(old_response.rdata >> (8*(int'(offset) % DBUS_BYTES))) != data)
            $fatal(1, "legacy ABI %x", offset);
        @(negedge clk);
    endtask
    logic [31:0] value, timer_first, timer_last;
    realtime first_time, last_time, uart_start, uart_end, spi_first, spi_last;
    initial begin
        repeat (5) @(negedge clk); rst = 0;
        expect_word('h000, 32'(XLEN));
        expect_word('h004, 125000000);
        expect_word('h008, soc_config_pkg::ITCM_BYTES);
        expect_word('h00c, soc_config_pkg::DTCM_BYTES);
        expect_word('h038, {17'b0,soc_config_pkg::SOC_FULL_PRESENT});
        expect_word('h03c, 32'h00010100 | 32'(soc_config_pkg::SOC_PROFILE_FULL));
        expect_word('h050, 32'h0001001f);
        expect_word('h054, CORE_HZ);
        expect_word('h058, SYS_HZ);
        expect_word('h05c, 125000000);
        expect_word('h060, PERIPH_HZ);
        expect_word('h064, PERIPH_HZ);
        for (int off = 'h50; off <= 'h64; off += 4)
            write_word(32'h10040000 + 32'(off), 32'hdeadbeef, AXI_SLVERR);
        read_word(32'h10040068, value, AXI_SLVERR);
        legacy_read('h004, BUS_OK, 50000000);
        legacy_read('h03c, BUS_OK, 32'h00010000 | 32'(soc_config_pkg::SOC_PROFILE_FULL));
        for (int off = 'h50; off <= 'h64; off += 4)
            legacy_read(12'(off), BUS_SLVERR, 0);
        read_word(32'h0200bff8, timer_first); first_time = timer_sample_time;
        repeat (31) @(negedge clk);
        read_word(32'h0200bff8, timer_last); last_time = timer_sample_time;
        if (last_time - first_time < real'(timer_last - timer_first) * PERIPH_PERIOD_NS - 0.002 ||
            last_time - first_time > real'(timer_last - timer_first) * PERIPH_PERIOD_NS + 0.002)
            $fatal(1, "mtime frequency disagrees with periph");
        write_word(32'h1000000c, 25);
        fork
            begin
                @(negedge uart_tx[0]); uart_start = $realtime;
                @(posedge uart_tx[0]); uart_end = $realtime;
                if (uart_end - uart_start < 25.0 * PERIPH_PERIOD_NS - 0.002 ||
                    uart_end - uart_start > 25.0 * PERIPH_PERIOD_NS + 0.002)
                    $fatal(1, "UART bit duration %f", uart_end-uart_start);
            end
            begin
                write_word(32'h10000000, 32'hff);
            end
        join
        @(negedge sys_clk);
        spi_request.addr = xlen_t'(32'h30000000); spi_request.size = MEM_WORD;
        spi_req_valid = 1;
        do @(posedge sys_clk); while (!spi_req_ready);
        @(negedge sys_clk); spi_req_valid = 0;
        @(posedge spi_sck); spi_first = $realtime;
        repeat (7) @(posedge spi_sck);
        spi_last = $realtime;
        if (spi_last-spi_first < 56.0 * SYS_PERIOD_NS - 0.002 ||
            spi_last-spi_first > 56.0 * SYS_PERIOD_NS + 0.002)
            $fatal(1, "SPI cadence disagrees with sys");
        while (!spi_rsp_valid) @(negedge sys_clk);
        if (spi_response.error != BUS_OK || spi_response.rdata != 0) $fatal(1, "SPI result");
        $display("PASS soc_clock_contract rv%0d C%0d ABI/backpressure/readonly/legacy core=%0d sys=%0d periph=%0d DDR125 mtime/UART/SPI", XLEN, CLOCK_PROFILE, CORE_HZ, SYS_HZ, PERIPH_HZ);
        $finish;
    end
    initial begin #200us; $fatal(1, "clock-contract timeout"); end
endmodule
