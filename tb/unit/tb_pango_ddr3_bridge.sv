// Module: tb_pango_ddr3_bridge
// Description: Exercises the Pango 256-bit DDR user port translation and local response holding.
module tb_pango_ddr3_bridge;
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
    logic memory_req_valid, memory_req_ready, memory_rsp_valid, memory_rsp_ready;
    ddr_req_t memory_request;
    ddr_rsp_t memory_response;
    logic wide_req_valid = 0, wide_req_ready, wide_rsp_valid, wide_rsp_ready = 0;
    ddr_req_t wide_request = '0;
    ddr_rsp_t wide_response;
    logic [27:0] axi_awaddr, axi_araddr;
    logic axi_awuser_ap, axi_aruser_ap, axi_awvalid, axi_awready;
    logic axi_wready, axi_arvalid, axi_arready, axi_rlast, axi_rvalid;
    logic [3:0] axi_awuser_id, axi_awlen, axi_aruser_id, axi_arlen, axi_rid;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;
    int checks;

    // 保留原窄访存用例，经过与板级相同的 lane 适配后检查 256-bit 原生接口。
    ddr_port_arbiter u_port (
        .clk, .rst, .cpu_req_valid(req_valid), .cpu_req_ready(req_ready), .cpu_request(request),
        .cpu_rsp_valid(rsp_valid), .cpu_rsp_ready(rsp_ready), .cpu_response(response),
        .dma_req_valid(wide_req_valid), .dma_req_ready(wide_req_ready), .dma_request(wide_request),
        .dma_rsp_valid(wide_rsp_valid), .dma_rsp_ready(wide_rsp_ready), .dma_response(wide_response),
        .req_valid(memory_req_valid), .req_ready(memory_req_ready), .request(memory_request),
        .rsp_valid(memory_rsp_valid), .rsp_ready(memory_rsp_ready), .response(memory_response)
    );
    pango_ddr3_bridge dut (.req_valid(memory_req_valid), .req_ready(memory_req_ready),
        .request(memory_request), .rsp_valid(memory_rsp_valid), .rsp_ready(memory_rsp_ready),
        .response(memory_response), .*);

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic send(input bus_req_t value);
        request = value;
        req_valid = 1;
        #1;
        if (!req_ready) $fatal(1, "bridge did not accept request");
        tick();
        req_valid = 0;
        request = '1;
    endtask

    task automatic take(input bus_error_e error, input xlen_t data);
        #1;
        if (!rsp_valid || response.error != error || response.rdata !== data)
            $fatal(1, "response error=%0d/%0d data=%h/%h", response.error,
                   error, response.rdata, data);
        repeat (2) begin
            if (req_ready) $fatal(1, "accepted next request before response was consumed");
            tick();
            if (!rsp_valid || response.error != error || response.rdata !== data)
                $fatal(1, "response changed under backpressure");
        end
        rsp_ready = 1;
        tick();
        rsp_ready = 0;
        #1;
        if (rsp_valid || !req_ready) $fatal(1, "response consumed incorrectly");
        checks++;
    endtask

    initial begin
        req_valid = 0; rsp_ready = 0; request = '0;
        axi_awready = 0; axi_wready = 0; axi_arready = 0;
        axi_rdata = '0; axi_rid = 0; axi_rlast = 0; axi_rvalid = 0;
        repeat (3) tick();
        rst = 0;
        tick();

        // 32-byte beat 的最后一个 XLEN 字，检查 AW 地址、局部字节掩码和反压。
        request = '0;
        request.write = 1;
        request.size = MEM_BYTE;
        request.addr = xlen_t'(32'h8000_001f);
        request.wdata = xlen_t'(8'h5a) << (8 * (DBUS_BYTES - 1));
        request.wstrb = DBUS_BYTES'(1 << (DBUS_BYTES - 1));
        send(request);
        repeat (3) begin
            #1;
            if (!axi_awvalid || axi_awaddr != 28'h0000000 ||
                axi_awlen != 0 || axi_awuser_id != 0 || axi_awuser_ap ||
                axi_wstrb !== (32'h1 << 31) || axi_wdata[255:248] !== 8'h5a ||
                rsp_valid)
                $fatal(1, "write translation or AW backpressure failed");
            tick();
        end
        axi_awready = 1;
        tick();
        axi_awready = 0;
        if (axi_awvalid || rsp_valid) $fatal(1, "write completed before data acceptance");
        repeat (2) tick();
        axi_wready = 1;
        tick();
        axi_wready = 0;
        take(BUS_OK, '0);

        // IP 无 RREADY；读数据脉冲必须锁存，下一笔本地请求不可覆盖它。
        request = '0;
        request.size = MEM_WORD;
        request.addr = xlen_t'(32'h8000_0018);
        send(request);
        repeat (2) begin
            #1;
            if (!axi_arvalid || axi_araddr != 28'h0 || axi_arlen != 0 || rsp_valid)
                $fatal(1, "read translation or AR backpressure failed");
            tick();
        end
        axi_arready = 1;
        tick();
        axi_arready = 0;
        axi_rdata = '0;
        axi_rdata[223:192] = 32'h12345678;
        axi_rlast = 1;
        axi_rvalid = 1;
        tick();
        axi_rvalid = 0;
        axi_rdata = '1;
        take(BUS_OK, xlen_t'(32'h12345678));

        // 地址越界及 IP 异常读标识应返回错误，不能静默折叠到合法物理地址。
        request = '0;
        request.size = MEM_WORD;
        request.addr = xlen_t'(32'ha000_0000);
        send(request);
        if (axi_arvalid || axi_awvalid) $fatal(1, "out-of-range request reached IP");
        take(BUS_DECERR, '0);

        request = '0;
        request.size = MEM_WORD;
        request.addr = xlen_t'(32'h8000_0000);
        send(request);
        axi_arready = 1;
        tick();
        axi_arready = 0;
        axi_rid = 4'h1;
        axi_rvalid = 1;
        tick();
        axi_rvalid = 0;
        take(BUS_SLVERR, '0);

        // 非法多 beat 响应必须排空到 RLAST，期间不得报完成或接纳新 owner。
        axi_rid = 0;
        request = '0;
        request.size = MEM_WORD;
        request.addr = xlen_t'(32'h8000_0000);
        send(request);
        axi_arready = 1; tick(); axi_arready = 0;
        axi_rvalid = 1; axi_rlast = 0; tick(); axi_rvalid = 0;
        repeat (3) begin
            #1;
            assert (!rsp_valid && !req_ready) else $fatal(1, "Pango malformed read released owner early");
            tick();
        end
        axi_rvalid = 1; axi_rlast = 1; tick(); axi_rvalid = 0;
        take(BUS_SLVERR, '0);
        request = '0;
        request.size = MEM_WORD;
        request.addr = xlen_t'(32'h8000_0000);
        send(request);
        axi_arready = 1; tick(); axi_arready = 0;
        axi_rdata = '0; axi_rdata[31:0] = 32'h5a123456;
        axi_rvalid = 1; tick(); axi_rvalid = 0;
        take(BUS_OK, xlen_t'(32'h5a123456));

        // 整拍 DMA 不能只检查低 XLEN；全部 32 字节逐一对应到真实 IP 256-bit 引脚。
        wide_request = '0;
        wide_request.write = 1;
        wide_request.addr = xlen_t'(32'h80001000);
        wide_request.size = 5;
        wide_request.wstrb = '1;
        for (int b = 0; b < 32; b++) wide_request.wdata[b*8 +: 8] = 8'(b*3+1);
        wide_req_valid = 1; #1;
        assert (wide_req_ready) else $fatal(1, "Pango native request blocked while idle");
        tick(); wide_req_valid = 0;
        #1;
        assert (axi_awvalid && axi_awaddr == 28'h400 && axi_awlen == 0 &&
                axi_wstrb == 32'hffffffff && axi_wdata == wide_request.wdata)
            else $fatal(1, "Pango native wide payload truncated or wrong address units");
        axi_awready = 1; tick(); axi_awready = 0;
        axi_wready = 1; tick(); axi_wready = 0;
        #1;
        assert (wide_rsp_valid && wide_response.error == BUS_OK) else $fatal(1, "native write did not complete");
        wide_rsp_ready = 1; tick(); wide_rsp_ready = 0;
        wide_request.write = 0; wide_req_valid = 1; tick(); wide_req_valid = 0;
        axi_arready = 1; tick(); axi_arready = 0;
        axi_rdata = wide_request.wdata; axi_rvalid = 1; axi_rlast = 1; tick(); axi_rvalid = 0;
        repeat (3) begin
            #1;
            assert (wide_rsp_valid && wide_response.error == BUS_OK && wide_response.rdata == wide_request.wdata)
                else $fatal(1, "native read lost upper bytes or response backpressure");
            tick();
        end
        wide_rsp_ready = 1; tick(); wide_rsp_ready = 0;
        checks += 2;

        $display("PASS tb_pango_ddr3_bridge RV%0d checks=%0d", XLEN, checks);
        $finish;
    end
endmodule
