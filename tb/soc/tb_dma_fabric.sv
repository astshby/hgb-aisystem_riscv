// Module: tb_dma_fabric
// Description: Exercises DMA, three-master arbitration, TCM, AXI external RAM and IRQ.
module tb_dma_fabric #(
    parameter bit REGISTERED = 1'b0,
    parameter bit WIDE_ENABLE = 1'b0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    localparam int unsigned EXTERNAL_BYTES = 64 * 1024;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic [2:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [3];
    bus_rsp_t m_response [3];
    logic [2:0] fabric_req_valid, fabric_req_ready, fabric_rsp_valid, fabric_rsp_ready;
    bus_req_t fabric_request [3];
    bus_rsp_t fabric_response [3];
    logic [15:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [16];
    bus_rsp_t s_response [16];
    bus_error_e s_error [16];
    logic dma_irq, external_irq;
    logic [31:0] fault_read_addr = '1, fault_write_addr = '1;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    logic [255:0] wdata, rdata;
    logic [31:0] wstrb;
    logic wide_req_valid, wide_req_ready, wide_rsp_valid, wide_rsp_ready;
    ddr_req_t wide_request, memory_request;
    ddr_rsp_t wide_response, memory_response;
    logic memory_req_valid, memory_req_ready, memory_rsp_valid, memory_rsp_ready;
    int checks = 0, dma_accepted = 0, dma_completed = 0, ddr_writes = 0;
    int data_accepted = 0, data_completed = 0;
    int wide_accepted = 0, wide_completed = 0, wide_reads = 0, wide_writes = 0, cycles = 0;

    // 对比原 fabric 与 SoC 新边界；同一 DMA/AXI/错误/IRQ 用例运行两种接线。
    for (genvar m = 0; m < 3; m++) begin : g_timing_boundary
        if (REGISTERED) begin
            bus_transaction_register u_register (
                .clk, .rst,
                .s_req_valid(m_req_valid[m]), .s_req_ready(m_req_ready[m]), .s_request(m_request[m]),
                .s_rsp_valid(m_rsp_valid[m]), .s_rsp_ready(m_rsp_ready[m]), .s_response(m_response[m]),
                .m_req_valid(fabric_req_valid[m]), .m_req_ready(fabric_req_ready[m]), .m_request(fabric_request[m]),
                .m_rsp_valid(fabric_rsp_valid[m]), .m_rsp_ready(fabric_rsp_ready[m]), .m_response(fabric_response[m])
            );
        end else begin
            assign fabric_req_valid[m] = m_req_valid[m];
            assign m_req_ready[m] = fabric_req_ready[m];
            assign fabric_request[m] = m_request[m];
            assign m_rsp_valid[m] = fabric_rsp_valid[m];
            assign fabric_rsp_ready[m] = m_rsp_ready[m];
            assign m_response[m] = fabric_response[m];
        end
    end

    bus_interconnect #(.MASTERS(3), .PRESENT(16'h503f),
                       .DATA_PRIORITY(1'b1), .DDR_BYTES(EXTERNAL_BYTES)) u_fabric (
        .clk, .rst, .m_req_valid(fabric_req_valid), .m_req_ready(fabric_req_ready), .m_request(fabric_request),
        .m_rsp_valid(fabric_rsp_valid), .m_rsp_ready(fabric_rsp_ready), .m_response(fabric_response),
        .s_req_valid, .s_req_ready, .s_request, .s_error,
        .s_rsp_valid, .s_rsp_ready, .s_response
    );
    bus_error_slave u_error (
        .clk, .rst, .req_valid(s_req_valid[0]), .req_ready(s_req_ready[0]),
        .req_error(s_error[0]), .rsp_valid(s_rsp_valid[0]),
        .rsp_ready(s_rsp_ready[0]), .response(s_response[0])
    );
    boot_rom u_rom (
        .clk, .rst, .req_valid(s_req_valid[1]), .req_ready(s_req_ready[1]),
        .request(s_request[1]), .rsp_valid(s_rsp_valid[1]),
        .rsp_ready(s_rsp_ready[1]), .response(s_response[1])
    );
    for (genvar s = 2; s < 4; s++) begin : g_tcm
        tcm_controller #(.BASE(s == 2 ? ITCM_BASE : DTCM_BASE)) u_tcm (
            .clk, .rst, .req_valid(s_req_valid[s]), .req_ready(s_req_ready[s]),
            .request(s_request[s]), .rsp_valid(s_rsp_valid[s]),
            .rsp_ready(s_rsp_ready[s]), .response(s_response[s])
        );
    end
    irq_controller u_irq (
        .clk, .rst, .sources({dma_irq, 6'b0}), .irq(external_irq),
        .req_valid(s_req_valid[5]), .req_ready(s_req_ready[5]),
        .request(s_request[5]), .rsp_valid(s_rsp_valid[5]),
        .rsp_ready(s_rsp_ready[5]), .response(s_response[5])
    );
    dma_controller #(.DDR_BYTES(EXTERNAL_BYTES), .WIDE_ENABLE(WIDE_ENABLE)) u_dma (
        .clk, .rst, .req_valid(s_req_valid[12]), .req_ready(s_req_ready[12]),
        .request(s_request[12]), .rsp_valid(s_rsp_valid[12]),
        .rsp_ready(s_rsp_ready[12]), .response(s_response[12]), .irq(dma_irq),
        .master_req_valid(m_req_valid[2]), .master_req_ready(m_req_ready[2]),
        .master_request(m_request[2]), .master_rsp_valid(m_rsp_valid[2]),
        .master_rsp_ready(m_rsp_ready[2]), .master_response(m_response[2]),
        .wide_req_valid, .wide_req_ready, .wide_request, .wide_rsp_valid, .wide_rsp_ready, .wide_response
    );
    ddr_port_arbiter u_port (
        .clk, .rst, .cpu_req_valid(s_req_valid[14]), .cpu_req_ready(s_req_ready[14]), .cpu_request(s_request[14]),
        .cpu_rsp_valid(s_rsp_valid[14]), .cpu_rsp_ready(s_rsp_ready[14]), .cpu_response(s_response[14]),
        .dma_req_valid(wide_req_valid), .dma_req_ready(wide_req_ready), .dma_request(wide_request),
        .dma_rsp_valid(wide_rsp_valid), .dma_rsp_ready(wide_rsp_ready), .dma_response(wide_response),
        .req_valid(memory_req_valid), .req_ready(memory_req_ready), .request(memory_request),
        .rsp_valid(memory_rsp_valid), .rsp_ready(memory_rsp_ready), .response(memory_response)
    );
    ddr_to_axi #(.DDR_BYTES(EXTERNAL_BYTES)) u_bridge (
        .clk, .rst, .req_valid(memory_req_valid), .req_ready(memory_req_ready),
        .request(memory_request), .rsp_valid(memory_rsp_valid),
        .rsp_ready(memory_rsp_ready), .response(memory_response),
        .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
        .awlock, .awcache, .awqos, .awregion, .awprot,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
        .arlock, .arcache, .arqos, .arregion, .arprot,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );
    axi_memory_model #(.BYTES(EXTERNAL_BYTES), .DATA_W(256)) u_external (
        .clk, .rst, .fault_read_addr, .fault_write_addr,
        .awvalid, .awready, .awaddr, .awsize,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .araddr, .arsize,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );
    for (genvar s = 4; s < 14; s++) begin : g_absent
        if (s != 5 && s != 12) begin
            assign s_req_ready[s] = 1'b0;
            assign s_rsp_valid[s] = 1'b0;
            assign s_response[s] = '0;
        end
    end
    always @(posedge clk) begin
        cycles++;
        if (rst) begin
            dma_accepted = 0;
            dma_completed = 0;
            ddr_writes = 0;
            data_accepted = 0;
            data_completed = 0;
            wide_accepted = 0; wide_completed = 0; wide_reads = 0; wide_writes = 0;
        end else begin
            if (m_req_valid[2] && m_req_ready[2]) dma_accepted++;
            if (m_rsp_valid[2] && m_rsp_ready[2]) dma_completed++;
            if (bvalid && bready && bresp == 0) ddr_writes++;
            if (m_req_valid[1] && m_req_ready[1]) data_accepted++;
            if (m_rsp_valid[1] && m_rsp_ready[1]) data_completed++;
            if (wide_req_valid && wide_req_ready) begin
                wide_accepted++;
                assert (wide_request.size == 5 && wide_request.addr[4:0] == 0 &&
                        (!wide_request.write || wide_request.wstrb == 32'hffffffff))
                    else $fatal(1, "DMA wide request is not a full native beat");
            end
            if (wide_rsp_valid && wide_rsp_ready) wide_completed++;
            if (arvalid && arready && arsize == 5) wide_reads++;
            if (awvalid && awready && awsize == 5) wide_writes++;
            if ((arvalid && arready) || (awvalid && awready))
                assert (arlen == 0 && awlen == 0 &&
                        (!arvalid || (13'(araddr[11:0]) + (13'd1 << arsize) <= 4096)) &&
                        (!awvalid || (13'(awaddr[11:0]) + (13'd1 << awsize) <= 4096)))
                    else $fatal(1, "single-beat AXI crossed 4 KiB or changed LEN");
            assert (wide_accepted >= wide_completed && wide_accepted-wide_completed <= 1)
                else $fatal(1, "wide DMA outstanding count");
            assert (dma_accepted >= dma_completed && dma_accepted-dma_completed <= 1)
                else $fatal(1, "DMA outstanding count");
            assert (data_accepted >= data_completed && data_accepted-data_completed <= 1)
                else $fatal(1, "CPU D outstanding count");
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    // 通过真实 CPU 总线初始化与核对，期望数据不来自 DUT 的 FIFO 或路由选择。
    task automatic wide_copy_case(input logic [31:0] src, dst, length, input int expected_beats);
        int read_before, write_before, cycle_before;
        for (int i = 0; i < int'(length); i++) begin
            byte_write(src + 32'(i), 8'(i*13+7));
            byte_write(dst + 32'(i), 8'ha5);
        end
        byte_write(dst-1, 8'hc3); byte_write(dst+length, 8'h3c);
        read_before = wide_reads; write_before = wide_writes; cycle_before = cycles;
        start_copy(src, dst, length);
        wait_done(2, length, 0, 0);
        $display("DMA_COPY RV%0d wide=%0d bytes=%0d cycles=%0d AXI256_R=%0d AXI256_W=%0d",
                 XLEN, WIDE_ENABLE, length, cycles-cycle_before, wide_reads-read_before, wide_writes-write_before);
        assert (wide_reads-read_before == (WIDE_ENABLE ? expected_beats : 0) &&
                wide_writes-write_before == (WIDE_ENABLE ? expected_beats : 0))
            else $fatal(1, "wide DMA was emulated with narrow beats or used an illegal tail");
        for (int i = 0; i < int'(length); i++) byte_check(dst+32'(i), 8'(i*13+7));
        byte_check(dst-1, 8'hc3); byte_check(dst+length, 8'h3c);
        assert (dma_irq) else $fatal(1, "wide completion IRQ missing");
        wr(DMA_BASE+16, 2);
        assert (!dma_irq) else $fatal(1, "wide completion IRQ W1C failed");
    endtask
    task automatic transfer(input int master, input logic [31:0] addr, input bit wr,
                            input mem_size_e size, input xlen_t data,
                            output xlen_t result, input bus_error_e expected = BUS_OK);
        int elapsed;
        m_request[master] = '0;
        m_request[master].addr = xlen_t'(addr);
        m_request[master].write = wr;
        m_request[master].size = size;
        m_request[master].wdata = data << (8 * (addr % DBUS_BYTES));
        m_request[master].wstrb = DBUS_BYTES'(((1 << (1 << size))-1) << (addr % DBUS_BYTES));
        m_req_valid[master] = 1;
        elapsed = 0;
        #1;
        while (!m_req_ready[master]) begin
            tick(); #1;
            elapsed++;
            if (elapsed > 3000) $fatal(1, "CPU request timeout addr=%h", addr);
        end
        tick();
        m_req_valid[master] = 0;
        elapsed = 0;
        #1;
        while (!m_rsp_valid[master]) begin
            tick(); #1;
            elapsed++;
            if (elapsed > 3000) $fatal(1, "CPU response timeout addr=%h", addr);
        end
        if (m_response[master].error != expected)
            $fatal(1, "response addr=%h error=%0d wanted=%0d", addr,
                   m_response[master].error, expected);
        result = m_response[master].rdata >> (8 * (addr % DBUS_BYTES));
        m_rsp_ready[master] = 1;
        tick();
        m_rsp_ready[master] = 0;
        checks++;
    endtask
    task automatic wr(input logic [31:0] addr, data);
        xlen_t ignored;
        transfer(1, addr, 1, MEM_WORD, xlen_t'(data), ignored);
    endtask
    task automatic rd(input logic [31:0] addr, output logic [31:0] data);
        xlen_t value;
        transfer(1, addr, 0, MEM_WORD, '0, value);
        data = 32'(value);
    endtask
    task automatic byte_write(input logic [31:0] addr, input logic [7:0] value);
        xlen_t ignored;
        transfer(1, addr, 1, MEM_BYTE, xlen_t'(value), ignored);
    endtask
    task automatic byte_check(input logic [31:0] addr, input logic [7:0] value);
        xlen_t got;
        transfer(1, addr, 0, MEM_BYTE, '0, got);
        if (got[7:0] !== value) $fatal(1, "copy addr=%h got=%h wanted=%h", addr,got[7:0],value);
    endtask
    task automatic start_copy(input logic [31:0] src, dst, bytes);
        wr(DMA_BASE, src);
        wr(DMA_BASE+4, dst);
        wr(DMA_BASE+8, bytes);
        wr(DMA_BASE+12, 3);
    endtask
    task automatic wait_done(input logic [31:0] expected_status, expected_count,
                             expected_fault, expected_code);
        logic [31:0] status, count, fault, code;
        int elapsed;
        elapsed = 0;
        do begin
            rd(DMA_BASE+16, status);
            elapsed++;
            if (elapsed > 3000) $fatal(1, "DMA completion timeout");
        end while ((status & 32'h6) == 0);
        rd(DMA_BASE+20, count);
        rd(DMA_BASE+24, fault);
        rd(DMA_BASE+28, code);
        if (status != expected_status || count != expected_count ||
            fault != expected_fault || code != expected_code)
            $fatal(1, "DMA result status=%h/%h bytes=%h/%h fault=%h/%h code=%h/%h",
                   status,expected_status,count,expected_count,fault,expected_fault,code,expected_code);
        checks++;
    endtask

    initial begin
        logic [31:0] value;
        xlen_t ignored;
        int before_dma;
        int drain_cycles;
        int contention_cycles;
        int before_data;
        m_req_valid = '0;
        m_rsp_ready = '0;
        for (int m = 0; m < 2; m++) m_request[m] = '0;
        repeat (4) tick();
        rst = 0;
        for (int i = 0; i < 40; i++)
            byte_write(DTCM_BASE+32'h100+32'(i), 8'(i+16));
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h100, 35);
        wait_done(2, 35, 0, 0);
        if (!dma_irq) $fatal(1, "DMA done interrupt absent");
        for (int i = 0; i < 35; i++)
            byte_check(DDR_BASE+32'h100+32'(i), 8'(i+16));
        wr(DMA_BASE+16, 2);
        if (dma_irq) $fatal(1, "DMA W1C did not clear IRQ");

        start_copy(DDR_BASE+32'h101, ITCM_BASE+32'h181, 17);
        wait_done(2, 17, 0, 0);
        for (int i = 0; i < 17; i++)
            byte_check(ITCM_BASE+32'h181+32'(i), 8'(i+17));
        wr(DMA_BASE+16, 2);

        // CPU 持续读同一 TCM bank 时，DMA 仍须拿到有限个授权。
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h200, 32);
        before_dma = dma_accepted;
        before_data = data_accepted;
        m_request[1] = '0;
        m_request[1].addr = xlen_t'(DTCM_BASE) + xlen_t'(32'h100);
        m_request[1].size = MEM_WORD;
        m_req_valid[1] = 1;
        m_rsp_ready[1] = 1;
        // DMA 两次请求之间还要等待 AXI 响应；寄存边界下不沿用旧 30 拍截止值。
        // 保持 CPU 压力直到 DMA 确实前进两笔，并以有限周期约束检查饥饿。
        contention_cycles = 0;
        while (dma_accepted-before_dma < 2 && contention_cycles < 120) begin
            tick();
            contention_cycles++;
        end
        if (dma_accepted-before_dma < 2 || data_accepted == before_data)
            $fatal(1, "CPU/DMA progress data=%0d dma=%0d req=%b/%b rsp=%b/%b pending=%b busy=%h",
                   data_accepted-before_data, dma_accepted-before_dma,
                   m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready,
                   u_fabric.pending_q, u_fabric.busy_q);
        m_req_valid[1] = 0;
        // 根据真实握手排空 CPU 请求，不能假设有寄存边界时两拍一定返回。
        drain_cycles = 0;
        while (data_accepted != data_completed) begin
            tick();
            drain_cycles++;
            if (drain_cycles > 100) $fatal(1, "CPU D did not drain after contention");
        end
        m_rsp_ready[1] = 0;
        wait_done(2, 32, 0, 0);
        wr(DMA_BASE+16, 2);

        // 非内存区域在启动前拒绝；状态和 IRQ 保持到 W1C。
        start_copy(UART0_BASE, DTCM_BASE+32'h200, 8);
        wait_done(4, 0, UART0_BASE, 1);
        wr(IRQ_BASE+28, 3);
        wr(IRQ_BASE+32'h2000, 32'h80);
        if (!external_irq) $fatal(1, "DMA IRQ path dma=%b pending=%h enable=%h p7=%h threshold=%h selected=%h", dma_irq, u_irq.pending_q, u_irq.enable_q, u_irq.priority_q[7], u_irq.threshold_q, u_irq.selected);
        rd(IRQ_BASE+32'h200004, value);
        if (value != 7) $fatal(1, "DMA claim ID=%0d", value);
        wr(DMA_BASE+16, 4);
        wr(IRQ_BASE+32'h200004, 7);
        repeat (2) tick();
        if (external_irq) $fatal(1, "DMA IRQ did not deassert after completion");

        fault_read_addr = DDR_BASE+32'h300;
        start_copy(DDR_BASE+32'h300, DTCM_BASE+32'h300, 8);
        wait_done(4, 0, DDR_BASE+32'h300, 3);
        fault_read_addr = '1;
        wr(DMA_BASE+16, 4);
        fault_write_addr = DDR_BASE+32'h380;
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h380, 8);
        wait_done(4, 0, DDR_BASE+32'h380, 5);
        fault_write_addr = '1;
        wr(DMA_BASE+16, 4);

        // 大小无效、目标越界和源/目的重叠不得向主端口发请求。
        before_dma = dma_accepted;
        start_copy(DTCM_BASE+32'h100, DTCM_BASE+32'h104, 8);
        wait_done(4, 0, DTCM_BASE+32'h104, 1);
        if (dma_accepted != before_dma) $fatal(1, "invalid DMA issued bus request");
        wr(DMA_BASE+16, 4);
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h100, 0);
        wait_done(4, 0, DDR_BASE+32'h100, 1);
        if (dma_accepted != before_dma) $fatal(1, "zero length DMA issued bus request");

        if (dma_accepted != dma_completed || ddr_writes < 4)
            $fatal(1, "missing completion or external write");

        wr(DMA_BASE+16, 4);
        wide_copy_case(DDR_BASE+32'h1000, DDR_BASE+32'h2000, 153, 4);
        wide_copy_case(DDR_BASE+32'h8fe0, DDR_BASE+32'hafe0, 96, 3);
        wide_copy_case(DDR_BASE+32'h4001, DDR_BASE+32'h5001, 95, 2);
        wide_copy_case(DDR_BASE+32'h6001, DDR_BASE+32'h7003, 67, 0);

        // 第二个宽 beat 失败：仅第一个成功写入的 32 字节计入 finish_bytes。
        if (WIDE_ENABLE) begin
            for (int i = 0; i < 96; i++) byte_write(DDR_BASE+32'h3000+32'(i), 8'ha5);
            before_dma = wide_accepted;
            fault_read_addr = DDR_BASE+32'h1020;
            start_copy(DDR_BASE+32'h1000, DDR_BASE+32'h3000, 96);
            wait_done(4, 32, DDR_BASE+32'h1020, 3);
            assert (wide_accepted-before_dma == 3) else $fatal(1, "read fault did not stop before second write");
            for (int i = 0; i < 96; i++)
                byte_check(DDR_BASE+32'h3000+32'(i), i < 32 ? 8'(i*13+7) : 8'ha5);
            fault_read_addr = '1; wr(DMA_BASE+16, 4);
            for (int i = 0; i < 96; i++) byte_write(DDR_BASE+32'h3000+32'(i), 8'ha5);
            before_dma = wide_accepted;
            fault_write_addr = DDR_BASE+32'h3020;
            start_copy(DDR_BASE+32'h1000, DDR_BASE+32'h3000, 96);
            wait_done(4, 32, DDR_BASE+32'h3020, 5);
            assert (wide_accepted-before_dma == 4) else $fatal(1, "write fault continued beyond failed beat");
            for (int i = 0; i < 96; i++)
                byte_check(DDR_BASE+32'h3000+32'(i), i < 32 ? 8'(i*13+7) : 8'ha5);
            fault_write_addr = '1; wr(DMA_BASE+16, 4);

            // CPU 与宽 DMA 同时访问 DDR，模型独立反压各 AXI 通道，双方都必须前进。
            before_dma = wide_completed;
            start_copy(DDR_BASE+32'h1000, DDR_BASE+32'h3000, 128);
            for (int i = 0; i < 12; i++) byte_check(DDR_BASE+32'h1000+32'(i), 8'(i*13+7));
            wait_done(2, 128, 0, 0);
            assert (wide_completed-before_dma == 8) else $fatal(1, "CPU contention lost native DMA beats");
            wr(DMA_BASE+16, 2);
        end
        before_dma = dma_accepted + wide_accepted;
        start_copy(32'hffffffe0, DDR_BASE+32'h3000, 64);
        wait_done(4, 0, 32'hffffffe0, 1);
        assert (dma_accepted + wide_accepted == before_dma) else $fatal(1, "overflow DMA reached memory");

        // 协调复位丢弃在途控制状态，但不承诺撤销先前已被外存接受的写入。
        wr(DMA_BASE+16, 4);
        before_dma = wide_accepted;
        if (WIDE_ENABLE) start_copy(DDR_BASE+32'h1000, DDR_BASE+32'h3000, 256);
        else start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h600, 256);
        repeat (10) tick();
        if (!u_dma.u_engine.busy) $fatal(1, "DMA finished before coordinated reset");
        if (WIDE_ENABLE && wide_accepted == before_dma) $fatal(1, "reset did not cover native DMA transaction");
        rst = 1;
        repeat (4) tick();
        rst = 0;
        repeat (2) tick();
        rd(DMA_BASE+16, value);
        if (value != 0 || dma_irq) $fatal(1, "DMA reset did not clear status");
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h700, 8);
        wait_done(2, 8, 0, 0);
        if (dma_accepted != dma_completed)
            $fatal(1, "DMA did not recover after coordinated reset");
        $display("PASS tb_dma_fabric RV%0d registered=%0d wide=%0d checks=%0d dma_requests=%0d external_writes=%0d",
                 XLEN, REGISTERED, WIDE_ENABLE, checks, dma_accepted, ddr_writes);
        $finish;
    end
    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1, "DMA fabric timeout");
    end
endmodule
