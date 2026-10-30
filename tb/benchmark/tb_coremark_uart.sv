// Module: tb_coremark_uart
// Description: Exercises persistent CoreMark through real UART pins on the complete four-clock SoC.
module tb_coremark_uart #(
    parameter int CLOCK_PROFILE = 1,
    parameter int PERIPH_HZ = 25000000,
    parameter int BAUD = 500000,
    parameter int ICACHE_BYTES = 16384,
    parameter int DCACHE_BYTES = 8192
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    // 与固件时钟发现后的 UART 分频取整一致，外设分数频率不能向下取整。
    localparam int DIVISOR = (PERIPH_HZ + BAUD/2) / BAUD;
    tb_soc_system #(.DDR_BYTES(262144), .FLASH_BYTES(0), .NPU_ENABLE(0),
        .CLOCK_PROFILE(CLOCK_PROFILE), .UART_DIVISOR(DIVISOR), .AUTO_FINISH(0),
        .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES)) u_test();
    logic host_rx = 1'b1;
    string received_lines[$];
    int begin_count = 0;
    int ready_count = 0;
    int result_count = 0;

    function automatic bit starts_with(input string line, input string prefix);
        return line.len() >= prefix.len() && line.substr(0, prefix.len()-1) == prefix;
    endfunction

    initial force u_test.uart_rx = {1'b1, host_rx};
    initial forever begin
        byte unsigned value;
        static string line = "";
        @(negedge u_test.uart_tx[0]);
        repeat (DIVISOR/2) @(negedge u_test.clk_periph);
        assert (!u_test.uart_tx[0]) else $fatal(1, "UART start bit");
        for (int index = 0; index < 8; index++) begin
            repeat (DIVISOR) @(negedge u_test.clk_periph);
            value[index] = u_test.uart_tx[0];
        end
        repeat (DIVISOR) @(negedge u_test.clk_periph);
        assert (u_test.uart_tx[0]) else $fatal(1, "UART stop bit");
        if (value == 10) begin
            received_lines.push_back(line);
            if (starts_with(line, "CM_BEGIN ")) begin_count++;
            if (starts_with(line, "CM_RESULT ")) result_count++;
            if (starts_with(line, "READY ")) ready_count++;
            $display("%s", line);
            line = "";
        end else line = {line, value};
    end

    task automatic recv_line(output string line);
        while (received_lines.size() == 0) @(negedge u_test.clk_periph);
        line = received_lines.pop_front();
    endtask

    task automatic send_byte(input byte unsigned value);
        @(negedge u_test.clk_periph);
        host_rx = 0;
        repeat (DIVISOR) @(negedge u_test.clk_periph);
        for (int index = 0; index < 8; index++) begin
            host_rx = value[index];
            repeat (DIVISOR) @(negedge u_test.clk_periph);
        end
        host_rx = 1;
        repeat (DIVISOR) @(negedge u_test.clk_periph);
    endtask

    task automatic ready;
        string line;
        recv_line(line);
        assert (starts_with(line, "READY app=coremark ")) else $fatal(1, "missing READY: %s", line);
        assert (line.substr(line.len()-11,line.len()-1) == "test_only=1")
            else $fatal(1, "UART smoke requires test-only firmware");
    endtask

    task automatic check_run(input string expected_mode);
        string line, mode;
        int unsigned iterations, hz, formal;
        longint unsigned roi_cycles;
        int unsigned crc;
        bit have_begin = 0, have_result = 0;
        bit have_seed = 0, have_list = 0, have_matrix = 0, have_state = 0;
        forever begin
            recv_line(line);
            if (starts_with(line, "CM_BEGIN ")) begin
                assert (!have_begin && $sscanf(line, "CM_BEGIN mode=%s iterations=%d", mode, iterations) == 2 &&
                        mode == expected_mode && iterations == 2) else $fatal(1, "bad CM_BEGIN: %s", line);
                have_begin = 1;
            end
            if ($sscanf(line, "seedcrc          : 0x%x", crc) == 1) begin
                assert (crc == (expected_mode == "performance" ? 'he9f5 : 'h18f2)) else $fatal(1, "seed CRC");
                have_seed = 1;
            end
            if ($sscanf(line, "[0]crclist       : 0x%x", crc) == 1) begin
                assert (crc == (expected_mode == "performance" ? 'he714 : 'he3c1)) else $fatal(1, "list CRC");
                have_list = 1;
            end
            if ($sscanf(line, "[0]crcmatrix     : 0x%x", crc) == 1) begin
                assert (crc == (expected_mode == "performance" ? 'h1fd7 : 'h0747)) else $fatal(1, "matrix CRC");
                have_matrix = 1;
            end
            if ($sscanf(line, "[0]crcstate      : 0x%x", crc) == 1) begin
                assert (crc == (expected_mode == "performance" ? 'h8e3a : 'h8d84)) else $fatal(1, "state CRC");
                have_state = 1;
            end
            if (starts_with(line, "CM_RESULT ")) begin
                assert (have_begin && !have_result && $sscanf(line,
                    "CM_RESULT mode=%s iterations=%d roi_cycles=%d core_hz=%d formal=%d",
                    mode, iterations, roi_cycles, hz, formal) == 5 && mode == expected_mode &&
                    iterations == 2 && roi_cycles > 0 && hz == u_test.frequency_hz(0) && formal == 0)
                    else $fatal(1, "bad CM_RESULT: %s", line);
                have_result = 1;
            end
            if (starts_with(line, "DONE ")) begin
                assert (line == "DONE status=short" && have_begin && have_result &&
                        have_seed && have_list && have_matrix && have_state)
                    else $fatal(1, "incomplete UART CoreMark: %s", line);
                break;
            end
        end
    endtask

    initial begin
        ready();
        repeat (3000) @(negedge u_test.clk_core);
        assert (begin_count == 0) else $fatal(1, "benchmark started without command");
        send_byte(13);
        send_byte(10);
        check_run("performance");
        ready();
        repeat (3000) @(negedge u_test.clk_core);
        assert (begin_count == 1) else $fatal(1, "CRLF started a second run");
        send_byte("V");
        send_byte(13);
        send_byte(10);
        check_run("validation");
        ready();
        repeat (3000) @(negedge u_test.clk_core);
        assert (begin_count == 2 && result_count == 2 && ready_count == 3)
            else $fatal(1, "persistent command counts");
        $display("PASS board CoreMark UART RV%0d requests=2 ready=3 real_uart=1 formal=0", XLEN);
        $finish;
    end
endmodule
