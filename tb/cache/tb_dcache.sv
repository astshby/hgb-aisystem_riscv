// Module: tb_dcache
// Description: Independent byte-memory scoreboard for WT/NWA, errors, maintenance and bypass.
module tb_dcache #(
    parameter bit ENABLE = 1'b1,
    parameter int CACHE_BYTES = 128,
    parameter int DDR_BYTES = 8204
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    localparam xlen_t BASE = xlen_t'(DDR_BASE);
    localparam int BEATS = 32 / DBUS_BYTES, STRIDE = CACHE_BYTES / 2;
    logic clk = 0, rst = 1, invalidate = 0;
    always #5 clk = ~clk;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
    bus_req_t request = '0;
    bus_rsp_t response;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    bus_req_t mem_request, saved_request;
    bus_rsp_t mem_response = '0;
    bus_target_e target;
    bus_error_e decoded_error;
    logic pending = 0, fault_enable = 0, wide_fault_only = 0;
    xlen_t fault_addr;
    byte unsigned memory [8208];
    int cycles = 0, delay_q = 0, transfers = 0, checks = 0, writes = 0;

    dcache #(.ENABLE(ENABLE), .CACHE_BYTES(CACHE_BYTES), .DDR_BYTES(DDR_BYTES)) dut (.*);
    address_decode #(.DDR_BYTES(DDR_BYTES)) decoder (
        .request(saved_request), .target, .error(decoded_error)
    );
    function automatic xlen_t read_word(input xlen_t addr);
        xlen_t result;
        int offset;
        result = '0;
        offset = int'((addr-BASE) & ~xlen_t'(DBUS_BYTES-1));
        if (addr >= BASE && addr < BASE+xlen_t'(DDR_BYTES)) begin
            for (int b = 0; b < DBUS_BYTES; b++)
                if (offset+b < DDR_BYTES) result[b*8 +: 8] = memory[offset+b];
        end else result = xlen_t'(32'h12345678);
        return result;
    endfunction

    // 变延迟单事务模型：错误写允许产生部分副作用，Cache 必须失效旧命中行。
    assign mem_req_ready = !rst && !pending && (!mem_rsp_valid || mem_rsp_ready) && cycles % 3 != 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 0;
            mem_rsp_valid <= 0;
            cycles <= 0;
            transfers <= 0;
            writes <= 0;
        end else begin
            cycles <= cycles + 1;
            if (mem_rsp_valid && mem_rsp_ready) mem_rsp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                // 写穿透必须原样下传，不允许 Cache 与内存模型共同掩盖错误的 lane/size。
                assert (request.write ? mem_request == request : !mem_request.write)
                    else $fatal(1, "D-cache changed original Store payload");
                saved_request <= mem_request;
                pending <= 1;
                delay_q <= 2 + transfers % 4;
                transfers <= transfers + 1;
                if (mem_request.write) writes <= writes + 1;
            end
            if (pending) begin
                if (delay_q != 0) delay_q <= delay_q - 1;
                else begin
                    pending <= 0;
                    mem_rsp_valid <= 1;
                    mem_response.error <= decoded_error;
                    mem_response.rdata <= saved_request.write ? '0 : read_word(saved_request.addr);
                    if (fault_enable && saved_request.addr == fault_addr &&
                        (!wide_fault_only || saved_request.size == mem_size_e'($clog2(DBUS_BYTES))))
                        mem_response.error <= BUS_SLVERR;
                    if (saved_request.write && decoded_error == BUS_OK && target == TARGET_DDR)
                        for (int b = 0; b < DBUS_BYTES; b++)
                            if (saved_request.wstrb[b] &&
                                (!fault_enable || saved_request.addr != fault_addr || b % 2 == 0))
                                memory[int'((saved_request.addr-BASE) & ~xlen_t'(DBUS_BYTES-1))+b] <=
                                    saved_request.wdata[b*8 +: 8];
                end
            end
            if (pending && saved_request.write)
                assert (!rsp_valid) else $fatal(1, "Store acknowledged before lower response");
        end
    end

    bus_req_t held_request;
    logic held = 0;
    always_ff @(posedge clk) begin
        if (rst) held <= 0;
        else begin
            if (held) assert (mem_req_valid && mem_request == held_request)
                else $fatal(1, "unstable lower request");
            held <= mem_req_valid && !mem_req_ready;
            held_request <= mem_request;
        end
    end

    task automatic clear_cache;
        @(negedge clk); invalidate = 1;
        @(negedge clk); invalidate = 0;
    endtask
    task automatic access_data(input xlen_t addr, input bit write, input mem_size_e size,
        input xlen_t data, input logic [DBUS_BYTES-1:0] mask, input bus_error_e error,
        input int expected_transfers, input int invalidate_beat = -1, input bit invalidate_held = 0);
        int before_count, timeout;
        bit injected;
        bus_rsp_t snapshot;
        before_count = transfers;
        timeout = 0;
        injected = 0;
        @(negedge clk);
        request = '{write:write, execute:1'b0, size:size, addr:addr, wdata:data, wstrb:mask};
        req_valid = 1;
        rsp_ready = 0;
        do begin
            @(posedge clk);
            timeout++;
            if (timeout > 500) $fatal(1, "D request timeout");
        end while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        while (!rsp_valid) begin
            invalidate = !injected && invalidate_beat >= 0 &&
                         ((invalidate_beat < BEATS && mem_rsp_valid && transfers == before_count+invalidate_beat+1) ||
                          (invalidate_beat == BEATS && dut.fill_done));
            if (invalidate) injected = 1;
            @(negedge clk);
            timeout++;
            if (timeout > 500) $fatal(1, "D response timeout addr=%h", addr);
        end
        invalidate = 0;
        snapshot = response;
        assert (response.error == error) else $fatal(1, "D error addr=%h got=%0d want=%0d", addr, response.error, error);
        if (!write && error == BUS_OK)
            assert (response.rdata == read_word(addr))
                else $fatal(1, "D data addr=%h got=%h want=%h", addr, response.rdata, read_word(addr));
        assert (transfers-before_count == expected_transfers)
            else $fatal(1, "D transfers addr=%h got=%0d want=%0d", addr, transfers-before_count, expected_transfers);
        if (invalidate_beat >= 0) assert (injected) else $fatal(1, "missed D invalidation");
        invalidate = invalidate_held;
        repeat (3) begin
            @(negedge clk);
            invalidate = 0;
            assert (rsp_valid && response == snapshot) else $fatal(1, "unstable D held response");
        end
        rsp_ready = 1;
        @(negedge clk);
        rsp_ready = 0;
        assert (!rsp_valid) else $fatal(1, "duplicate D response");
        checks++;
    endtask
    task automatic load_word(input xlen_t addr, input int beats);
        access_data(addr, 0, MEM_BYTE, '0, '0, BUS_OK, beats);
    endtask

    // D 旁路保留响应消费与下一请求接受同沿交接，不能强加一个 LOOKUP 空拍。
    task automatic bypass_handoff;
        @(negedge clk);
        request = '{write:1'b0, execute:1'b0, size:MEM_WORD, addr:xlen_t'(DTCM_BASE), wdata:'0, wstrb:'0};
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk); req_valid = 0;
        while (!rsp_valid || !mem_req_ready) @(negedge clk);
        request.addr = xlen_t'(DTCM_BASE+4);
        req_valid = 1; rsp_ready = 1;
        @(posedge clk);
        assert (req_ready && rsp_valid && mem_req_valid) else $fatal(1, "D bypass handoff inserted bubble");
        @(negedge clk); req_valid = 0; rsp_ready = 0;
        while (!rsp_valid) @(negedge clk);
        assert (response.error == BUS_OK && response.rdata == read_word(request.addr))
            else $fatal(1, "D bypass response ownership");
        rsp_ready = 1;
        @(negedge clk); rsp_ready = 0;
        checks += 2;
    endtask

    initial begin
        for (int b = 0; b < 8208; b++) memory[b] = 8'(b*7+3);
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        load_word(xlen_t'(ITCM_BASE), 1);
        load_word(xlen_t'(DTCM_BASE), 1);
        // MMIO 不分配，重复读取必须每次都访问下层，不吞设备副作用。
        repeat (3) access_data(xlen_t'(UART0_BASE), 0, MEM_WORD, '0, '0, BUS_OK, 1);
        access_data(BASE+1, 0, MEM_WORD, '0, '0, DDR_BYTES == 0 ? BUS_DECERR : BUS_SLVERR, 1);
        if (XLEN == 64) access_data(BASE | (xlen_t'(1)<<32), 0, MEM_WORD, '0, '0, BUS_DECERR, 1);
        if (!ENABLE || DDR_BYTES == 0) begin
            repeat (3) access_data(BASE, 0, MEM_WORD, '0, '0, DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, 1);
            access_data(BASE, 1, MEM_WORD, xlen_t'(32'hdeadbeef), DBUS_BYTES'(15),
                        DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, 1);
        end else begin
            load_word(BASE, BEATS);
            for (int b = 0; b < 32; b++) load_word(BASE+xlen_t'(b), 0);
            // 全部合法宽度与所有 byte lane；每次 Store 后从缓存验证合并结果。
            for (int size = 0; size <= $clog2(DBUS_BYTES); size++)
                for (int lane = 0; lane < DBUS_BYTES; lane += 1<<size) begin
                    access_data(BASE+xlen_t'(lane), 1, mem_size_e'(size),
                        ~xlen_t'(32'h12345678 + 31*lane + size),
                        DBUS_BYTES'(((1<<(1<<size))-1)<<lane), BUS_OK, 1);
                    load_word(BASE+xlen_t'(lane), 0);
                end
            access_data(BASE, 1, MEM_WORD, '1, '0, BUS_OK, 1);
            load_word(BASE, 0);
            access_data(BASE+64, 1, MEM_WORD, xlen_t'(42), DBUS_BYTES'(15), BUS_OK, 1);
            load_word(BASE+64, BEATS); // 写缺失不分配，也不能触发读填充。
            load_word(BASE, 0);
            clear_cache();
            load_word(BASE, BEATS);
            load_word(BASE+xlen_t'(STRIDE), BEATS);
            load_word(BASE, 0);
            load_word(BASE+xlen_t'(2*STRIDE), BEATS);
            load_word(BASE, 0);
            load_word(BASE+xlen_t'(STRIDE), BEATS);
            load_word(BASE+xlen_t'(DDR_BYTES-4), 1);
            access_data(BASE+xlen_t'(DDR_BYTES), 0, MEM_BYTE, '0, '0, BUS_DECERR, 1);
            for (int beat = 0; beat < BEATS; beat++) begin
                clear_cache();
                fault_enable = 1;
                fault_addr = BASE+xlen_t'(beat*DBUS_BYTES);
                access_data(BASE+xlen_t'(DBUS_BYTES), 0, MEM_BYTE, '0, '0,
                            beat == 1 ? BUS_SLVERR : BUS_OK, beat+2);
                fault_enable = 0;
                load_word(BASE, BEATS);
            end
            clear_cache();
            fault_enable = 1; wide_fault_only = 1; fault_addr = BASE;
            load_word(BASE, 2); // 扩宽读取报错，原始 BYTE 读取成功。
            fault_enable = 0; wide_fault_only = 0;
            load_word(BASE, BEATS);
            fault_enable = 1; fault_addr = BASE;
            access_data(BASE, 1, mem_size_e'($clog2(DBUS_BYTES)), '1, '1, BUS_SLVERR, 1);
            fault_enable = 0;
            load_word(BASE, BEATS); // 写错误后的部分副作用不能被旧缓存遮盖。
            for (int beat = 0; beat <= BEATS; beat++) begin
                clear_cache();
                access_data(BASE+3, 0, MEM_BYTE, '0, '0, BUS_OK, BEATS, beat);
                load_word(BASE, BEATS);
            end
            access_data(BASE, 1, MEM_WORD, '0, DBUS_BYTES'(15), BUS_OK, 1, 0);
            load_word(BASE, BEATS);
            access_data(BASE, 0, MEM_BYTE, '0, '0, BUS_OK, 0, -1, 1);
            load_word(BASE, BEATS);
        end
        bypass_handoff();
        // 协调复位在途事务，数据阵列不复位；复位后的同地址必须重新 miss。
        @(negedge clk);
        request = '{write:1'b0, execute:1'b0, size:MEM_WORD, addr:BASE+128, wdata:'0, wstrb:'0};
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk); req_valid = 0;
        while (!pending) @(negedge clk);
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        access_data(BASE+128, 0, MEM_WORD, '0, '0, DDR_BYTES == 0 ? BUS_DECERR : BUS_OK,
                    ENABLE && DDR_BYTES != 0 ? BEATS : 1);
        $display("PASS tb_dcache XLEN=%0d enabled=%0d bytes=%0d ddr=%0d checks=%0d", XLEN, ENABLE, CACHE_BYTES, DDR_BYTES, checks);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "D-cache watchdog");
    end
endmodule
