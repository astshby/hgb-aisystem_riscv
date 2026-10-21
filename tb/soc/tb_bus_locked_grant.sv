// Module: tb_bus_locked_grant
// Description: Checks locked grants against late contenders, exact endpoint fires, and stable payloads.
module tb_bus_locked_grant #(
    parameter bit DATA_PRIORITY = 1'b1
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;

    localparam int BANK = int'(TARGET_ITCM);
    logic clk = 1'b0, rst = 1'b1;
    logic [2:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request[3];
    bus_rsp_t m_response[3];
    logic [14:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request[15];
    bus_rsp_t s_response[15];
    bus_error_e s_error[15];
    logic allow_request;
    logic [2:0] accepted_this_edge, pending;
    xlen_t expected_response[3];
    int accepted[3], completed[3];
    logic held_valid;
    bus_req_t held_request;
    bus_error_e held_error;
    int checks = 0, stalled_cycles = 0, handoffs = 0;

    always #5 clk = ~clk;
    bus_interconnect #(.MASTERS(3), .DATA_PRIORITY(DATA_PRIORITY)) dut (.*);

    // 通用从端可任意反压，不依赖 TCM ready 的特殊实现；响应寄存并保持至接收。
    assign s_req_ready[BANK] = allow_request && (!s_rsp_valid[BANK] || s_rsp_ready[BANK]);
    for (genvar s = 0; s < 15; s++) begin : g_other_bank
        if (s != BANK) begin
            assign s_req_ready[s] = 1'b0;
            assign s_rsp_valid[s] = 1'b0;
            assign s_response[s] = '0;
        end
    end
    function automatic xlen_t response_value(input bus_req_t request);
        return request.addr ^ request.wdata ^ xlen_t'(64'h9876_5432_1234_5678);
    endfunction
    always_ff @(posedge clk) begin
        if (rst) begin
            s_rsp_valid[BANK] <= 1'b0;
            s_response[BANK] <= '0;
        end else begin
            if (s_rsp_valid[BANK] && s_rsp_ready[BANK]) s_rsp_valid[BANK] <= 1'b0;
            if (s_req_valid[BANK] && s_req_ready[BANK]) begin
                s_rsp_valid[BANK] <= 1'b1;
                s_response[BANK].rdata <= response_value(s_request[BANK]);
                s_response[BANK].error <= s_error[BANK];
            end
        end
    end

    // 计分只用主/从两端真实 fire 和载荷，不读取 grant/owner 作参考答案。
    // 同沿先消费旧响应，再记录新请求，覆盖 D/DMA 的无气泡交接。
    always @(posedge clk) begin
        int request_count, response_count, request_owner;
        if (rst) begin
            pending = '0;
            accepted_this_edge = '0;
            held_valid = 1'b0;
            for (int m = 0; m < 3; m++) begin
                accepted[m] = 0;
                completed[m] = 0;
                expected_response[m] = '0;
            end
        end else begin
            request_count = 0;
            response_count = 0;
            request_owner = -1;
            accepted_this_edge = m_req_valid & m_req_ready;
            for (int m = 0; m < 3; m++) begin
                if (m_rsp_valid[m]) begin
                    assert (pending[m] && m_response[m].rdata == expected_response[m] &&
                            m_response[m].error == BUS_OK)
                        else $fatal(1, "response owner/payload mismatch master=%0d", m);
                end
                if (m_rsp_valid[m] && m_rsp_ready[m]) begin
                    response_count++;
                    pending[m] = 1'b0;
                    completed[m]++;
                end
                if (accepted_this_edge[m]) begin
                    request_count++;
                    request_owner = m;
                end
            end
            assert (request_count == int'(s_req_valid[BANK] && s_req_ready[BANK]))
                else $fatal(1, "request fire mismatch master_fires=%0d slave_fire=%b ready=%b valid=%b",
                            request_count, s_req_valid[BANK] && s_req_ready[BANK], m_req_ready, m_req_valid);
            assert (response_count == int'(s_rsp_valid[BANK] && s_rsp_ready[BANK]))
                else $fatal(1, "response fire mismatch master_fires=%0d", response_count);
            if (request_count != 0) begin
                assert (!pending[request_owner] && s_request[BANK] == m_request[request_owner] &&
                        s_error[BANK] == BUS_OK)
                    else $fatal(1, "request owner/payload mismatch master=%0d", request_owner);
                pending[request_owner] = 1'b1;
                expected_response[request_owner] = response_value(m_request[request_owner]);
                accepted[request_owner]++;
                if (response_count != 0) handoffs++;
            end
            if (held_valid)
                assert (s_req_valid[BANK] && s_request[BANK] == held_request && s_error[BANK] == held_error)
                    else $fatal(1, "locked request changed before slave acceptance");
            held_valid = s_req_valid[BANK] && !s_req_ready[BANK];
            if (held_valid) begin
                held_request = s_request[BANK];
                held_error = s_error[BANK];
                stalled_cycles++;
            end
        end
    end

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic drain_requests;
        int timeout_cycles;
        timeout_cycles = 0;
        while ((|m_req_valid) || (|pending) || s_rsp_valid[BANK]) begin
            tick();
            m_req_valid &= ~accepted_this_edge;
            timeout_cycles++;
            assert (timeout_cycles < 50) else $fatal(1, "locked grant test drain timeout");
        end
        #1;
    endtask
    task automatic initialize;
        @(negedge clk);
        rst = 1'b1;
        m_req_valid = '0;
        m_rsp_ready = '1;
        allow_request = 1'b1;
        for (int m = 0; m < 3; m++) begin
            m_request[m] = '0;
            m_request[m].addr = xlen_t'(ITCM_BASE) + xlen_t'(16*m);
            m_request[m].size = MEM_WORD;
            m_request[m].execute = m == 0;
            m_request[m].write = m != 0;
            m_request[m].wdata = xlen_t'(64'hfedc_ba98_0000_0000) | xlen_t'(m + 1);
            m_request[m].wstrb = DBUS_BYTES'(15);
        end
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    endtask

    initial begin
        // 先由 D 成功访问，使轮询下一位指向 DMA；随后只由 D 在 ready=0 时锁定。
        // 新 DMA 到达不能推翻既有 D 的锁，更不能只在主端压 ready 而让从端 fire。
        for (int owner = 1; owner < 4; owner++) begin
            int selected;
            selected = owner % 3;
            initialize();
            m_req_valid = 3'b010;
            drain_requests();
            allow_request = 1'b0;
            m_req_valid = 3'(1 << selected);
            tick();
            m_req_valid = 3'b111;
            repeat (3) tick();
            allow_request = 1'b1;
            tick();
            assert (accepted_this_edge == 3'(1 << selected))
                else $fatal(1, "late contender replaced locked owner=%0d fires=%b", selected, accepted_this_edge);
            m_req_valid &= ~accepted_this_edge;
            drain_requests();
            checks++;
        end

        // 满响应槽阻止新请求；释放后返回必须仍属于原主端，载荷保持由独立计分检查。
        initialize();
        m_rsp_ready = '0;
        m_req_valid = 3'b010;
        tick();
        assert (accepted_this_edge == 3'b010) else $fatal(1, "response hold setup");
        m_req_valid = 3'b101;
        repeat (4) begin
            tick();
            assert (accepted_this_edge == '0 && m_rsp_valid == 3'b010)
                else $fatal(1, "busy slave accepted younger request or lost owner");
        end
        m_rsp_ready = '1;
        drain_requests();
        checks++;

        // 无锁时维持原 D/DMA 轮询，不借修复让 D 永久优先于 DMA。
        initialize();
        m_req_valid = 3'b110;
        for (int cycle = 0; cycle < 24; cycle++) begin
            tick();
            assert ($onehot(accepted_this_edge) && accepted[1] >= accepted[2] &&
                    accepted[1] - accepted[2] <= 1)
                else $fatal(1, "D/DMA round-robin fairness or throughput changed");
        end
        m_req_valid = '0;
        drain_requests();
        assert (accepted[1] == 12 && accepted[2] == 12 && completed[1] == 12 && completed[2] == 12)
            else $fatal(1, "D/DMA transaction counts differ");
        checks++;
        assert (stalled_cycles >= 12 && handoffs >= 23) else $fatal(1, "protocol coverage missing");
        $display("PASS tb_bus_locked_grant RV%0d priority=%0d checks=%0d stalled=%0d handoffs=%0d",
                 XLEN, DATA_PRIORITY, checks, stalled_cycles, handoffs);
        $finish;
    end
    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "locked grant test timeout");
    end
endmodule
