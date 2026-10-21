// Module: tb_bus_transaction_register
// Description: Checks registered isolation, same-edge turnover, ordering, backpressure, errors, and reset.
module tb_bus_transaction_register;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic s_req_valid = 1'b0, s_req_ready, s_rsp_valid, s_rsp_ready = 1'b0;
    logic m_req_valid, m_req_ready = 1'b0, m_rsp_valid = 1'b0, m_rsp_ready;
    bus_req_t s_request = '0, m_request;
    bus_rsp_t s_response, m_response = '0;
    bus_req_t expected_request;
    bus_rsp_t expected_response;
    int accepted = 0, issued = 0, returned = 0, completed = 0;
    int checks = 0, refill_checks = 0;
    always #5 clk = ~clk;
    bus_transaction_register dut (.*);

    // 在每个端点真实握手沿计数，不能因 valid 保持而重复发出或越过在途上限。
    always @(posedge clk) begin
        if (rst) begin
            accepted = 0;
            issued = 0;
            returned = 0;
            completed = 0;
        end else begin
            if (s_req_valid && s_req_ready) accepted++;
            if (m_req_valid && m_req_ready) issued++;
            if (m_rsp_valid && m_rsp_ready) returned++;
            if (s_rsp_valid && s_rsp_ready) completed++;
            assert (accepted >= issued && issued >= returned && returned >= completed &&
                    accepted - completed <= 1)
                else $fatal(1, "transaction ordering/count violation");
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic reset_boundary;
        rst = 1'b1;
        s_req_valid = 1'b0;
        s_rsp_ready = 1'b0;
        m_req_ready = 1'b0;
        m_rsp_valid = 1'b0;
        #1;
        assert (!(s_req_ready || s_rsp_valid || m_req_valid || m_rsp_ready))
            else $fatal(1, "handshake survived reset");
        tick();
        rst = 1'b0;
        #1;
        assert (s_req_ready && !m_req_valid && !s_rsp_valid && !m_rsp_ready)
            else $fatal(1, "old transaction replayed after reset");
    endtask

    task automatic build_request(input int n, output bus_req_t value);
        value = '0;
        value.addr = xlen_t'(64'h8000_0000 + 8*n);
        value.execute = (n % 3) == 0;
        value.write = (n % 3) == 1;
        value.size = mem_size_e'(n % (XLEN == 64 ? 4 : 3));
        value.wdata = xlen_t'(64'h1234_5678_9abc_def0 ^ (64'(n) << 32) ^ 64'(n));
        value.wstrb = DBUS_BYTES'(1 << (n % DBUS_BYTES));
    endtask

    task automatic accept_request(input int n);
        build_request(n, expected_request);
        s_req_valid = 1'b1;
        s_request = expected_request;
        m_req_ready = 1'b1;
        #1;
        assert (s_req_ready && !m_req_valid)
            else $fatal(1, "request has combinational bypass");
        tick();
        s_req_valid = 1'b0;
        s_request = '1;
        m_req_ready = 1'b0;
        #1;
        assert (!s_req_ready && m_req_valid && m_request == expected_request)
            else $fatal(1, "accepted request lost its payload");
    endtask

    task automatic issue_request;
        // 改变下游 ready 不得组合改变上游 ready；已接受的取指不能再撤销。
        m_req_ready = 1'b1;
        #1;
        assert (!s_req_ready && m_req_valid && m_request == expected_request)
            else $fatal(1, "request ready leaked upstream");
        tick();
        m_req_ready = 1'b0;
        #1;
        assert (!m_req_valid && !s_req_ready && m_rsp_ready && !s_rsp_valid)
            else $fatal(1, "request was replayed or slot released before response");
    endtask

    task automatic return_response(input int n);
        expected_response.rdata = ~expected_request.wdata;
        unique case (n % 3)
            0: expected_response.error = BUS_OK;
            1: expected_response.error = BUS_SLVERR;
            default: expected_response.error = BUS_DECERR;
        endcase
        m_response = expected_response;
        m_rsp_valid = 1'b1;
        s_rsp_ready = 1'b1;
        #1;
        assert (m_rsp_ready && !s_rsp_valid && !s_req_ready)
            else $fatal(1, "response has combinational bypass");
        tick();
        m_rsp_valid = 1'b0;
        m_response = '0;
        s_rsp_ready = 1'b0;
        #1;
        assert (s_rsp_valid && s_response == expected_response && !m_rsp_ready)
            else $fatal(1, "response lost data/error ownership");
    endtask

    task automatic offer_successor(input bus_req_t successor);
        // 这是真实后继请求；一旦声明 valid，必须保持到释放/重装沿或协调复位。
        s_req_valid = 1'b1;
        s_request = successor;
        #1;
        assert (!s_req_ready)
            else $fatal(1, "successor accepted before old response permission");
    endtask

    task automatic check_turnover(input int phase, input int n);
        bus_req_t successor;
        bus_rsp_t old_response;
        int before_accepted, before_completed;
        accept_request(101 + n);
        build_request(201 + n, successor);
        if (phase == 0) offer_successor(successor);
        repeat (2) begin
            tick();
            assert (m_req_valid && m_request == expected_request && !s_req_ready)
                else $fatal(1, "successor replaced held downstream request");
        end
        issue_request();
        if (phase == 1) offer_successor(successor);
        repeat (2) begin
            tick();
            assert (m_rsp_ready && !s_req_ready && !s_rsp_valid && !m_req_valid)
                else $fatal(1, "successor escaped while waiting for response");
        end
        return_response(n);
        old_response = expected_response;
        if (phase == 2) offer_successor(successor);
        repeat (1 + n % 4) begin
            tick();
            assert (s_rsp_valid && s_response == old_response && !s_req_ready &&
                    !m_req_valid && !m_rsp_ready && s_request == successor)
                else $fatal(1, "backpressured response lost old owner");
        end

        // 新请求与旧响应各自保留期望值，避免测试在交接沿提前覆盖旧 owner。
        before_accepted = accepted;
        before_completed = completed;
        s_rsp_ready = 1'b1;
        m_req_ready = 1'b1;
        #1;
        assert (s_req_ready && s_rsp_valid && s_response == old_response &&
                !m_req_valid && !m_rsp_ready)
            else $fatal(1, "release/refill lost registered isolation");
        m_req_ready = 1'b0;
        tick();
        s_req_valid = 1'b0;
        s_request = '1;
        s_rsp_ready = 1'b0;
        expected_request = successor;
        #1;
        assert (!s_req_ready && m_req_valid && m_request == successor &&
                !s_rsp_valid && !m_rsp_ready && s_response == old_response &&
                accepted == before_accepted + 1 && completed == before_completed + 1)
            else $fatal(1, "same-edge refill failed or duplicated old response");
        repeat (n % 3) begin
            tick();
            assert (m_req_valid && m_request == successor && !s_req_ready && !s_rsp_valid)
                else $fatal(1, "refilled request changed under backpressure");
        end
        issue_request();
        return_response(n + 1);
        s_rsp_ready = 1'b1;
        tick();
        s_rsp_ready = 1'b0;
        #1;
        assert (s_req_ready && !s_rsp_valid && accepted == completed)
            else $fatal(1, "refilled transaction did not drain exactly once");
        refill_checks++;
        checks += 2;
    endtask

    initial begin
        repeat (2) tick();
        reset_boundary();
        for (int n = 0; n < 96; n++) begin
            accept_request(n);
            // 无后继请求时只毒化无效载荷；不能声明假 valid 再为旧计数随意撤回。
            repeat (n % 5) begin
                tick();
                assert (m_req_valid && m_request == expected_request && !s_req_ready)
                    else $fatal(1, "held request changed");
            end
            issue_request();
            repeat (n % 7) begin
                tick();
                assert (!s_req_ready && !s_rsp_valid && !m_req_valid)
                    else $fatal(1, "waiting transaction escaped its slot");
            end
            return_response(n);
            repeat (n % 4) begin
                tick();
                assert (s_rsp_valid && s_response == expected_response && !s_req_ready)
                    else $fatal(1, "held response changed");
            end
            s_rsp_ready = 1'b1;
            #1;
            assert (s_req_ready && s_rsp_valid && s_response == expected_response &&
                    !m_rsp_ready && !m_req_valid)
                else $fatal(1, "response permission failed to release source slot");
            tick();
            s_req_valid = 1'b0;
            s_rsp_ready = 1'b0;
            #1;
            assert (s_req_ready && !s_rsp_valid && accepted == completed)
                else $fatal(1, "transaction did not drain exactly once");
            checks++;
        end
        assert (accepted == 96 && issued == 96 && returned == 96 && completed == 96)
            else $fatal(1, "missing endpoint coverage");

        // 后继分别从 SEND、WAIT、REPLY 等待；每种起点覆盖三种错误码和四种响应反压长度。
        for (int phase = 0; phase < 3; phase++)
            for (int n = 0; n < 12; n++)
                check_turnover(phase, n);
        assert (accepted == 168 && issued == 168 && returned == 168 && completed == 168)
            else $fatal(1, "missing turnover endpoint coverage");

        // SEND、WAIT、REPLY 三个状态均需协调复位，不能重发旧写或旧错误。
        accept_request(97);
        reset_boundary();
        accept_request(98);
        issue_request();
        reset_boundary();
        accept_request(99);
        issue_request();
        return_response(99);
        reset_boundary();
        accept_request(100);
        issue_request();
        return_response(100);
        build_request(101, s_request);
        offer_successor(s_request);
        s_rsp_ready = 1'b1;
        #1;
        assert (s_req_ready && s_rsp_valid) else $fatal(1, "reset test missed refill window");
        // 双方已准备交接但尚无时钟沿；协调复位必须压住所有握手，而非接收再重放。
        rst = 1'b1;
        #1;
        assert (!(s_req_ready || s_rsp_valid || m_req_valid || m_rsp_ready))
            else $fatal(1, "refill handshake survived reset");
        tick();
        s_req_valid = 1'b0;
        s_rsp_ready = 1'b0;
        rst = 1'b0;
        #1;
        assert (s_req_ready && !s_rsp_valid && !m_req_valid && !m_rsp_ready && accepted == 0)
            else $fatal(1, "reset replayed successor or old response");
        accept_request(102);
        issue_request();
        return_response(102);
        s_rsp_ready = 1'b1;
        tick();
        assert (accepted == 1 && issued == 1 && returned == 1 && completed == 1)
            else $fatal(1, "transaction did not recover after reply reset");
        $display("PASS tb_bus_transaction_register RV%0d transactions=%0d refill_pairs=%0d reset_states=3 reset_refill=1 recovered=1",
                 XLEN, checks, refill_checks);
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "transaction register timeout");
    end
endmodule
