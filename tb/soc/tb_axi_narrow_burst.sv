// Module: tb_axi_narrow_burst
// Description: Byte-addressed AXI INCR reference checking independent of the target's strobe arithmetic.
module tb_axi_narrow_burst;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    localparam int MEMORY_BYTES = 1024;
    logic clk = 0, rst = 1;
    axi_req_t axi_req = '0;
    axi_rsp_t axi_rsp;
    bus_req_t request;
    bus_rsp_t response;
    logic req_valid, req_ready, rsp_valid, rsp_ready, pending_q = 0;
    byte unsigned actual [MEMORY_BYTES], expected [MEMORY_BYTES];
    int cycles = 0, delay_q = 0, cases = 0, checked_bytes = 0;
    int local_writes = 0, local_reads = 0;
    always #5 clk = ~clk;
    axi_bus_target dut (.*);
    assign req_ready = !rst && !pending_q && cycles % 5 != 0;
    assign rsp_valid = pending_q && delay_q == 0;

    // 参考存储只按接收到的地址与逐字节使能更新，不使用DUT的beat计数或掩码。
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 100000) $fatal(1, "AXI narrow burst timeout");
        if (rst) begin
            pending_q <= 0;
            delay_q <= 0;
            response <= '0;
        end else begin
            if (delay_q != 0) delay_q <= delay_q - 1;
            if (rsp_valid && rsp_ready) pending_q <= 0;
            if (req_valid && req_ready) begin
                assert (request.addr < MEMORY_BYTES) else $fatal(1, "local address outside model");
                pending_q <= 1;
                delay_q <= 1 + cycles % 3;
                response.error <= BUS_OK;
                for (int lane = 0; lane < DBUS_BYTES; lane++) begin
                    response.rdata[8*lane +: 8] <= actual[(int'(request.addr) / DBUS_BYTES)*DBUS_BYTES + lane];
                    if (request.write && request.wstrb[lane])
                        actual[(int'(request.addr) / DBUS_BYTES)*DBUS_BYTES + lane] = request.wdata[8*lane +: 8];
                end
                if (request.write) local_writes++;
                else local_reads++;
            end
        end
    end

    task automatic send_aw(input int address, size, beats);
        @(negedge clk);
        axi_req.aw_valid = 1;
        axi_req.aw = '{id:axi_id_t'(cases), addr:32'(address), len:8'(beats-1),
                      size:3'(size), burst:2'b01, default:'0};
        do @(posedge clk); while (!axi_rsp.aw_ready);
        @(negedge clk); axi_req.aw_valid = 0;
    endtask

    task automatic send_w(input int address, size, beat, beats, mode);
        int current_address, first_lane;
        logic bad_beat;
        current_address = address + beat * (1 << size);
        first_lane = current_address % AXI_BYTES;
        bad_beat = (mode == 3 || mode == 4) && beat == 1;
        @(negedge clk);
        axi_req.w = '0;
        axi_req.w.last = (beat == beats-1) ^ (mode == 4 && beat == 1);
        for (int lane = 0; lane < AXI_BYTES; lane++)
            axi_req.w.data[8*lane +: 8] = 8'(cases*17 + beat*13 + lane);
        for (int byte_no = 0; byte_no < (1 << size); byte_no++) begin
            if ((mode != 1 || (byte_no+beat)%2 == 0) && (mode != 2 || beat%2 == 0)) begin
                axi_req.w.strb[first_lane+byte_no] = 1;
                if (!bad_beat)
                    expected[current_address+byte_no] = axi_req.w.data[8*(first_lane+byte_no) +: 8];
            end
        end
        if (mode == 3 && beat == 1) axi_req.w.strb[first_lane ^ 16] = 1;
        axi_req.w_valid = 1;
        do @(posedge clk); while (!axi_rsp.w_ready);
        @(negedge clk); axi_req.w_valid = 0;
    endtask

    task automatic write_case(input int address, size, beats, mode, input bit data_first);
        axi_b_t held;
        if (data_first) begin
            send_w(address, size, 0, beats, mode);
            repeat (3) @(negedge clk);
            send_aw(address, size, beats);
        end else send_aw(address, size, beats);
        for (int beat = data_first ? 1 : 0; beat < beats; beat++)
            send_w(address, size, beat, beats, mode);
        while (!axi_rsp.b_valid) @(negedge clk);
        held = axi_rsp.b;
        assert (held.id == axi_id_t'(cases) && held.resp == ((mode == 3 || mode == 4) ? AXI_SLVERR : AXI_OKAY))
            else $fatal(1, "narrow B case=%0d size=%0d addr=%h response=%0d", cases, size, address, held.resp);
        repeat (7) begin
            @(negedge clk);
            assert (axi_rsp.b_valid && axi_rsp.b == held) else $fatal(1, "B changed during backpressure");
        end
        for (int address_byte = 0; address_byte < MEMORY_BYTES; address_byte++) begin
            assert (actual[address_byte] == expected[address_byte])
                else $fatal(1, "byte mismatch case=%0d address=%h actual=%h expected=%h",
                            cases, address_byte, actual[address_byte], expected[address_byte]);
            checked_bytes++;
        end
        axi_req.b_ready = 1;
        @(posedge clk); @(negedge clk); axi_req.b_ready = 0;
        cases++;
    endtask

    task automatic read_back;
        axi_r_t held;
        @(negedge clk);
        axi_req.ar_valid = 1;
        axi_req.ar = '{id:4'd9, addr:32'h100, len:8'd7, size:3'd5, burst:2'b01, default:'0};
        do @(posedge clk); while (!axi_rsp.ar_ready);
        @(negedge clk); axi_req.ar_valid = 0;
        for (int beat = 0; beat < 8; beat++) begin
            while (!axi_rsp.r_valid) @(negedge clk);
            held = axi_rsp.r;
            assert (held.id == 9 && held.resp == AXI_OKAY && held.last == (beat == 7))
                else $fatal(1, "read response frame");
            for (int lane = 0; lane < AXI_BYTES; lane++)
                assert (held.data[8*lane +: 8] == expected[256 + beat*AXI_BYTES + lane])
                    else $fatal(1, "AXI readback mismatch beat=%0d lane=%0d", beat, lane);
            repeat (3) begin
                @(negedge clk);
                assert (axi_rsp.r_valid && axi_rsp.r == held) else $fatal(1, "R changed during backpressure");
            end
            axi_req.r_ready = 1;
            @(posedge clk); @(negedge clk); axi_req.r_ready = 0;
        end
    endtask

    initial begin
        for (int address_byte = 0; address_byte < MEMORY_BYTES; address_byte++) begin
            actual[address_byte] = 8'(address_byte ^ 8'hb7);
            expected[address_byte] = actual[address_byte];
        end
        repeat (5) @(negedge clk);
        rst = 0;
        for (int size = 0; size <= 5; size++)
            for (int mode = 0; mode < 5; mode++)
                if (!(size == 5 && mode == 3))
                    for (int ordering = 0; ordering < 2; ordering++)
                        write_case(256 + 32 - (1 << size), size, 4, mode, 1'(ordering));
        read_back();
        $display("PASS AXI independent INCR bytes RV%0d cases=%0d checked_bytes=%0d local_reads=%0d local_writes=%0d",
                 XLEN, cases, checked_bytes, local_reads, local_writes);
        $finish;
    end
endmodule
