// Module: tb_pango_measure_top
// Description: Serialized runtime stimulus for the three physical diagnostic boundaries.
module tb_pango_measure_top #(
    parameter int unsigned MEASURE_LAYER = 0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import pango_measure_pkg::*;
    import axi_types_pkg::*;
    logic clk_core = 0, clk_sys = 0, clk_ddr = 0, clk_periph = 0;
    always #5 clk_core = !clk_core;
    always #6.25 clk_sys = !clk_sys;
    always #4 clk_ddr = !clk_ddr;
    always #20 clk_periph = !clk_periph;
    wire [3:0] clocks = {clk_periph, clk_ddr, clk_sys, clk_core};
    logic reset_async = 1;
    logic [3:0] scan_shift = 0, scan_update = 0, scan_capture = 0, scan_din = 0;
    logic [3:0] scan_dout;
    int retired = 0;
    bit x2_seen = 0, x5_seen = 0, x9_seen = 0, store_seen = 0;
    pango_measure_top #(.MEASURE_LAYER(MEASURE_LAYER)) dut (.*);

    // 全部功能输入经串口装载；层次引用仅被动观察实际 fire 和双退休，不强制内部信号。
    always @(posedge clk_core) begin
        if (reset_async || dut.rst_core) begin
            retired = 0;
            x2_seen = 0;
            x5_seen = 0;
            x9_seen = 0;
            store_seen = 0;
        end else begin
            for (int p = 0; p < 2; p++) begin
                if (dut.arch.trace[p].valid && !dut.arch.trace[p].exception) begin
                    retired++;
                    if (dut.arch.trace[p].rd_we && dut.arch.trace[p].rd == 2 && dut.arch.trace[p].rd_data == 43)
                        x2_seen = 1;
                    if (dut.arch.trace[p].rd_we && dut.arch.trace[p].rd == 5 && dut.arch.trace[p].rd_data == 44)
                        x5_seen = 1;
                    if (dut.arch.trace[p].rd_we && dut.arch.trace[p].rd == 9 && dut.arch.trace[p].rd_data == 77)
                        x9_seen = 1;
                end
            end
            if (dut.arch.store_fire && dut.arch.store_addr == 32'h01100000 && dut.arch.store_data == 43)
                store_seen = 1;
        end
    end
    task automatic load_input(input int domain, input logic [4095:0] value, input int width);
        for (int i = width-1; i >= 0; i--) begin
            @(negedge clocks[domain]);
            scan_shift[domain] = 1;
            scan_din[domain] = value[i];
        end
        @(negedge clocks[domain]); scan_shift[domain] = 0;
        scan_update[domain] = 1;
        @(negedge clocks[domain]); scan_update[domain] = 0;
    endtask
    task automatic clear_input(input int domain);
        // update 已将装载串清空，因此无需新串行传输即可在下一沿撤销请求。
        scan_update[domain] = 1;
        @(negedge clocks[domain]); scan_update[domain] = 0;
    endtask
    task automatic read_output(input int domain, input int width, output logic [4095:0] value);
        value = 0;
        @(negedge clocks[domain]); scan_capture[domain] = 1;
        @(negedge clocks[domain]); scan_capture[domain] = 0; scan_din[domain] = 0;
        for (int i = width-1; i >= 0; i--) begin
            value[i] = scan_dout[domain];
            scan_shift[domain] = 1;
            @(negedge clocks[domain]);
        end
        scan_shift[domain] = 0;
    endtask
    task automatic reset_all;
        @(negedge clk_core); reset_async = 1;
        scan_shift = 0; scan_update = 0; scan_capture = 0; scan_din = 0;
        repeat (12) @(negedge clk_core);
        reset_async = 0;
        repeat (12) @(negedge clk_core);
    endtask
    initial begin
        $display("MEASURE_WIDTHS xlen=%0d layer=%0d core_in=%0d core_out=%0d sys_in=%0d sys_out=%0d ddr_in=%0d ddr_out=%0d periph_in=%0d periph_out=%0d",
            XLEN, MEASURE_LAYER, dut.CORE_INPUT_BITS, dut.CORE_OUTPUT_BITS, dut.SYS_INPUT_BITS,
            dut.SYS_OUTPUT_BITS, dut.DDR_INPUT_BITS, dut.DDR_OUTPUT_BITS, dut.PERIPH_INPUT_BITS, dut.PERIPH_OUTPUT_BITS);
        #10000000;
        $fatal(1, "measurement test timeout");
    end

    if (MEASURE_LAYER == 0) begin : g_core_test
        core_drive_t value;
        core_observe_t result;
        logic [4095:0] captured;
        initial begin
            reset_all();
            value = '0;
            value.imem_req_ready = 1;
            load_input(0, 4096'(value), $bits(value));
            @(posedge clk_core);
            assert (dut.g_core.outputs.imem_req_valid && dut.g_core.outputs.imem_req_addr == 0)
                else $fatal(1, "H0 initial request missing");
            @(negedge clk_core); clear_input(0);
            value = '0;
            value.imem_rsp_valid = 1;
            value.imem_rsp_data = {32'h00108113, 32'h02a00093};
            load_input(0, 4096'(value), $bits(value));
            @(posedge clk_core);
            assert (dut.g_core.outputs.imem_rsp_ready) else $fatal(1, "H0 response not accepted");
            @(negedge clk_core); clear_input(0);
            repeat (100) @(negedge clk_core);
            assert (x2_seen && retired >= 2) else $fatal(1, "H0 dependent instruction execution failed");
            read_output(0, $bits(result), captured);
            result = core_observe_t'(captured);
            assert (result.imem_req_valid && result.imem_req_addr == 8)
                else $fatal(1, "H0 request boundary snapshot mismatch");
            $display("PASS tb_pango_measure_top layer=0 xlen=%0d serial_instruction_pair=1 dependent_retire=1 snapshot=1", XLEN);
            $finish;
        end
    end else if (MEASURE_LAYER == 1) begin : g_hot_test
        hot_drive_t value;
        hot_observe_t result;
        logic [4095:0] captured;
        int aw_count = 0, w_count = 0, ar_count = 0;
        always @(posedge clk_core) begin
            if (!dut.rst_core) begin
                if (dut.g_hot.inputs.tcm_request.aw_valid && dut.g_hot.outputs.tcm_response.aw_ready) aw_count++;
                if (dut.g_hot.inputs.tcm_request.w_valid && dut.g_hot.outputs.tcm_response.w_ready) w_count++;
                if (dut.g_hot.inputs.tcm_request.ar_valid && dut.g_hot.outputs.tcm_response.ar_ready) ar_count++;
            end
        end
        task automatic write_line(input logic [31:0] address, input logic [255:0] data, input logic [31:0] strb);
            int old_aw, old_w;
            $display("MEASURE_STEP H1 write %h", address);
            old_aw = aw_count; old_w = w_count;
            value = '0;
            value.tcm_request.aw_valid = 1;
            value.tcm_request.aw = '{id:1, addr:address, size:5, burst:1, default:'0};
            load_input(0, 4096'(value), $bits(value));
            while (!dut.g_hot.outputs.tcm_response.aw_ready) @(negedge clk_core);
            clear_input(0);
            value = '0;
            value.tcm_request.w_valid = 1;
            value.tcm_request.w = '{data:data, strb:strb, last:1};
            load_input(0, 4096'(value), $bits(value));
            while (!dut.g_hot.outputs.tcm_response.w_ready) @(negedge clk_core);
            clear_input(0);
            while (!dut.g_hot.outputs.tcm_response.b_valid) @(negedge clk_core);
            read_output(0, $bits(result), captured);
            result = hot_observe_t'(captured);
            assert (result.tcm_response.b_valid && result.tcm_response.b.id == 1 && result.tcm_response.b.resp == AXI_OKAY)
                else $fatal(1, "H1 TCM write response mismatch");
            value = '0; value.tcm_request.b_ready = 1;
            load_input(0, 4096'(value), $bits(value));
            clear_input(0);
            assert (aw_count == old_aw+1 && w_count == old_w+1)
                else $fatal(1, "H1 scan duplicated a write transaction");
        endtask
        task automatic read_line(input logic [31:0] address, input logic [255:0] expected);
            int old_ar;
            $display("MEASURE_STEP H1 read %h", address);
            old_ar = ar_count;
            value = '0; value.tcm_request.ar_valid = 1;
            value.tcm_request.ar = '{id:2, addr:address, size:5, burst:1, default:'0};
            load_input(0, 4096'(value), $bits(value));
            while (!dut.g_hot.outputs.tcm_response.ar_ready) @(negedge clk_core);
            clear_input(0);
            while (!dut.g_hot.outputs.tcm_response.r_valid) @(negedge clk_core);
            read_output(0, $bits(result), captured);
            result = hot_observe_t'(captured);
            assert (result.tcm_response.r_valid && result.tcm_response.r.id == 2 && result.tcm_response.r.last &&
                    result.tcm_response.r.resp == AXI_OKAY && result.tcm_response.r.data == expected)
                else $fatal(1, "H1 TCM read/byte-mask/snapshot mismatch addr=%h", address);
            value = '0; value.tcm_request.r_ready = 1;
            load_input(0, 4096'(value), $bits(value));
            clear_input(0);
            assert (ar_count == old_ar+1) else $fatal(1, "H1 scan duplicated a read transaction");
        endtask
        task automatic answer_cpu(input int port_index, input logic [31:0] expected_address,
                                  input logic [255:0] data);
            axi_a_t request;
            $display("MEASURE_STEP H1 answer port=%0d expected=%h", port_index, expected_address);
            while (!dut.g_hot.outputs.cpu_request[port_index].ar_valid) @(negedge clk_core);
            request = dut.g_hot.outputs.cpu_request[port_index].ar;
            assert (request.addr == expected_address && request.len == 0)
                else $fatal(1, "H1 CPU AXI request mismatch port=%0d addr=%h", port_index, request.addr);
            value = '0; value.cpu_response[port_index].ar_ready = 1;
            load_input(0, 4096'(value), $bits(value));
            clear_input(0);
            value = '0; value.cpu_response[port_index].r_valid = 1;
            value.cpu_response[port_index].r = '{id:request.id, data:data, resp:AXI_OKAY, last:1};
            load_input(0, 4096'(value), $bits(value));
            while (!dut.g_hot.outputs.cpu_request[port_index].r_ready) @(negedge clk_core);
            clear_input(0);
        endtask
        logic [255:0] program_low, program_high, data_line;
        bit data_fill_seen = 0, instruction_fill_seen = 0;
        int selected_port;
        logic [31:0] selected_address;
        initial begin
            reset_all();
            // 运行时装载完整两个 TCM 末尾 bank，保留全部 RAM 地址与写掩码。
            data_line = 256'h0123456789abcdef_fedcba9876543210_1111222233334444_aaaabbbbccccdddd;
            write_line(32'h0100ffe0, data_line, '1);
            read_line(32'h0100ffe0, data_line);
            write_line(32'h0110ffe0, data_line, '1);
            write_line(32'h0110ffe0, '0, 32'h55555555);
            for (int b = 0; b < 32; b += 2) data_line[b*8 +: 8] = 0;
            read_line(32'h0110ffe0, data_line);
            // addi+slli 在 RV64 也形成零扩展的物理 DDR 地址，避免 LUI 的符号扩展。
            program_low = {32'h01f31313,32'h00100313,32'h00120293,32'h0001a203,
                           32'h0021a023,32'h00108113,32'h02a00093,32'h011001b7};
            program_high = {32'h00000013,32'h00000013,32'h00000013,32'h00000013,
                            32'h00000013,32'h00030067,32'h00138413,32'h00032383};
            write_line(32'h01000000, program_low, '1);
            write_line(32'h01000020, program_high, '1);
            read_line(32'h01000000, program_low);
            reset_all();
            // DDR 数据 miss 与跳转后的指令 miss 各经真实 Cache/AXI；返回32B完整行。
            data_line = {32'h00000013,32'h00000013,32'h00000013,32'h00000013,
                         32'h00000013,32'h00000013,32'h0000006f,32'h04d00493};
            // 分支改向前已接纳的 ROM 推测读也必须排空，不能只服务 PC0/PC4 就等待 D 口。
            for (int transaction = 0; transaction < 64 && !x9_seen; transaction++) begin
                while (!(|{dut.g_hot.outputs.cpu_request[0].ar_valid, dut.g_hot.outputs.cpu_request[1].ar_valid}) && !x9_seen)
                    @(negedge clk_core);
                if (x9_seen) break;
                selected_port = dut.g_hot.outputs.cpu_request[1].ar_valid ? 1 : 0;
                selected_address = dut.g_hot.outputs.cpu_request[selected_port].ar.addr;
                if (selected_port == 0 && selected_address < 32'h4000) begin
                    answer_cpu(0, selected_address, selected_address < 32 ?
                        {32'h00000013,32'h00000013,32'h00000013,32'h00000013,
                         32'h00000013,32'h00000013,32'h00028067,32'h010002b7} : {8{32'h00000013}});
                end else begin
                    assert (selected_address == 32'h80000000 || selected_address == 32'h80000020)
                        else $fatal(1, "H1 unexpected CPU request %h", selected_address);
                    if (selected_port == 1) data_fill_seen = 1;
                    else instruction_fill_seen = 1;
                    answer_cpu(selected_port, selected_address, data_line);
                end
            end
            repeat (300) @(negedge clk_core);
            assert (x2_seen && x5_seen && x9_seen && store_seen && data_fill_seen && instruction_fill_seen)
                else $fatal(1, "H1 runtime program/TCM load-store/cache execution failed");
            $display("PASS tb_pango_measure_top layer=1 xlen=%0d tcm_end_banks=2 masked_write=1 short_program=1 dcache_fill=1 icache_fill=1", XLEN);
            $finish;
        end
    end else begin : g_soc_test
        sys_drive_t value;
        sys_observe_t result;
        ddr_drive_t ddr_value;
        periph_drive_t periph_value;
        periph_observe_t periph_result;
        axi_req_t ddr_result;
        logic [4095:0] captured;
        int aw_count = 0, w_count = 0, ar_count = 0, flash_edges = 0;
        logic previous_sck = 0;
        always @(posedge clk_sys) begin
            if (!dut.rst_sys) begin
                if (dut.g_soc.sys_drive.external_request.aw_valid && dut.g_soc.sys_observe.external_response.aw_ready) aw_count++;
                if (dut.g_soc.sys_drive.external_request.w_valid && dut.g_soc.sys_observe.external_response.w_ready) w_count++;
                if (dut.g_soc.sys_drive.external_request.ar_valid && dut.g_soc.sys_observe.external_response.ar_ready) ar_count++;
                if (!dut.g_soc.sys_observe.flash_cs_n && dut.g_soc.sys_observe.flash_sck && !previous_sck) flash_edges++;
                previous_sck = dut.g_soc.sys_observe.flash_sck;
            end
        end
        task automatic write_system(input logic [31:0] address, input logic [2:0] size,
                                    input logic [255:0] data, input logic [31:0] strb);
            int old_aw, old_w;
            $display("MEASURE_STEP H2 write %h", address);
            old_aw = aw_count; old_w = w_count;
            value = '0; value.external_request.aw_valid = 1;
            value.external_request.aw = '{id:1, addr:address, size:size, burst:1, default:'0};
            load_input(1, 4096'(value), $bits(value));
            while (!dut.g_soc.sys_observe.external_response.aw_ready) @(negedge clk_sys);
            clear_input(1);
            value = '0; value.external_request.w_valid = 1;
            value.external_request.w = '{data:data, strb:strb, last:1};
            load_input(1, 4096'(value), $bits(value));
            while (!dut.g_soc.sys_observe.external_response.w_ready) @(negedge clk_sys);
            clear_input(1);
            while (!dut.g_soc.sys_observe.external_response.b_valid) @(negedge clk_sys);
            read_output(1, $bits(result), captured);
            result = sys_observe_t'(captured);
            assert (result.external_response.b_valid && result.external_response.b.id == 1 && result.external_response.b.resp == AXI_OKAY)
                else $fatal(1, "H2 AXI write response mismatch addr=%h", address);
            value = '0; value.external_request.b_ready = 1;
            load_input(1, 4096'(value), $bits(value)); clear_input(1);
            assert (aw_count == old_aw+1 && w_count == old_w+1)
                else $fatal(1, "H2 scan duplicated a write transaction");
        endtask
        task automatic start_read(input logic [31:0] address, input logic [2:0] size);
            int old_ar;
            $display("MEASURE_STEP H2 read %h", address);
            old_ar = ar_count;
            value = '0; value.external_request.ar_valid = 1;
            value.external_request.ar = '{id:2, addr:address, size:size, burst:1, default:'0};
            load_input(1, 4096'(value), $bits(value));
            while (!dut.g_soc.sys_observe.external_response.ar_ready) @(negedge clk_sys);
            clear_input(1);
            assert (ar_count == old_ar+1) else $fatal(1, "H2 scan duplicated a read transaction");
        endtask
        task automatic finish_read(input logic [255:0] expected, input logic [255:0] mask);
            while (!dut.g_soc.sys_observe.external_response.r_valid) @(negedge clk_sys);
            read_output(1, $bits(result), captured);
            result = sys_observe_t'(captured);
            assert (result.external_response.r_valid && result.external_response.r.id == 2 &&
                    result.external_response.r.last && result.external_response.r.resp == AXI_OKAY &&
                    (result.external_response.r.data & mask) == (expected & mask))
                else $fatal(1, "H2 AXI read data/id/error mismatch got=%h expected=%h", result.external_response.r.data, expected);
            value = '0; value.external_request.r_ready = 1;
            load_input(1, 4096'(value), $bits(value)); clear_input(1);
        endtask
        logic [255:0] program_line, pattern;
        axi_a_t request;
        initial begin
            reset_all();
            program_line = {32'h00000013,32'h0000006f,32'h00120293,32'h0001a203,
                            32'h0021a023,32'h00108113,32'h02a00093,32'h011001b7};
            write_system(32'h01000000, 5, program_line, '1);
            start_read(32'h01000000, 5); finish_read(program_line, '1);
            reset_all();
            repeat (1000) @(negedge clk_core);
            assert (x2_seen && x5_seen && store_seen) else $fatal(1, "H2 ROM/TCM program execution failed");
            // 外设域扫描输入经过真实 GPIO 同步器、AXI-Lite 和 CDC 返回 SYS。
            periph_value = '0; periph_value.uart_rx = 2'b11;
            periph_value.gpio_in[0] = 32'h89abcdef;
            periph_value.gpio_in[1] = 32'h01234567;
            periph_value.gpio_in[2] = 32'h55aa33cc;
            load_input(3, 4096'(periph_value), $bits(periph_value));
            start_read(32'h10020000, 2); finish_read(256'h89abcdef, 256'hffffffff);
            start_read(32'h10021000, 2); finish_read(256'h01234567, 256'hffffffff);
            start_read(32'h10022000, 2); finish_read(256'h55aa33cc, 256'hffffffff);
            write_system(32'h10020004, 2, 256'hdeadbeef << 32, 32'hf0);
            write_system(32'h10020008, 2, 256'h55aa55aa << 64, 32'hf00);
            read_output(3, $bits(periph_result), captured);
            periph_result = periph_observe_t'(captured);
            assert (periph_result.gpio_out[0] == 32'hdeadbeef && periph_result.gpio_oe[0] == 32'h55aa55aa &&
                    periph_result.uart_tx == 3)
                else $fatal(1, "H2 peripheral output snapshot mismatch");
            // Flash 不是 DECERR 占位：真实引脚读取完成并产生 SCK。
            start_read(32'h30000000, 2); finish_read('0, 256'hffffffff);
            assert (flash_edges >= 64) else $fatal(1, "H2 Flash window was not retained");
            // NPU 仅保留通用 SRAM 目标端口，测试端模拟响应，不声称存在 NPU 计算单元。
            start_read(32'h20000020, 5);
            while (!dut.g_soc.sys_observe.npu_request.ar_valid) @(negedge clk_sys);
            read_output(1, $bits(result), captured);
            result = sys_observe_t'(captured);
            request = result.npu_request.ar;
            assert (result.npu_request.ar_valid && request.addr == 32'h20000020 && request.id == 14)
                else $fatal(1, "H2 NPU address/ID propagation mismatch");
            value = '0; value.npu_response.ar_ready = 1;
            load_input(1, 4096'(value), $bits(value)); clear_input(1);
            pattern = 256'h0123456789abcdef_fedcba9876543210_1111222233334444_aaaabbbbccccdddd;
            value = '0; value.npu_response.r_valid = 1;
            value.npu_response.r = '{id:request.id, data:pattern, resp:AXI_OKAY, last:1};
            load_input(1, 4096'(value), $bits(value));
            while (!dut.g_soc.sys_observe.npu_request.r_ready) @(negedge clk_sys);
            clear_input(1); finish_read(pattern, '1);
            // DDR 只测 AXI 目标边界及异步FIFO，未实例化硬 DDR PHY。
            ddr_value = '0; ddr_value.ready = 1;
            load_input(2, 4096'(ddr_value), $bits(ddr_value));
            start_read(32'h80000020, 5);
            while (!dut.g_soc.ddr_observe.ar_valid) @(negedge clk_ddr);
            read_output(2, $bits(ddr_result), captured);
            ddr_result = axi_req_t'(captured);
            request = ddr_result.ar;
            assert (ddr_result.ar_valid && request.addr == 32'h80000020 && request.id == 14)
                else $fatal(1, "H2 DDR address/ID propagation mismatch");
            ddr_value = '0; ddr_value.ready = 1; ddr_value.response.ar_ready = 1;
            load_input(2, 4096'(ddr_value), $bits(ddr_value)); clear_input(2);
            ddr_value = '0; ddr_value.ready = 1; ddr_value.response.r_valid = 1;
            ddr_value.response.r = '{id:request.id, data:~pattern, resp:AXI_OKAY, last:1};
            load_input(2, 4096'(ddr_value), $bits(ddr_value));
            while (!dut.g_soc.ddr_observe.r_ready) @(negedge clk_ddr);
            clear_input(2); finish_read(~pattern, '1);
            // H2 Core 域的唯一输入是测量回读位，不干预生产 Core。
            load_input(0, 4096'd1, 1);
            read_output(0, dut.CORE_OUTPUT_BITS, captured);
            assert (captured[$bits(arch_observe_t)]) else $fatal(1, "H2 core scan marker missing");
            $display("PASS tb_pango_measure_top layer=2 xlen=%0d rom_tcm_program=1 tcm_axi=1 gpio_cdc=3 flash_pin_read=1 npu_axi=1 ddr_cdc=1 domains=4", XLEN);
            $finish;
        end
    end
endmodule
