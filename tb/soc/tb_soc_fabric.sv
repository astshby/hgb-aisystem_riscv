// Module: tb_soc_fabric
// Description: Exercises two-master routing, arbitration, TCM lanes, ROM, and backpressure.
module tb_soc_fabric;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import soc_config_pkg::*;
    import bus_types_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic [1:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [2];
    bus_rsp_t m_response [2];
    logic [14:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready, raw_ready;
    logic [14:0] allow_request;
    bus_req_t s_request [15];
    bus_rsp_t s_response [15];
    bus_error_e s_error [15];
    int accepted [2], completed [2];
    int checks = 0;
    int before0, before1;
    xlen_t expected;
    bus_req_t held_request;
    always #5 clk = ~clk;

    bus_interconnect dut (
        .clk, .rst, .m_req_valid, .m_req_ready, .m_request,
        .m_rsp_valid, .m_rsp_ready, .m_response,
        .s_req_valid, .s_req_ready, .s_request, .s_error,
        .s_rsp_valid, .s_rsp_ready, .s_response
    );
    assign s_req_ready = raw_ready & allow_request;
    bus_error_slave u_error (
        .clk, .rst, .req_valid(s_req_valid[0] && allow_request[0]),
        .req_ready(raw_ready[0]), .req_error(s_error[0]),
        .rsp_valid(s_rsp_valid[0]), .rsp_ready(s_rsp_ready[0]), .response(s_response[0])
    );
    boot_rom u_rom (
        .clk, .rst, .req_valid(s_req_valid[1] && allow_request[1]),
        .req_ready(raw_ready[1]), .request(s_request[1]),
        .rsp_valid(s_rsp_valid[1]), .rsp_ready(s_rsp_ready[1]), .response(s_response[1])
    );
    for (genvar s = 2; s < 4; s++) begin : g_tcm
        tcm_controller #(.BASE(s == 2 ? ITCM_BASE : DTCM_BASE)) u_tcm (
            .clk, .rst, .req_valid(s_req_valid[s] && allow_request[s]),
            .req_ready(raw_ready[s]), .request(s_request[s]),
            .rsp_valid(s_rsp_valid[s]), .rsp_ready(s_rsp_ready[s]), .response(s_response[s])
        );
    end
    for (genvar s = 4; s < 15; s++) begin : g_absent
        assign raw_ready[s] = 1'b0;
        assign s_rsp_valid[s] = 1'b0;
        assign s_response[s] = '0;
    end

    // 计分板只在真正握手的上升沿计数；不把 valid 的保持当作新事务。
    always @(posedge clk) begin
        if (rst) begin
            for (int m = 0; m < 2; m++) begin
                accepted[m] = 0;
                completed[m] = 0;
            end
        end else begin
            for (int m = 0; m < 2; m++) begin
                if (m_req_valid[m] && m_req_ready[m]) accepted[m]++;
                if (m_rsp_valid[m] && m_rsp_ready[m]) completed[m]++;
                assert (accepted[m] >= completed[m] && accepted[m] - completed[m] <= 1)
                    else $fatal(1, "outstanding bound master=%0d accepted=%0d completed=%0d",
                                m, accepted[m], completed[m]);
            end
        end
    end

    // 所有激励在下降沿之后更新，下一上升沿接受，随后下降沿检查寄存结果。
    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic prepare(input int m, input xlen_t addr,
        input logic write, input xlen_t data, input mem_size_e size, input logic execute);
        m_request[m] = '0;
        m_request[m].addr = addr;
        m_request[m].write = write;
        m_request[m].wdata = data;
        m_request[m].wstrb = DBUS_BYTES'(((1 << (1 << size)) - 1) << (addr % xlen_t'(DBUS_BYTES)));
        m_request[m].size = size;
        m_request[m].execute = execute;
    endtask
    task automatic send(input int m);
        int cycles;
        m_req_valid[m] = 1'b1;
        #1;
        cycles = 0;
        while (!m_req_ready[m]) begin
            tick();
            #1;
            cycles++;
            assert (cycles < 20) else $fatal(1, "request timeout");
        end
        tick();
        m_req_valid[m] = 1'b0;
        #1;
    endtask
    task automatic check_response(input int m, input xlen_t data, input bus_error_e error);
        assert (m_rsp_valid[m] && m_response[m].rdata == data && m_response[m].error == error)
            else $fatal(1, "response m=%0d valid=%b data=%h/%h error=%0d/%0d",
                        m, m_rsp_valid[m], m_response[m].rdata, data, m_response[m].error, error);
        checks++;
    endtask
    task automatic consume(input int m);
        m_rsp_ready[m] = 1'b1;
        tick();
        m_rsp_ready[m] = 1'b0;
        #1;
        assert (!m_rsp_valid[m]) else $fatal(1, "duplicate response");
    endtask
    task automatic access(input int m, input xlen_t addr, input logic write,
        input xlen_t data, input mem_size_e size, input logic execute,
        input xlen_t result, input bus_error_e error);
        prepare(m, addr, write, data, size, execute);
        send(m);
        check_response(m, result, error);
        consume(m);
    endtask

    initial begin
        m_req_valid = '0;
        m_rsp_ready = '0;
        m_request[0] = '0;
        m_request[1] = '0;
        allow_request = '1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        expected = XLEN == 64 ? xlen_t'(64'h00028067_010002b7) : xlen_t'(32'h010002b7);
        access(0, xlen_t'(ROM_BASE), 0, 0, MEM_WORD, 1, expected, BUS_OK);
        // RV32 的 ROM 字节读取也返回对齐字，不能只在 addr==4 时返回 JALR。
        expected = XLEN == 64 ? xlen_t'(64'h00028067_010002b7) : xlen_t'(32'h00028067);
        access(1, xlen_t'(ROM_BASE) + 5, 0, 0, MEM_BYTE, 0, expected, BUS_OK);
        access(1, xlen_t'(ROM_BASE), 1, 0, MEM_WORD, 0, 0, BUS_SLVERR);
        access(0, xlen_t'(DTCM_BASE), 0, 0, MEM_WORD, 1, 0, BUS_SLVERR);
        access(1, xlen_t'(UART0_BASE), 0, 0, MEM_WORD, 0, 0, BUS_DECERR);
        access(1, xlen_t'(ITCM_BASE) + ITCM_BYTES, 0, 0, MEM_WORD, 0, 0, BUS_DECERR);
        access(1, xlen_t'(DDR_BASE), 0, 0, MEM_WORD, 0, 0, BUS_DECERR);
        if (XLEN == 64)
            access(1, xlen_t'(64'h00000001_01000000), 0, 0, MEM_WORD, 0, 0, BUS_DECERR);

        // D 主端口改写 I-TCM 后 I 主端口看到同一份数据；逐字节写保留其他通道。
        access(1, xlen_t'(ITCM_BASE), 1, '1, XLEN == 64 ? MEM_DWORD : MEM_WORD, 0, 0, BUS_OK);
        expected = '1;
        for (int b = 0; b < DBUS_BYTES; b++) begin
            prepare(1, xlen_t'(ITCM_BASE) + xlen_t'(b), 1, xlen_t'(b + 16) << (b*8), MEM_BYTE, 0);
            m_request[1].wstrb = DBUS_BYTES'(1 << b);
            send(1);
            check_response(1, 0, BUS_OK);
            consume(1);
            expected[b*8 +: 8] = 8'(b + 16);
            access(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1, expected, BUS_OK);
        end

        // 响应被阻塞时载荷必须保持；另一 bank 仍能完成事务。
        prepare(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1);
        send(0);
        prepare(0, xlen_t'(ROM_BASE), 0, 0, MEM_WORD, 1);
        m_req_valid[0] = 1'b1;
        access(1, xlen_t'(DTCM_BASE), 1, xlen_t'(32'h12345678), XLEN == 64 ? MEM_DWORD : MEM_WORD, 0, 0, BUS_OK);
        repeat (3) begin
            #1;
            check_response(0, expected, BUS_OK);
            assert (!m_req_ready[0]) else $fatal(1, "second request accepted while pending");
            tick();
        end
        m_req_valid[0] = 1'b0;
        consume(0);

        // 不同 bank 的两个请求在同一个上升沿接受。
        prepare(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1);
        prepare(1, xlen_t'(DTCM_BASE), 0, 0, MEM_WORD, 0);
        m_req_valid = 2'b11;
        #1;
        assert (m_req_ready == 2'b11) else $fatal(1, "independent banks serialized");
        tick();
        m_req_valid = '0;
        #1;
        check_response(0, expected, BUS_OK);
        check_response(1, xlen_t'(32'h12345678), BUS_OK);
        m_rsp_ready = 2'b11;
        tick();
        m_rsp_ready = '0;

        // 单 bank 连续请求同拍消费旧响应/接受新请求，不能平白插气泡。
        prepare(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1);
        m_req_valid[0] = 1'b1;
        m_rsp_ready[0] = 1'b1;
        for (int n = 0; n < 8; n++) begin
            #1;
            assert (m_req_ready[0]) else $fatal(1, "RAM throughput bubble");
            tick();
            #1;
            check_response(0, expected, BUS_OK);
        end
        m_req_valid[0] = 1'b0;
        tick();
        m_rsp_ready[0] = 1'b0;

        // 两主持续争用同 bank，不得饿死；同一响应只属于保存的 owner。
        prepare(1, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 0);
        before0 = accepted[0];
        before1 = accepted[1];
        m_req_valid = 2'b11;
        m_rsp_ready = 2'b11;
        repeat (12) begin
            #1;
            assert ($onehot(m_req_ready)) else $fatal(1, "same-bank grant invalid");
            tick();
            #1;
            assert ($onehot(m_rsp_valid)) else $fatal(1, "response owner invalid");
            if (m_rsp_valid[0]) check_response(0, expected, BUS_OK);
            if (m_rsp_valid[1]) check_response(1, expected, BUS_OK);
        end
        m_req_valid = '0;
        tick();
        m_rsp_ready = '0;
        assert (accepted[0] - before0 == 6 && accepted[1] - before1 == 6)
            else $fatal(1, "round-robin unfair");

        // 从端反压时新竞争者不能抢走已选请求；IF 撤回后则应释放锁。
        access(1, xlen_t'(ITCM_BASE) + DBUS_BYTES, 1, xlen_t'(32'h5a5aa5a5),
               XLEN == 64 ? MEM_DWORD : MEM_WORD, 0, 0, BUS_OK);
        // 先让主端口 0 完成一次访问，使下一轮优先级属于 1。
        // 此时先到但优先级较低的 0 必须能锁住被反压的请求。
        access(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1, expected, BUS_OK);
        allow_request[2] = 1'b0;
        prepare(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1);
        m_req_valid[0] = 1'b1;
        tick();
        held_request = s_request[2];
        prepare(1, xlen_t'(ITCM_BASE) + DBUS_BYTES, 0, 0, MEM_WORD, 0);
        m_req_valid[1] = 1'b1;
        repeat (3) begin
            tick();
            #1;
            assert (s_req_valid[2] && s_request[2] == held_request && m_req_ready == '0)
                else $fatal(1, "blocked grant changed");
        end
        m_req_valid[0] = 1'b0;
        tick();
        #1;
        assert (s_request[2] == m_request[1]) else $fatal(1, "withdrawn request locked bus");
        allow_request[2] = 1'b1;
        tick();
        m_req_valid[1] = 1'b0;
        #1;
        check_response(1, xlen_t'(32'h5a5aa5a5), BUS_OK);
        consume(1);

        // 复位抛弃在途响应，但不清空已写入的 RAM。
        prepare(1, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 0);
        send(1);
        rst = 1'b1;
        tick();
        rst = 1'b0;
        #1;
        assert (m_rsp_valid == '0) else $fatal(1, "reset kept response");
        access(0, xlen_t'(ITCM_BASE), 0, 0, MEM_WORD, 1, expected, BUS_OK);
        assert (accepted[0] == completed[0] && accepted[1] == completed[1])
            else $fatal(1, "transactions not drained");
        $display("PASS tb_soc_fabric RV%0d checks=%0d", XLEN, checks);
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "fabric watchdog");
    end
endmodule
