// Module: tb_icache
// Description: Directed cache protocol, replacement, error and invalidation tests.
module tb_icache #(
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
    logic clk = 0, rst = 1, invalidate = 0;
    always #5 clk = ~clk;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
    bus_req_t request = '0;
    bus_rsp_t response;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    bus_req_t mem_request, saved_request;
    bus_rsp_t mem_response = '0;
    bus_target_e decoded_target;
    bus_error_e decoded_error;
    logic pending = 0, fault_enable = 0;
    xlen_t fault_addr;
    int delay_q = 0, cycles = 0, reads = 0, checks = 0;
    localparam xlen_t BASE = xlen_t'(DDR_BASE);
    localparam int STRIDE = CACHE_BYTES / 2;

    icache #(.ENABLE(ENABLE), .CACHE_BYTES(CACHE_BYTES), .DDR_BYTES(DDR_BYTES)) dut (.*);
    address_decode #(.DDR_BYTES(DDR_BYTES)) decoder (
        .request(saved_request), .target(decoded_target), .error(decoded_error)
    );
    function automatic logic [31:0] word_at(input xlen_t addr);
        return 32'h5ac00000 ^ (32'(addr) & 32'hfffffffc);
    endfunction

    // 单笔变延迟存储器：全总线字返回，RV64 上下半字不同，禁止靠低半字侥幸通过。
    assign mem_req_ready = !rst && !pending && (!mem_rsp_valid || mem_rsp_ready) && cycles % 3 != 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 0;
            mem_rsp_valid <= 0;
            cycles <= 0;
            reads <= 0;
        end else begin
            cycles <= cycles + 1;
            if (mem_rsp_valid && mem_rsp_ready) mem_rsp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                saved_request <= mem_request;
                pending <= 1;
                delay_q <= 1 + reads % 4;
                reads <= reads + 1;
                assert (mem_request.size == MEM_WORD && mem_request.execute && !mem_request.write)
                    else $fatal(1, "refill changed fetch attributes");
            end
            if (pending) begin
                if (delay_q != 0) delay_q <= delay_q - 1;
                else begin
                    pending <= 0;
                    mem_rsp_valid <= 1;
                    mem_response.error <= fault_enable && saved_request.addr == fault_addr ?
                                          BUS_SLVERR : decoded_error;
                    for (int lane = 0; lane < DBUS_BYTES / 4; lane++)
                        mem_response.rdata[lane*32 +: 32] <= word_at(
                            (saved_request.addr & ~xlen_t'(DBUS_BYTES-1)) + xlen_t'(lane*4));
                end
            end
        end
    end

    // 请求被反压时地址/属性必须保持；本模型总会在有限周期内接受请求。
    bus_req_t held_request;
    logic held = 0;
    always_ff @(posedge clk) begin
        if (rst) held <= 0;
        else begin
            if (held) assert (mem_req_valid && mem_request == held_request)
                else $fatal(1, "lower request changed before acceptance");
            held <= mem_req_valid && !mem_req_ready;
            held_request <= mem_request;
        end
    end

    task automatic clear_cache;
        @(negedge clk);
        invalidate = 1;
        @(negedge clk);
        invalidate = 0;
    endtask

    // invalidate_beat 在指定填行响应被消费前拉高，覆盖最后一拍与安装冲突。
    task automatic fetch(input xlen_t addr, input bus_error_e error, input int expected_reads,
                         input int invalidate_beat = -1, input bit invalidate_held = 0);
        int before_reads, timeout;
        bit invalidated;
        bus_rsp_t snapshot;
        before_reads = reads;
        invalidated = 0;
        @(negedge clk);
        request = '0;
        request.addr = addr;
        request.size = MEM_WORD;
        request.execute = 1;
        req_valid = 1;
        rsp_ready = 0;
        timeout = 0;
        do begin
            @(posedge clk);
            timeout++;
            if (timeout > 500) $fatal(1, "request timeout %h", addr);
        end while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        while (!rsp_valid) begin
            invalidate = !invalidated && invalidate_beat >= 0 &&
                         ((invalidate_beat < 8 && mem_rsp_valid && reads == before_reads + invalidate_beat + 1) ||
                          (invalidate_beat == 8 && dut.fill_done));
            if (invalidate) invalidated = 1;
            @(negedge clk);
            timeout++;
            if (timeout > 500) $fatal(1, "response timeout %h", addr);
        end
        invalidate = 0;
        snapshot = response;
        assert (response.error == error) else $fatal(1, "error addr=%h got=%d expected=%d", addr, response.error, error);
        if (error == BUS_OK)
            assert (32'(response.rdata >> (8 * int'(addr & xlen_t'(DBUS_BYTES-1)))) == word_at(addr))
                else $fatal(1, "bad data addr=%h data=%h", addr, response.rdata);
        assert (reads - before_reads == expected_reads)
            else $fatal(1, "read count addr=%h got=%0d expected=%0d", addr, reads-before_reads, expected_reads);
        if (invalidate_beat >= 0) assert (invalidated) else $fatal(1, "missed invalidate injection");
        // CPU 反压期间响应必须稳定，失效不能撤回已经给出的响应。
        invalidate = invalidate_held;
        repeat (3) begin
            @(negedge clk);
            invalidate = 0;
            assert (rsp_valid && response == snapshot) else $fatal(1, "unstable held response");
        end
        rsp_ready = 1;
        @(negedge clk);
        rsp_ready = 0;
        assert (!rsp_valid) else $fatal(1, "duplicate response");
        checks++;
    endtask

    // 旁路旧响应与下一请求同沿交接，验证 Cache 没有给 TCM 强加空拍。
    task automatic bypass_handoff;
        @(negedge clk);
        request = '0;
        request.addr = xlen_t'(ITCM_BASE);
        request.execute = 1;
        request.size = MEM_WORD;
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        while (!rsp_valid || !mem_req_ready) @(negedge clk);
        request.addr = xlen_t'(ITCM_BASE+4);
        req_valid = 1;
        rsp_ready = 1;
        @(posedge clk);
        assert (req_ready && rsp_valid && mem_req_valid)
            else $fatal(1, "uncached handoff inserted a bubble");
        @(negedge clk);
        req_valid = 0;
        rsp_ready = 0;
        while (!rsp_valid) @(negedge clk);
        assert (response.error == BUS_OK &&
                32'(response.rdata >> (8 * ((ITCM_BASE+4) % DBUS_BYTES))) == word_at(xlen_t'(ITCM_BASE+4)))
            else $fatal(1, "uncached response route mixed");
        rsp_ready = 1;
        @(negedge clk);
        rsp_ready = 0;
        checks += 2;
    endtask

    // Reset 与下层一起复位，取消在途协议状态；数据 RAM 不清零也必须冷 miss。
    task automatic reset_inflight;
        @(negedge clk);
        request = '0;
        request.addr = BASE+64;
        request.execute = 1;
        request.size = MEM_WORD;
        req_valid = 1;
        do @(posedge clk); while (!req_ready);
        @(negedge clk);
        req_valid = 0;
        while (!pending) @(negedge clk);
        rst = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        assert (!rsp_valid) else $fatal(1, "reset retained response");
        fetch(BASE+64, DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, ENABLE && DDR_BYTES != 0 ? 8 : 1);
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 0;
        fetch(xlen_t'(ITCM_BASE), BUS_OK, 1);
        fetch(xlen_t'(DTCM_BASE+4), BUS_SLVERR, 1);
        fetch(xlen_t'(32'h10000000), BUS_SLVERR, 1);
        fetch(BASE+2, DDR_BYTES == 0 ? BUS_DECERR : BUS_SLVERR, 1);
        if (XLEN == 64) fetch(BASE | (xlen_t'(1) << 32), BUS_DECERR, 1);
        if (!ENABLE || DDR_BYTES == 0) begin
            repeat (3) fetch(BASE, DDR_BYTES == 0 ? BUS_DECERR : BUS_OK, 1);
        end else begin
            fetch(BASE, BUS_OK, 8);
            for (int word_idx = 0; word_idx < 8; word_idx++) fetch(BASE+xlen_t'(4*word_idx), BUS_OK, 0);
            fetch(BASE+xlen_t'(STRIDE), BUS_OK, 8);
            fetch(BASE, BUS_OK, 0);
            fetch(BASE+xlen_t'(2*STRIDE), BUS_OK, 8);
            fetch(BASE, BUS_OK, 0);
            fetch(BASE+xlen_t'(STRIDE), BUS_OK, 8); // LRU 淘汰的正是另一条线。
            // 最后不足一行的 DDR 与区域外访问必须旁路，不能为命中截断地址。
            fetch(BASE+xlen_t'(DDR_BYTES-4), BUS_OK, 1);
            fetch(BASE+xlen_t'(DDR_BYTES), BUS_DECERR, 1);
            for (int beat = 0; beat < 8; beat++) begin
                clear_cache();
                fault_enable = 1;
                fault_addr = BASE+xlen_t'(4*beat);
                fetch(BASE+12, beat == 3 ? BUS_SLVERR : BUS_OK, beat+2);
                fault_enable = 0;
                fetch(BASE+12, BUS_OK, 8); // 部分成功不能安装有效行。
            end
            for (int beat = 0; beat <= 8; beat++) begin
                clear_cache();
                fetch(BASE+28, BUS_OK, 8, beat);
                fetch(BASE+28, BUS_OK, 8); // 被失效的填行不得在稍后复活。
            end
            fetch(BASE+4, BUS_OK, 0, -1, 1);
            fetch(BASE+4, BUS_OK, 8);
        end
        bypass_handoff();
        reset_inflight();
        $display("PASS tb_icache XLEN=%0d enabled=%0d bytes=%0d ddr=%0d checks=%0d", XLEN, ENABLE, CACHE_BYTES, DDR_BYTES, checks);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "cache test global timeout");
    end
endmodule
