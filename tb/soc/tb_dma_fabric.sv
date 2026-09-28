// Module: tb_dma_fabric
// Description: Exercises DMA, three-master arbitration, TCM, AXI external RAM and IRQ.
module tb_dma_fabric;
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
    logic [14:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [15];
    bus_rsp_t s_response [15];
    bus_error_e s_error [15];
    logic dma_irq, external_irq;
    logic [31:0] fault_read_addr = '1, fault_write_addr = '1;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast;
    logic arvalid, arready, arid, arlock, bvalid, bready, bid, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    xlen_t wdata, rdata;
    logic [DBUS_BYTES-1:0] wstrb;
    int checks = 0, dma_accepted = 0, dma_completed = 0, ddr_writes = 0;

    bus_interconnect #(.MASTERS(3), .PRESENT(15'h503f),
                       .DATA_PRIORITY(1'b1), .DDR_BYTES(EXTERNAL_BYTES)) u_fabric (
        .clk, .rst, .m_req_valid, .m_req_ready, .m_request,
        .m_rsp_valid, .m_rsp_ready, .m_response,
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
    dma_controller #(.DDR_BYTES(EXTERNAL_BYTES)) u_dma (
        .clk, .rst, .req_valid(s_req_valid[12]), .req_ready(s_req_ready[12]),
        .request(s_request[12]), .rsp_valid(s_rsp_valid[12]),
        .rsp_ready(s_rsp_ready[12]), .response(s_response[12]), .irq(dma_irq),
        .master_req_valid(m_req_valid[2]), .master_req_ready(m_req_ready[2]),
        .master_request(m_request[2]), .master_rsp_valid(m_rsp_valid[2]),
        .master_rsp_ready(m_rsp_ready[2]), .master_response(m_response[2])
    );
    local_to_axi u_bridge (
        .clk, .rst, .req_valid(s_req_valid[14]), .req_ready(s_req_ready[14]),
        .request(s_request[14]), .rsp_valid(s_rsp_valid[14]),
        .rsp_ready(s_rsp_ready[14]), .response(s_response[14]),
        .awvalid, .awready, .awid, .awaddr, .awlen, .awsize, .awburst,
        .awlock, .awcache, .awqos, .awregion, .awprot,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .arid, .araddr, .arlen, .arsize, .arburst,
        .arlock, .arcache, .arqos, .arregion, .arprot,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );
    axi_memory_model #(.BYTES(EXTERNAL_BYTES)) u_external (
        .clk, .rst, .fault_read_addr, .fault_write_addr,
        .awvalid, .awready, .awaddr, .awsize,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .araddr, .arsize,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );
    for (genvar s = 4; s < 14; s++) begin : g_absent
        if (s != 5 && s != 12) begin : g_missing
            assign s_req_ready[s] = 1'b0;
            assign s_rsp_valid[s] = 1'b0;
            assign s_response[s] = '0;
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            dma_accepted = 0;
            dma_completed = 0;
            ddr_writes = 0;
        end else begin
            if (m_req_valid[2] && m_req_ready[2]) dma_accepted++;
            if (m_rsp_valid[2] && m_rsp_ready[2]) dma_completed++;
            if (bvalid && bready && bresp == 0) ddr_writes++;
            assert (dma_accepted >= dma_completed && dma_accepted-dma_completed <= 1)
                else $fatal(1, "DMA outstanding count");
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
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

    initial begin : run
        logic [31:0] value;
        xlen_t ignored;
        int before_dma;
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
        m_request[1] = '0;
        m_request[1].addr = xlen_t'(DTCM_BASE+32'h100);
        m_request[1].size = MEM_WORD;
        m_req_valid[1] = 1;
        m_rsp_ready[1] = 1;
        repeat (30) tick();
        m_req_valid[1] = 0;
        repeat (2) tick();
        m_rsp_ready[1] = 0;
        if (dma_accepted-before_dma < 2) $fatal(1, "continuous CPU D starved DMA");
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

        // 协调复位丢弃在途控制状态，但不承诺撤销先前已被外存接受的写入。
        wr(DMA_BASE+16, 4);
        start_copy(DTCM_BASE+32'h100, DDR_BASE+32'h600, 256);
        repeat (10) tick();
        if (!u_dma.u_engine.busy) $fatal(1, "DMA finished before coordinated reset");
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
        $display("PASS tb_dma_fabric RV%0d checks=%0d dma_requests=%0d external_writes=%0d",
                 XLEN, checks, dma_accepted, ddr_writes);
        $finish;
    end
    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "DMA fabric timeout");
    end
endmodule
