// Module: tb_local_to_axi
// Description: Checks independent AXI channels, backpressure, byte lanes and error completion.
module tb_local_to_axi;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_req_t request;
    bus_rsp_t response;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    xlen_t wdata, rdata;
    logic [DBUS_BYTES-1:0] wstrb;
    int checks, expected_writes, expected_reads, accepted, completed, aws, ws, ars, bs, rs;
    logic aw_stalled, w_stalled, ar_stalled, rsp_stalled;
    logic [127:0] aw_previous, ar_previous, aw_payload, ar_payload;
    logic [XLEN+DBUS_BYTES:0] w_previous;
    bus_rsp_t rsp_previous;

    local_to_axi dut (.*);
    assign aw_payload = 128'({awid, awaddr, awlen, awsize, awburst, awlock,
                              awcache, awqos, awregion, awprot});
    assign ar_payload = 128'({arid, araddr, arlen, arsize, arburst, arlock,
                              arcache, arqos, arregion, arprot});

    // 在采样沿检查上一拍反压的载荷；刺激统一在下降沿更新，避免 TB/DUT 竞争。
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_stalled <= 0; w_stalled <= 0; ar_stalled <= 0; rsp_stalled <= 0;
            accepted <= 0; completed <= 0; aws <= 0; ws <= 0; ars <= 0; bs <= 0; rs <= 0;
            aw_previous <= '0; ar_previous <= '0; w_previous <= '0; rsp_previous <= '0;
        end else begin
            if (aw_stalled && (!awvalid || aw_payload !== aw_previous))
                $fatal(1, "AW changed under backpressure");
            if (ar_stalled && (!arvalid || ar_payload !== ar_previous))
                $fatal(1, "AR changed under backpressure");
            if (w_stalled && (!wvalid || {wdata, wstrb, wlast} !== w_previous))
                $fatal(1, "W changed under backpressure");
            if (rsp_stalled && (!rsp_valid || response !== rsp_previous))
                $fatal(1, "local response changed under backpressure");
            aw_stalled <= awvalid && !awready;
            ar_stalled <= arvalid && !arready;
            w_stalled <= wvalid && !wready;
            rsp_stalled <= rsp_valid && !rsp_ready;
            aw_previous <= aw_payload; ar_previous <= ar_payload;
            w_previous <= {wdata, wstrb, wlast}; rsp_previous <= response;
            if (req_valid && req_ready) accepted <= accepted + 1;
            if (rsp_valid && rsp_ready) completed <= completed + 1;
            if (awvalid && awready) aws <= aws + 1;
            if (wvalid && wready) ws <= ws + 1;
            if (arvalid && arready) ars <= ars + 1;
            if (bvalid && bready) bs <= bs + 1;
            if (rvalid && rready) rs <= rs + 1;
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic send(input bus_req_t value);
        request = value;
        req_valid = 1;
        #1;
        if (!req_ready || rsp_valid || awvalid || arvalid || wvalid)
            $fatal(1, "request not isolated from AXI until accepted");
        tick();
        req_valid = 0;
        request = '1; // 接受后立即改变上游载荷，证明 AXI 使用锁存值。
        #1;
    endtask

    task automatic finish_response(input bus_error_e error, input xlen_t data);
        if (!rsp_valid || response.error != error || response.rdata !== data)
            $fatal(1, "response error=%0d/%0d data=%h/%h", response.error, error,
                   response.rdata, data);
        // 反压时尝试送下一笔，旧响应未消费前不允许接受。
        req_valid = 1;
        repeat (3) begin
            if (req_ready || awvalid || arvalid || wvalid || bready || rready)
                $fatal(1, "transaction escaped held local response");
            tick();
        end
        req_valid = 0;
        rsp_ready = 1;
        tick();
        rsp_ready = 0;
        #1;
        if (rsp_valid || !req_ready) $fatal(1, "response not consumed exactly once");
        checks++;
    endtask

    task automatic write_case(input bus_req_t value, input int order,
                              input logic [1:0] code, input logic bad_id,
                              input bus_error_e expected, input int response_delay = 3);
        send(value);
        expected_writes++;
        if (!awvalid || !wvalid || awaddr != 32'(value.addr) || awsize != 3'(value.size) ||
            wdata !== value.wdata || wstrb !== value.wstrb || !wlast || awid || awlen ||
            awburst != 1 || awlock || awcache || awqos || awregion || awprot != 1)
            $fatal(1, "incorrect write channel metadata");
        repeat (2) tick();
        awready = order != 1;
        wready = order != 0;
        tick();
        awready = 0; wready = 0;
        #1;
        if (order != 2) begin
            if (awvalid != (order == 1) || wvalid != (order == 0) || bready)
                $fatal(1, "AW/W handshake coupled or duplicated");
            repeat (2) tick();
            awready = order == 1;
            wready = order == 0;
            tick();
            awready = 0; wready = 0;
        end
        repeat (response_delay) begin
            #1;
            if (rsp_valid || !bready || awvalid || wvalid)
                $fatal(1, "write completed before B response");
            tick();
        end
        bresp = code; bid = bad_id; bvalid = 1;
        tick();
        bvalid = 0; bresp = 0; bid = 0;
        finish_response(expected, '0);
    endtask

    task automatic read_case(input bus_req_t value, input logic [1:0] code,
                             input logic bad_id, input logic extra_beat,
                             input bus_error_e expected, input int address_delay = 3,
                             input int response_delay = 2);
        xlen_t value_read;
        value_read = xlen_t'(64'hf1e2_d3c4_b5a6_9788);
        send(value);
        expected_reads++;
        if (!arvalid || araddr != 32'(value.addr) || arsize != 3'(value.size) ||
            arid || arlen || arburst != 1 || arlock || arcache || arqos || arregion ||
            arprot != {value.execute, 2'b01}) $fatal(1, "incorrect read channel metadata");
        repeat (address_delay) tick();
        arready = 1;
        tick();
        arready = 0;
        repeat (response_delay) begin
            #1;
            if (rsp_valid || arvalid || !rready) $fatal(1, "read response wait broken");
            tick();
        end
        rdata = value_read; rresp = code; rid = bad_id;
        rlast = !extra_beat; rvalid = 1;
        tick();
        if (extra_beat) begin
            // 非法多 beat 返回须排空，不可把多余 beat 归给下一笔本地请求。
            if (rsp_valid || !rready || req_ready) $fatal(1, "malformed read escaped drain");
            rvalid = 0;
            tick();
            rvalid = 1; rlast = 1;
            tick();
        end
        rvalid = 0; rdata = '0; rresp = 0; rid = 0;
        finish_response(expected, expected == BUS_OK ? value_read : '0);
    endtask

    initial begin : run
        bus_req_t value;
        req_valid = 0; rsp_ready = 0; request = '0;
        awready = 0; wready = 0; arready = 0; bvalid = 0; bresp = 0; bid = 0;
        rvalid = 0; rdata = '0; rresp = 0; rid = 0; rlast = 1;
        checks = 0; expected_writes = 0; expected_reads = 0;
        repeat (4) tick();
        rst = 0;
        #1;
        // 采样沿前撤回的本地请求从未接受，不应产生 AXI VALID。
        req_valid = 1;
        #1; req_valid = 0;
        tick();
        if (awvalid || arvalid || wvalid || rsp_valid) $fatal(1, "unaccepted request issued");

        // 所有合法对齐大小与 byte lane，含 RV64 高 32 位和全 64 位传输。
        for (int size = 0; size <= $clog2(DBUS_BYTES); size++) begin
            for (int lane = 0; lane < DBUS_BYTES; lane += (1 << size)) begin
                value = '0;
                value.addr = xlen_t'(32'h8000_0100 + lane);
                value.size = mem_size_e'(size);
                value.wdata = xlen_t'(64'hfedc_ba98_7654_3210);
                value.wstrb = DBUS_BYTES'(((1 << (1 << size)) - 1) << lane);
                value.write = 1;
                write_case(value, (size + lane) % 3, 0, 0, BUS_OK);
                value.write = 0;
                read_case(value, 0, 0, 0, BUS_OK);
            end
        end
        value = '0; value.addr = xlen_t'(32'h8000_0ffc); value.size = MEM_WORD;
        value.execute = 1;
        read_case(value, 0, 0, 0, BUS_OK); // 页末取指，不扩大发送范围。
        value.execute = 0;
        read_case(value, 0, 0, 0, BUS_OK, 0, 0); // 地址接受后的最早返回。
        read_case(value, 2'b10, 0, 0, BUS_SLVERR);
        read_case(value, 2'b11, 0, 0, BUS_DECERR);
        read_case(value, 2'b01, 0, 0, BUS_SLVERR);
        read_case(value, 0, 1, 0, BUS_SLVERR);
        read_case(value, 0, 0, 1, BUS_SLVERR);
        value.write = 1;
        value.wstrb = DBUS_BYTES'(15 << (4 * (XLEN == 64)));
        write_case(value, 0, 2'b10, 0, BUS_SLVERR);
        write_case(value, 1, 2'b11, 0, BUS_DECERR);
        write_case(value, 2, 2'b01, 0, BUS_SLVERR);
        write_case(value, 2, 0, 1, BUS_SLVERR);
        write_case(value, 2, 0, 0, BUS_OK, 0); // AW/W 同沿，下一拍返回 B。
        value.wstrb = '0;
        write_case(value, 2, 0, 0, BUS_OK); // AXI 允许零 strobe 写，仍须等待 B。

        // 不对齐、非法取指/字节通道和 RV64 高物理地址只产生本地错误。
        value.addr = xlen_t'(32'h8000_0001);
        send(value); finish_response(BUS_SLVERR, '0);
        value.addr = xlen_t'(32'h8000_0000); value.execute = 1;
        send(value); finish_response(BUS_SLVERR, '0);
        value.execute = 0; value.size = MEM_BYTE; value.wstrb = '1;
        send(value); finish_response(BUS_SLVERR, '0);
        if (XLEN == 64) begin
            value.addr = xlen_t'(64'h1_8000_0000);
            send(value); finish_response(BUS_DECERR, '0);
        end else begin
            value.addr = xlen_t'(32'h8000_0000); value.size = MEM_DWORD;
            send(value); finish_response(BUS_SLVERR, '0);
        end
        if (accepted != checks || completed != checks || aws != expected_writes ||
            ws != expected_writes || bs != expected_writes || ars != expected_reads ||
            rs != expected_reads + 1) $fatal(1, "handshake counts disagree");
        // 只模拟与外部从端同时复位；不承诺单独复位主桥能撤销已送达的写入。
        for (int pending = 0; pending < 4; pending++) begin
            value = '0; value.addr = xlen_t'(32'h8000_0000); value.size = MEM_WORD;
            value.write = pending < 2; value.wstrb = DBUS_BYTES'(15);
            if (pending == 3) value.addr = xlen_t'(32'h8000_0001);
            send(value);
            awready = pending == 0; wready = pending == 1; arready = pending == 2;
            tick();
            rst = 1;
            awready = 0; wready = 0; arready = 0;
            #1;
            if (awvalid || wvalid || arvalid || bready || rready || rsp_valid || req_ready)
                $fatal(1, "AXI bridge active during reset");
            repeat (2) tick();
            rst = 0;
            repeat (2) tick();
            if (awvalid || wvalid || arvalid || rsp_valid || !req_ready)
                $fatal(1, "pre-reset transaction replayed");
            value = '0; value.addr = xlen_t'(32'h8000_0000); value.size = MEM_WORD;
            read_case(value, 0, 0, 0, BUS_OK, 0, 0);
            if (accepted != 1 || completed != 1 || ars != 1 || rs != 1 || aws || ws || bs)
                $fatal(1, "post-reset exact-once failed");
        end
        $display("PASS tb_local_to_axi RV%0d completions=%0d coordinated_resets=4", XLEN, checks);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "AXI bridge timeout");
    end
endmodule
