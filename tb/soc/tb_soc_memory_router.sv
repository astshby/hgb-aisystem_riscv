// Module: tb_soc_memory_router
// Description: Checks hot/slow ownership, invalid-access routing, same-edge switches, response holding and reset.
module tb_soc_memory_router #(parameter bit LOCAL_TCM_ENABLE = 1'b0);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic s_req_valid = 0, s_req_ready, s_rsp_valid, s_rsp_ready = 0;
    bus_req_t s_request = '0;
    bus_rsp_t s_response;
    logic hot_req_valid, hot_req_ready = 0, hot_rsp_valid = 0, hot_rsp_ready, hot_bank;
    logic slow_req_valid, slow_req_ready, slow_rsp_valid = 0, slow_rsp_ready;
    logic slow_accept_enable = 0, slow_busy_q = 0;
    bus_req_t hot_request, slow_request;
    bus_rsp_t hot_response = '0, slow_response = '0;
    int accepted = 0, completed = 0, lower_accepted = 0, checks = 0;
    int transitions [2][2] = '{default:'{default:0}};
    soc_memory_router #(.ENABLE(LOCAL_TCM_ENABLE)) dut (.*);

    // 慢端模型代表原事务槽已寄存的出口，仍限制一笔在途；真实槽在接线 TB 中单独覆盖。
    assign slow_req_ready = slow_accept_enable && (!slow_busy_q || (slow_rsp_valid && slow_rsp_ready));
    always_ff @(posedge clk) begin
        if (rst)
            slow_busy_q <= 0;
        else if (slow_req_valid && slow_req_ready)
            slow_busy_q <= 1;
        else if (slow_rsp_valid && slow_rsp_ready)
            slow_busy_q <= 0;
    end

    always @(posedge clk) if (!rst) begin
        if (s_req_valid && s_req_ready) accepted++;
        if (s_rsp_valid && s_rsp_ready) completed++;
        if (hot_req_valid && hot_req_ready) lower_accepted++;
        if (slow_req_valid && slow_req_ready) lower_accepted++;
        assert (accepted == lower_accepted && accepted >= completed && accepted-completed <= 1)
            else $fatal(1, "router handshake cardinality/outstanding");
        assert (!(hot_req_valid && slow_req_valid)) else $fatal(1, "both request paths active");
    end else begin
        accepted = 0;
        completed = 0;
        lower_accepted = 0;
    end
    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask
    task automatic pattern(input int n, output bus_req_t request,
                           output bus_rsp_t response, output bit hot);
        request = '0;
        request.addr = xlen_t'(ITCM_BASE + 4 * (n % 16));
        request.size = MEM_WORD;
        request.wdata = xlen_t'(64'h76543210_abcdef00 ^ 64'(n));
        request.wstrb = n[0] ? '0 : '1;
        response = '0;
        hot = 1'b0;
        // 错误码来自明确列出的边界，不以 DUT 的译码输出构造期望值。
        case (n % 10)
            0: begin request.execute = 1; hot = 1; end
            1: begin request.addr = xlen_t'(DTCM_BASE + 4); request.write = 1; hot = 1; end
            2: request.addr = xlen_t'(SOC_BASE);
            3: begin request.addr = xlen_t'(ITCM_BASE + 1); response.error = BUS_SLVERR; end
            4: begin request.addr = xlen_t'(DTCM_BASE); request.execute = 1; response.error = BUS_SLVERR; end
            5: begin
                if (XLEN == 64) begin
                    request.addr = xlen_t'(64'h1_01000000);
                    response.error = BUS_DECERR;
                end else begin
                    request.size = MEM_DWORD;
                    response.error = BUS_SLVERR;
                end
            end
            6: begin request.execute = 1; request.write = 1; response.error = BUS_SLVERR; end
            7: begin request.addr = xlen_t'(32'h20000000); response.error = BUS_DECERR; end
            8: begin request.size = MEM_BYTE; request.write = 1; request.addr += 1; hot = 1; end
            9: begin request.addr = xlen_t'(ITCM_BASE + 65535); response.error = BUS_SLVERR; end
        endcase
        hot = hot && LOCAL_TCM_ENABLE;
        response.rdata = request.addr ^ ~request.wdata;
    endtask
    task automatic accept_first(input int n);
        bus_rsp_t ignored;
        bit hot;
        pattern(n, s_request, ignored, hot);
        s_req_valid = 1;
        hot_req_ready = 0;
        slow_accept_enable = 0;
        repeat (2) begin
            tick();
            assert (!s_req_ready && !s_rsp_valid &&
                    hot_req_valid == hot && slow_req_valid == !hot)
                else $fatal(1, "request did not wait on selected path n=%0d", n);
        end
        hot_req_ready = 1;
        slow_accept_enable = 1;
        #1;
        assert (s_req_ready && (hot ? hot_request == s_request : slow_request == s_request))
            else $fatal(1, "request payload/routing n=%0d", n);
        if (hot) assert (hot_bank == (n % 10 == 1)) else $fatal(1, "TCM bank selection");
        tick();
        s_req_valid = 0;
        s_request = '1;
    endtask
    task automatic present_response(input int n, output bus_rsp_t expected, output bit hot);
        bus_req_t ignored;
        pattern(n, ignored, expected, hot);
        s_rsp_ready = 0;
        hot_rsp_valid = hot;
        slow_rsp_valid = !hot;
        hot_response = expected;
        slow_response = expected;
        #1;
        if (hot) begin
            assert (hot_rsp_ready && !s_rsp_valid)
                else $fatal(1, "hot response bypassed FF or depends on source ready");
            tick();
            hot_rsp_valid = 0;
            hot_response = '1;
        end else begin
            assert (!slow_rsp_ready)
                else $fatal(1, "slow response ignored source backpressure");
        end
        #1;
        assert (s_rsp_valid && s_response == expected)
            else $fatal(1, "response changed ownership n=%0d", n);
    endtask

    initial begin
        bus_req_t next_request;
        bus_rsp_t expected, ignored_response;
        bit old_hot, next_hot;
        repeat (3) tick();
        rst = 0;
        accept_first(0);
        for (int n = 0; n < 40; n++) begin
            present_response(n, expected, old_hot);
            pattern(n + 1, next_request, ignored_response, next_hot);
            s_req_valid = n != 39;
            s_request = next_request;
            repeat (2 + n % 3) begin
                tick();
                assert (!s_req_ready && !(hot_req_valid && hot_req_ready) &&
                        !(slow_req_valid && slow_req_ready) &&
                        s_rsp_valid && s_response == expected)
                    else $fatal(1, "pending successor changed held response");
            end
            s_rsp_ready = 1;
            #1;
            assert (s_rsp_valid && s_response == expected && s_req_ready)
                else $fatal(1, "release/refill unavailable");
            if (n != 39) begin
                assert (hot_req_valid == next_hot && slow_req_valid == !next_hot)
                    else $fatal(1, "same-edge switch selected old request route");
                transitions[int'(old_hot)][int'(next_hot)]++;
            end
            tick();
            s_req_valid = 0;
            s_request = '1;
            s_rsp_ready = 0;
            slow_rsp_valid = 0;
            slow_response = '1;
            #1;
            assert (!s_rsp_valid) else $fatal(1, "old response replayed after route switch");
            checks++;
        end
        assert (accepted == 40 && completed == 40) else $fatal(1, "chain counts");
        if (LOCAL_TCM_ENABLE)
            for (int old_path = 0; old_path < 2; old_path++)
                for (int new_path = 0; new_path < 2; new_path++)
                    assert (transitions[old_path][new_path] > 0) else $fatal(1, "missing route switch");

        // HOT_WAIT、HOT_REPLY、SLOW_WAIT 均协调复位，不允许旧响应/新请求重放。
        for (int phase = 0; phase < 3; phase++) begin
            accept_first(phase == 2 ? 2 : 0);
            if (phase == 1) present_response(0, expected, old_hot);
            rst = 1;
            s_req_valid = 0;
            hot_rsp_valid = 0;
            slow_rsp_valid = 0;
            tick();
            rst = 0;
            #1;
            assert (!s_rsp_valid && !hot_req_valid && !slow_req_valid)
                else $fatal(1, "reset replayed a route owner");
        end
        // 未接受的 IF 撤回不产生事务；与接受后的取指必须排空不同。
        pattern(0, s_request, ignored_response, next_hot);
        hot_req_ready = 0;
        slow_accept_enable = 0;
        s_req_valid = 1;
        tick();
        assert (!s_req_ready && accepted == 0) else $fatal(1, "withdrawal setup");
        s_req_valid = 0;
        hot_req_ready = 1;
        slow_accept_enable = 1;
        tick();
        assert (accepted == 0 && !s_rsp_valid) else $fatal(1, "unaccepted IF withdrawal created a response");
        accept_first(0);
        present_response(0, expected, old_hot);
        s_rsp_ready = 1;
        tick();
        assert (accepted == 1 && completed == 1) else $fatal(1, "post-reset recovery");
        $display("PASS tb_soc_memory_router RV%0d local=%0d transactions=%0d switches=%0d/%0d/%0d/%0d reset_states=3 withdrawal=1 recovered=1",
                 XLEN, LOCAL_TCM_ENABLE, checks, transitions[0][0], transitions[0][1], transitions[1][0], transitions[1][1]);
        $finish;
    end
    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "memory router timeout");
    end
endmodule
