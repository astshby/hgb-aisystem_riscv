// Module: tb_dcache_wb
// Description: Architectural byte scoreboard for writeback, allocation, dirty failures and maintenance.
module tb_dcache_wb #(
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
    import cache_pkg::*;
    localparam xlen_t BASE = xlen_t'(DDR_BASE);
    localparam int BEATS = 32 / DBUS_BYTES, STRIDE = CACHE_BYTES / 2;
    logic clk = 0, rst = 1;
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
    byte unsigned memory [8208], golden [8208];
    logic maint_req_valid = 0, maint_req_ready, maint_rsp_valid, maint_rsp_ready = 0;
    cache_maint_op_e maint_op = CACHE_NONE;
    cache_maint_error_e maint_error, fault_code;
    xlen_t maint_fault_addr, reported_addr;
    logic fault_valid, maint_inflight = 0, fault_writes = 0;
    xlen_t last_fault_addr;
    always_ff @(posedge clk) if (fault_valid) last_fault_addr <= reported_addr;
    int cycles = 0, delay_q = 0, transfers = 0, checks = 0, writes = 0;

    dcache #(.ENABLE(ENABLE), .CACHE_BYTES(CACHE_BYTES), .DDR_BYTES(DDR_BYTES)) dut (.fault_addr(reported_addr), .*);
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
                if (offset+b < DDR_BYTES) result[b*8 +: 8] = golden[offset+b];
        end else result = xlen_t'(32'h12345678);
        return result;
    endfunction

    function automatic xlen_t physical_word(input xlen_t addr);
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

    // 变延迟单事务模型：错误写允许部分副作用，Cache 必须保留尚未完整发布的脏行。
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
                // 回退 Store 保留原 lane/size；写回则按已退休 Store 的独立字节记分板核对。
                if (mem_request.write) begin
                    if (!maint_inflight && request.write &&
                        (mem_request.addr & ~xlen_t'(31)) == (request.addr & ~xlen_t'(31)))
                        assert (mem_request == request) else $fatal(1, "Store fallback changed payload");
                    else assert (mem_request.size == mem_size_e'($clog2(DBUS_BYTES)) &&
                                 mem_request.wstrb == '1 && mem_request.wdata == read_word(mem_request.addr))
                        else $fatal(1, "writeback differs from architectural bytes addr=%h", mem_request.addr);
                end
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
                    mem_response.rdata <= saved_request.write ? '0 : physical_word(saved_request.addr);
                    if (fault_enable && saved_request.addr == fault_addr && saved_request.write == fault_writes &&
                        (!wide_fault_only || saved_request.size == mem_size_e'($clog2(DBUS_BYTES))))
                        mem_response.error <= BUS_SLVERR;
                    if (saved_request.write && decoded_error == BUS_OK && target == TARGET_DDR)
                        for (int b = 0; b < DBUS_BYTES; b++)
                            if (saved_request.wstrb[b] &&
                                (!fault_enable || !fault_writes || saved_request.addr != fault_addr || b % 2 == 0))
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

    task automatic access_data(input xlen_t addr, input bit write, input mem_size_e size,
        input xlen_t data, input logic [DBUS_BYTES-1:0] mask, input bus_error_e error,
        input int expected_transfers);
        int before_count, timeout;
        bus_rsp_t snapshot;
        before_count = transfers;
        timeout = 0;
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
            @(negedge clk);
            timeout++;
            if (timeout > 500) $fatal(1, "D response timeout addr=%h", addr);
        end
        snapshot = response;
        if (write && error == BUS_OK && addr >= BASE && addr < BASE+xlen_t'(DDR_BYTES))
            for (int b = 0; b < DBUS_BYTES; b++)
                if (mask[b]) golden[int'((addr-BASE) & ~xlen_t'(DBUS_BYTES-1))+b] = data[b*8 +: 8];
        assert (response.error == error) else $fatal(1, "D error addr=%h got=%0d want=%0d", addr, response.error, error);
        if (!write && error == BUS_OK)
            assert (response.rdata == read_word(addr))
                else $fatal(1, "D data addr=%h got=%h want=%h", addr, response.rdata, read_word(addr));
        assert (expected_transfers < 0 || transfers-before_count == expected_transfers)
            else $fatal(1, "D transfers addr=%h got=%0d want=%0d", addr, transfers-before_count, expected_transfers);
        repeat (3) begin
            @(negedge clk);
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

    // 维护排队不能截走先前旁路请求的响应；CPU 反压解除后才能借用 D 主端口。
    task automatic maintenance_after_held_response;
        @(negedge clk);
        request = '{write:1'b0, execute:1'b0, size:MEM_WORD, addr:xlen_t'(DTCM_BASE), wdata:'0, wstrb:'0};
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk); req_valid = 0;
        maint_op = CACHE_CLEAN; maint_req_valid = 1; maint_inflight = 1;
        while (!rsp_valid) @(negedge clk);
        repeat (4) begin
            assert (!maint_req_ready && response.rdata == read_word(request.addr))
                else $fatal(1, "maintenance stole held CPU response");
            @(negedge clk);
        end
        rsp_ready = 1;
        @(negedge clk); rsp_ready = 0;
        do @(posedge clk); while (!maint_req_ready);
        @(negedge clk); maint_req_valid = 0;
        while (!maint_rsp_valid) @(negedge clk);
        assert (maint_error == CACHE_OK) else $fatal(1, "queued clean failed");
        maint_rsp_ready = 1;
        @(negedge clk); maint_rsp_ready = 0; maint_inflight = 0;
        checks++;
    endtask

    task automatic maintenance(input cache_maint_op_e op, input cache_maint_error_e expected,
                               input int expected_transfers);
        int count_before, timeout;
        cache_maint_error_e held_error;
        xlen_t held_addr;
        count_before = transfers; timeout = 0;
        @(negedge clk);
        maint_inflight = 1; maint_op = op; maint_req_valid = 1;
        do begin
            @(posedge clk); timeout++;
            if (timeout > 5000) $fatal(1, "maintenance request timeout");
        end while (!maint_req_ready);
        @(negedge clk); maint_req_valid = 0;
        while (!maint_rsp_valid) begin
            @(negedge clk); timeout++;
            if (timeout > 5000) $fatal(1, "maintenance completion timeout");
        end
        assert (maint_error == expected) else $fatal(1, "maintenance error=%0d expected=%0d", maint_error, expected);
        assert (expected_transfers < 0 || transfers-count_before == expected_transfers)
            else $fatal(1, "maintenance transfers=%0d expected=%0d", transfers-count_before, expected_transfers);
        held_error = maint_error; held_addr = maint_fault_addr;
        repeat (3) begin
            @(negedge clk);
            assert (maint_rsp_valid && maint_error == held_error && maint_fault_addr == held_addr)
                else $fatal(1, "maintenance response changed");
        end
        maint_rsp_ready = 1;
        @(negedge clk); maint_rsp_ready = 0; maint_inflight = 0;
        checks++;
    endtask

    initial begin
        for (int b = 0; b < 8208; b++) begin memory[b] = 8'(b*7+3); golden[b] = memory[b]; end
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        load_word(xlen_t'(ITCM_BASE), 1);
        load_word(xlen_t'(DTCM_BASE), 1);
        repeat (3) access_data(xlen_t'(UART0_BASE), 0, MEM_WORD, '0, '0, BUS_OK, 1);
        access_data(BASE+1, 0, MEM_WORD, '0, '0, DDR_BYTES == 0 ? BUS_DECERR : BUS_SLVERR, 1);
        if (XLEN == 64) access_data(BASE | (xlen_t'(1)<<32), 0, MEM_WORD, '0, '0, BUS_DECERR, 1);
        if (!ENABLE || DDR_BYTES == 0) begin
            repeat (3) access_data(BASE, 0, MEM_WORD, '0, '0, DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, 1);
            access_data(BASE, 1, MEM_WORD, xlen_t'(42), DBUS_BYTES'(15), DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, 1);
            maintenance(CACHE_CLEAN, CACHE_OK, 0);
            maintenance(CACHE_INVALIDATE, CACHE_OK, 0);
        end else begin
            load_word(BASE, BEATS);
            for (int b = 0; b < 32; b++) load_word(BASE+xlen_t'(b), 0);
            for (int size = 0; size <= $clog2(DBUS_BYTES); size++)
                for (int lane = 0; lane < DBUS_BYTES; lane += 1<<size) begin
                    access_data(BASE+xlen_t'(lane), 1, mem_size_e'(size), ~xlen_t'(1234+lane+size),
                        DBUS_BYTES'(((1<<(1<<size))-1)<<lane), BUS_OK, 0);
                    load_word(BASE+xlen_t'(lane), 0);
                end
            assert (physical_word(BASE) != read_word(BASE)) else $fatal(1, "write hit unexpectedly wrote through");
            maintenance(CACHE_INVALIDATE, CACHE_DIRTY_ERROR, 0);
            load_word(BASE, 0);
            maintenance(CACHE_CLEAN, CACHE_OK, BEATS);
            assert (physical_word(BASE) == read_word(BASE)) else $fatal(1, "clean did not publish dirty bytes");
            load_word(BASE, 0);
            maintenance(CACHE_CLEAN, CACHE_OK, 0);
            access_data(BASE, 1, MEM_WORD, '1, '0, BUS_OK, 0);
            maintenance(CACHE_CLEAN, CACHE_OK, 0);
            // 写缺失先读行，再合并；不写 DDR，邻近未覆盖字节必须保留。
            access_data(BASE+64+1, 1, MEM_BYTE, xlen_t'(32'h0000ab00), DBUS_BYTES'(2), BUS_OK, BEATS);
            load_word(BASE+64, 0);
            maintenance(CACHE_FLUSH, CACHE_OK, BEATS);
            load_word(BASE+64, BEATS);
            maintenance(CACHE_INVALIDATE, CACHE_OK, 0);
            for (int beat = 0; beat < BEATS; beat++) begin
                maintenance(CACHE_FLUSH, CACHE_OK, -1);
                access_data(BASE, 1, MEM_WORD, xlen_t'(111+beat), DBUS_BYTES'(15), BUS_OK, BEATS);
                load_word(BASE+xlen_t'(STRIDE), BEATS);
                fault_enable = 1; fault_writes = 1; fault_addr = BASE+xlen_t'(beat*DBUS_BYTES);
                access_data(BASE+xlen_t'(2*STRIDE), 1'(beat), MEM_BYTE, xlen_t'(8'hab), DBUS_BYTES'(1), BUS_SLVERR, beat+1);
                assert (last_fault_addr == fault_addr) else $fatal(1, "wrong eviction fault address");
                fault_enable = 0;
                load_word(BASE, 0); // 写回失败仍保有脏行，不把已退休数据丢掉。
                load_word(BASE+xlen_t'(STRIDE), 0);
                load_word(BASE+xlen_t'(2*STRIDE), 2*BEATS);
                assert (physical_word(BASE) == read_word(BASE)) else $fatal(1, "eviction retry lost bytes");
            end
            for (int beat = 0; beat < BEATS; beat++) begin
                maintenance(CACHE_FLUSH, CACHE_OK, -1);
                access_data(BASE, 1, MEM_WORD, xlen_t'(222+beat), DBUS_BYTES'(15), BUS_OK, BEATS);
                fault_enable = 1; fault_writes = 1; fault_addr = BASE+xlen_t'(beat*DBUS_BYTES);
                maintenance(CACHE_CLEAN, CACHE_WRITEBACK_ERROR, beat+1);
                assert (maint_fault_addr == fault_addr) else $fatal(1, "wrong clean fault address");
                fault_enable = 0;
                load_word(BASE, 0);
                maintenance(CACHE_CLEAN, CACHE_OK, BEATS);
            end
            for (int beat = 0; beat < BEATS; beat++) begin
                maintenance(CACHE_FLUSH, CACHE_OK, -1);
                fault_enable = 1; fault_writes = 0; fault_addr = BASE+xlen_t'(beat*DBUS_BYTES);
                access_data(BASE+xlen_t'(DBUS_BYTES), 0, MEM_BYTE, '0, '0,
                            beat == 1 ? BUS_SLVERR : BUS_OK, beat+2);
                fault_enable = 0;
                load_word(BASE, BEATS);
                maintenance(CACHE_FLUSH, CACHE_OK, 0);
                fault_enable = 1;
                access_data(BASE+1, 1, MEM_BYTE, xlen_t'(32'h00005500), DBUS_BYTES'(2), BUS_OK, beat+2);
                fault_enable = 0;
                load_word(BASE, BEATS); // 写分配失败只能回退一次原 Store，不能安装部分行。
            end
            maintenance(CACHE_FLUSH, CACHE_OK, 0);
            fault_enable = 1; fault_writes = 0; wide_fault_only = 1; fault_addr = BASE;
            load_word(BASE, 2);
            fault_enable = 0; wide_fault_only = 0;
            load_word(BASE, BEATS);
            load_word(BASE+xlen_t'(DDR_BYTES-4), 1);
            // 可重复混合访问跨组与同组冲突；整行写回和字节合并由独立黄金内存核对。
            for (int n = 0; n < 96; n++) begin
                xlen_t addr;
                int lane;
                lane = n % DBUS_BYTES;
                addr = BASE+xlen_t'(((n*7)%4)*STRIDE+((n*11)%2)*32+lane);
                access_data(addr, 1, MEM_BYTE, xlen_t'(n+97) << (lane*8),
                            DBUS_BYTES'(1 << lane), BUS_OK, -1);
                load_word(addr, 0);
            end
            maintenance(CACHE_FLUSH, CACHE_OK, -1);
            for (int b = 0; b < DDR_BYTES; b++)
                assert (memory[b] == golden[b]) else $fatal(1, "final memory mismatch byte=%0d", b);
            maintenance(CACHE_FLUSH, CACHE_OK, 0);
        end
        bypass_handoff();
        maintenance_after_held_response();
        // 全局 reset 可丢失脏数据，因此测试先 flush，再协调复位在途协议。
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
        $display("PASS tb_dcache_wb XLEN=%0d enabled=%0d bytes=%0d ddr=%0d checks=%0d", XLEN, ENABLE, CACHE_BYTES, DDR_BYTES, checks);
        $finish;
    end
    initial begin #4000000; $fatal(1, "WB cache watchdog"); end
endmodule
