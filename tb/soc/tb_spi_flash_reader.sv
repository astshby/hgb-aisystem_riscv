// Module: tb_spi_flash_reader
// Description: Pin-level SPI read lengths, lanes, captured configuration, cadence and backpressure.
module tb_spi_flash_reader;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
    bus_req_t request = '0;
    bus_rsp_t response;
    logic [7:0] command = 0, dummy_bits = 0;
    logic address_four_bytes = 0;
    logic [15:0] divider = 1;
    logic busy, spi_cs_n, spi_sck, spi_mosi, spi_miso = 0;
    spi_flash_reader dut (.*);

    int cycles = 0, accepted_cycle = 0, request_fires = 0, response_fires = 0;
    int successful_reads = 0, rejected_reads = 0, pin_transactions = 0;
    int length_checks [4] = '{default:0};
    logic [7:0] expected_command;
    logic [31:0] expected_offset;
    int expected_address_bits, expected_dummy, expected_bytes, expected_divider;
    int rises = 0, last_toggle = 0;
    logic previous_cs = 1, previous_sck = 0;

    // 引脚模型独立按地址生成每个字节，不读取 DUT 的移位寄存器或状态机。
    function automatic logic [7:0] flash_byte(input logic [31:0] address);
        return 8'((address * 32'd29) ^ (address >> 8) ^ (address >> 16) ^ (address >> 24) ^ 32'ha6);
    endfunction
    always @(posedge clk) begin
        cycles++;
        if (!rst && req_valid && req_ready) begin
            request_fires++;
            accepted_cycle = cycles;
        end
        if (!rst && rsp_valid && rsp_ready) response_fires++;
    end
    // DUT 仅在上升沿更新 SCK；模型在下降沿观察，再为下一个 SCK 上升沿准备 MISO。
    always @(negedge clk) begin
        if (rst) begin
            previous_cs = 1;
            previous_sck = 0;
            spi_miso = 0;
            rises = 0;
        end else begin
            if (previous_cs && !spi_cs_n) begin
                rises = 0;
                last_toggle = accepted_cycle;
                assert (!spi_sck) else $fatal(1, "SPI must start in mode 0");
            end
            if (!spi_cs_n && spi_sck != previous_sck) begin
                assert (cycles-last_toggle == expected_divider)
                    else $fatal(1, "SPI divider changed got=%0d expected=%0d", cycles-last_toggle, expected_divider);
                last_toggle = cycles;
                if (spi_sck) begin
                    if (rises < 8) begin
                        assert (spi_mosi == expected_command[7-rises]) else $fatal(1, "SPI command mismatch");
                    end else if (rises < 8+expected_address_bits) begin
                        assert (spi_mosi == expected_offset[expected_address_bits-1-(rises-8)])
                            else $fatal(1, "SPI address mismatch");
                    end else if (rises < 8+expected_address_bits+expected_dummy) begin
                        assert (!spi_mosi) else $fatal(1, "SPI dummy bit mismatch");
                    end
                    rises++;
                end else begin
                    int data_bit;
                    logic [7:0] byte_value;
                    data_bit = rises-(8+expected_address_bits+expected_dummy);
                    if (data_bit >= 0 && data_bit < expected_bytes*8) begin
                        byte_value = flash_byte(expected_offset+32'(data_bit/8));
                        spi_miso = byte_value[7-(data_bit%8)];
                    end else spi_miso = 0;
                end
            end
            if (!previous_cs && spi_cs_n) begin
                assert (rises == 8+expected_address_bits+expected_dummy+8*expected_bytes && !spi_sck)
                    else $fatal(1, "SPI transfer length/last edge mismatch rises=%0d", rises);
                pin_transactions++;
            end
            previous_cs = spi_cs_n;
            previous_sck = spi_sck;
        end
    end

    task automatic read_case(input int size, lane, mode, div_value, dummy_override = -1);
        xlen_t expected;
        bus_rsp_t held;
        int old_requests, old_responses, old_pins, stall;
        expected_bytes = 1 << size;
        expected_address_bits = mode >= 2 ? 32 : 24;
        expected_command = mode == 0 ? 8'h03 : mode == 1 ? 8'h0b : mode == 2 ? 8'h13 : 8'h0c;
        expected_dummy = dummy_override >= 0 ? dummy_override : ((mode & 1) != 0 ? 8 : 0);
        expected_divider = div_value == 0 ? 1 : div_value;
        expected_offset = (mode >= 2 ? 32'h01001230 : 32'h00001230)+32'(lane);
        expected = '0;
        for (int b = 0; b < expected_bytes; b++)
            expected[(lane+b)*8 +: 8] = flash_byte(expected_offset+32'(b));
        old_requests = request_fires;
        old_responses = response_fires;
        old_pins = pin_transactions;
        @(negedge clk);
        command = expected_command;
        address_four_bytes = mode >= 2;
        dummy_bits = 8'(expected_dummy);
        divider = 16'(div_value);
        request = '0;
        request.addr = xlen_t'(32'h30000000)+xlen_t'(expected_offset);
        request.size = mem_size_e'(size);
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        // 接纳后改变全部外部配置和请求载荷，传输仍须使用已捕获值。
        command = ~expected_command;
        address_four_bytes = !(mode >= 2);
        dummy_bits = ~8'(expected_dummy);
        divider = 16'hffff;
        request.addr = '1;
        request.size = MEM_BYTE;
        while (!rsp_valid) @(negedge clk);
        held = response;
        assert (held.error == BUS_OK && held.rdata === expected)
            else $fatal(1, "SPI data size=%0d lane=%0d mode=%0d got=%h expected=%h", size, lane, mode, held.rdata, expected);
        stall = (size+lane+mode+div_value)%9;
        req_valid = 1;
        repeat (stall+2) begin
            @(negedge clk);
            assert (rsp_valid && response === held && !req_ready && !busy && spi_cs_n && !spi_sck)
                else $fatal(1, "SPI response/backpressure/idle pins changed");
        end
        req_valid = 0;
        rsp_ready = 1;
        @(posedge clk);
        @(negedge clk); rsp_ready = 0;
        @(negedge clk);
        assert (!rsp_valid && req_ready && request_fires == old_requests+1 &&
                response_fires == old_responses+1 && pin_transactions == old_pins+1)
            else $fatal(1, "SPI request/response conservation failed");
        successful_reads++;
        length_checks[size]++;
    endtask

    task automatic reject_case(input bit write_access, execute_access, high_address, oversize);
        bus_rsp_t held;
        int old_pins;
        old_pins = pin_transactions;
        @(negedge clk);
        command = 8'h03; address_four_bytes = 0; dummy_bits = 0; divider = 1;
        request = '0;
        request.addr = xlen_t'(high_address ? 32'h31000000 : 32'h30000000);
        request.write = write_access;
        request.execute = execute_access;
        request.size = oversize ? MEM_DWORD : MEM_BYTE;
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk); req_valid = 0;
        while (!rsp_valid) @(negedge clk);
        held = response;
        assert (held.error == BUS_SLVERR && held.rdata == 0) else $fatal(1, "SPI invalid request not rejected");
        repeat (4) begin
            @(negedge clk);
            assert (rsp_valid && response === held && !req_ready && !busy && spi_cs_n && !spi_sck)
                else $fatal(1, "SPI rejection changed under backpressure");
        end
        rsp_ready = 1;
        @(posedge clk);
        @(negedge clk); rsp_ready = 0;
        @(negedge clk);
        assert (pin_transactions == old_pins && req_ready && !rsp_valid)
            else $fatal(1, "SPI invalid request touched pins");
        rejected_reads++;
    endtask

    initial begin
        int divider_values [5] = '{0,1,2,3,7};
        int dummy_values [4] = '{1,7,31,255};
        repeat (4) @(negedge clk);
        rst = 0;
        for (int mode = 0; mode < 4; mode++)
            foreach (divider_values[d])
                for (int size = 0; size <= $clog2(DBUS_BYTES); size++)
                    for (int lane = 0; lane < DBUS_BYTES; lane += (1 << size))
                        read_case(size, lane, mode, divider_values[d]);
        foreach (dummy_values[d]) read_case($clog2(DBUS_BYTES), 0, 3, 3, dummy_values[d]);
        reject_case(1,0,0,0);
        reject_case(0,1,0,0);
        reject_case(0,0,1,0);
        if (XLEN == 32) reject_case(0,0,0,1);
        assert (request_fires == successful_reads+rejected_reads && response_fires == request_fires)
            else $fatal(1, "SPI final conservation failed");
        $display("PASS spi_flash_reader rv%0d reads=%0d rejected=%0d byte=%0d half=%0d word=%0d dword=%0d lanes=all_aligned commands=4 dividers=5 dummy_extra=4 captured_config=1 backpressure=1",
            XLEN, successful_reads, rejected_reads, length_checks[0], length_checks[1], length_checks[2], length_checks[3]);
        $finish;
    end
    initial begin #50ms; $fatal(1, "SPI reader timeout"); end
endmodule
