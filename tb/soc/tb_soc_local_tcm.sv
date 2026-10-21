// Module: tb_soc_local_tcm
// Description: Compares local/registered TCM paths with independent memory and handshake scoreboards.
module tb_soc_local_tcm #(
    parameter bit LOCAL_TCM_ENABLE = 1'b0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;
    localparam int EXPECT_INTERVAL = LOCAL_TCM_ENABLE ? 2 : 3;
    localparam int EXPECT_LATENCY = LOCAL_TCM_ENABLE ? 2 : 3;
    localparam int WORDS = 32;
    localparam int TRANSACTIONS = 48;
    localparam int SERVICE_BOUND = 256;
    localparam logic [31:0] SEED = 32'h7351cafe;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic [2:0] m_req_valid, m_req_ready, m_rsp_valid, m_rsp_ready;
    bus_req_t m_request [3];
    bus_rsp_t m_response [3];
    logic [2:0] f_req_valid, f_req_ready, f_rsp_valid, f_rsp_ready;
    bus_req_t f_request [3];
    bus_rsp_t f_response [3];
    logic [14:0] s_req_valid, s_req_ready, s_rsp_valid, s_rsp_ready;
    bus_req_t s_request [15];
    bus_rsp_t s_response [15];
    bus_error_e s_error [15];
    logic [1:0] bank_allow, bank_ready, bank_req_valid, bank_rsp_valid, bank_rsp_ready;
    bus_req_t bank_request [2];
    bus_rsp_t bank_response [2];
    logic [2:0] hot_req_valid, hot_req_ready, hot_rsp_valid, hot_rsp_ready, hot_bank;
    bus_req_t hot_request [3];
    bus_rsp_t hot_response [3];
    logic [2:0] slow_req_valid, slow_req_ready, slow_rsp_valid, slow_rsp_ready;
    bus_req_t slow_request [3];
    bus_rsp_t slow_response [3];
    logic [2:0] slow_f_req_valid, slow_f_req_ready, slow_f_rsp_valid, slow_f_rsp_ready;
    bus_req_t slow_f_request [3];
    bus_rsp_t slow_f_response [3];
    logic [31:0] random_q = SEED;
    xlen_t reference_mem [2][WORDS];
    bus_req_t accepted_request [3], held_m_request [3], held_f_request [3];
    bus_rsp_t expected_response [3], held_m_response [3], held_f_response [3];
    logic [2:0] hold_m_req, hold_f_req, hold_m_rsp, hold_f_rsp;
    bus_req_t held_s_request [15];
    bus_rsp_t held_s_response [15];
    logic [14:0] hold_s_req, hold_s_rsp;
    int accepted [3], issued [3], returned [3], completed [3], quota [3];
    int accept_cycle [3], last_accept [3], first_accept [3], last_complete [3];
    int interval_min [3], interval_max [3], interval_sum [3];
    int latency_min [3], latency_max [3], latency_sum [3];
    int request_stalls [3], response_stalls [3], issue_wait [3], max_issue_wait [3];
    logic [2:0] offer_pending;
    int offer_cycle [3], accepted_offer_cycle [3];
    int offer_wait_max [3], offer_wait_sum [3], total_latency_max [3], total_latency_sum [3];
    int effective_bytes [3], bank_accepts [2], bank_completes [2];
    int cycle_count, scenario, scenarios = 0, total_transactions = 0;
    int writes_expected, writes_observed, errors_expected, parallel_cycles;
    int total_writes = 0, total_errors = 0;
    string scenario_name;

    function automatic xlen_t initial_word(input int bank, input int word_index);
        xlen_t value;
        for (int b = 0; b < DBUS_BYTES; b++)
            value[b*8 +: 8] = 8'(bank * 97 + word_index * 13 + b * 19);
        return value;
    endfunction

    for (genvar m = 0; m < 3; m++) begin : g_register
        soc_memory_router #(.ENABLE(LOCAL_TCM_ENABLE)) u_router (
            .clk, .rst,
            .s_req_valid(m_req_valid[m]), .s_req_ready(m_req_ready[m]), .s_request(m_request[m]),
            .s_rsp_valid(m_rsp_valid[m]), .s_rsp_ready(m_rsp_ready[m]), .s_response(m_response[m]),
            .hot_req_valid(hot_req_valid[m]), .hot_req_ready(hot_req_ready[m]), .hot_request(hot_request[m]),
            .hot_bank(hot_bank[m]), .hot_rsp_valid(hot_rsp_valid[m]),
            .hot_rsp_ready(hot_rsp_ready[m]), .hot_response(hot_response[m]),
            .slow_req_valid(slow_req_valid[m]), .slow_req_ready(slow_req_ready[m]), .slow_request(slow_request[m]),
            .slow_rsp_valid(slow_rsp_valid[m]), .slow_rsp_ready(slow_rsp_ready[m]), .slow_response(slow_response[m])
        );
        bus_transaction_register u_register (
            .clk, .rst,
            .s_req_valid(slow_req_valid[m]), .s_req_ready(slow_req_ready[m]), .s_request(slow_request[m]),
            .s_rsp_valid(slow_rsp_valid[m]), .s_rsp_ready(slow_rsp_ready[m]), .s_response(slow_response[m]),
            .m_req_valid(slow_f_req_valid[m]), .m_req_ready(slow_f_req_ready[m]), .m_request(slow_f_request[m]),
            .m_rsp_valid(slow_f_rsp_valid[m]), .m_rsp_ready(slow_f_rsp_ready[m]), .m_response(slow_f_response[m])
        );
        // 两路的真实端点事件合并给计分板；不使用当前源地址猜测返回归属。
        assign f_req_valid[m] = hot_req_valid[m] || slow_f_req_valid[m];
        assign f_req_ready[m] = hot_req_valid[m] ? hot_req_ready[m] : slow_f_req_ready[m];
        assign f_request[m] = hot_req_valid[m] ? hot_request[m] : slow_f_request[m];
        assign f_rsp_valid[m] = hot_rsp_valid[m] || slow_f_rsp_valid[m];
        assign f_rsp_ready[m] = hot_rsp_valid[m] ? hot_rsp_ready[m] : slow_f_rsp_ready[m];
        assign f_response[m] = hot_rsp_valid[m] ? hot_response[m] : slow_f_response[m];
        always @(posedge clk) if (!rst) begin
            assert (!(hot_req_valid[m] && slow_f_req_valid[m]) &&
                    !(hot_rsp_valid[m] && slow_f_rsp_valid[m]))
                else $fatal(1, "hot/slow paths simultaneously own a master");
        end
    end
    bus_interconnect #(.MASTERS(3), .PRESENT(LOCAL_TCM_ENABLE ? 15'h0001 : 15'h000d),
                       .DATA_PRIORITY(1'b1)) u_fabric (
        .clk, .rst, .m_req_valid(slow_f_req_valid), .m_req_ready(slow_f_req_ready), .m_request(slow_f_request),
        .m_rsp_valid(slow_f_rsp_valid), .m_rsp_ready(slow_f_rsp_ready), .m_response(slow_f_response),
        .s_req_valid, .s_req_ready, .s_request, .s_error, .s_rsp_valid, .s_rsp_ready, .s_response
    );
    if (LOCAL_TCM_ENABLE) begin
        tcm_local_fabric u_local (
            .clk, .rst, .m_req_valid(hot_req_valid), .m_req_ready(hot_req_ready),
            .m_request(hot_request), .m_bank(hot_bank), .m_rsp_valid(hot_rsp_valid),
            .m_rsp_ready(hot_rsp_ready), .m_response(hot_response),
            .s_req_valid(bank_req_valid), .s_req_ready(bank_ready & bank_allow), .s_request(bank_request),
            .s_rsp_valid(bank_rsp_valid), .s_rsp_ready(bank_rsp_ready), .s_response(bank_response)
        );
        for (genvar b = 0; b < 2; b++) begin : g_disable_slow_bank
            assign s_req_ready[b+2] = 1'b0;
            assign s_rsp_valid[b+2] = 1'b0;
            assign s_response[b+2] = '0;
        end
    end else begin
        assign hot_req_ready = '0;
        assign hot_rsp_valid = '0;
        for (genvar m = 0; m < 3; m++) begin : g_disable_hot
            assign hot_response[m] = '0;
        end
        for (genvar b = 0; b < 2; b++) begin : g_connect_slow_bank
            assign bank_req_valid[b] = s_req_valid[b+2];
            assign bank_request[b] = s_request[b+2];
            assign s_req_ready[b+2] = bank_ready[b] && bank_allow[b];
            assign s_rsp_valid[b+2] = bank_rsp_valid[b];
            assign bank_rsp_ready[b] = s_rsp_ready[b+2];
            assign s_response[b+2] = bank_response[b];
        end
    end
    bus_error_slave u_error (
        .clk, .rst, .req_valid(s_req_valid[0]), .req_ready(s_req_ready[0]),
        .req_error(s_error[0]), .rsp_valid(s_rsp_valid[0]),
        .rsp_ready(s_rsp_ready[0]), .response(s_response[0])
    );
    for (genvar bank = 0; bank < 2; bank++) begin : g_tcm
        // 同时门控 valid/ready，只注入请求等待，不改变真实 TCM 的同步读语义。
        tcm_controller #(.BASE(bank == 0 ? ITCM_BASE : DTCM_BASE), .BYTES(WORDS * DBUS_BYTES)) u_tcm (
            .clk, .rst, .req_valid(bank_req_valid[bank] && bank_allow[bank]),
            .req_ready(bank_ready[bank]), .request(bank_request[bank]),
            .rsp_valid(bank_rsp_valid[bank]), .rsp_ready(bank_rsp_ready[bank]),
            .response(bank_response[bank])
        );
        initial begin
            for (int w = 0; w < WORDS; w++)
                u_tcm.mem[w] = initial_word(bank, w);
        end
        // 参考内存只由主端已发出的事务更新；这里独立比对所有物理字节副作用。
        always @(negedge clk) begin
            if (!rst)
                for (int w = 0; w < WORDS; w++)
                    assert (u_tcm.mem[w] === reference_mem[bank][w])
                        else $fatal(1, "memory side effect bank=%0d word=%0d cycle=%0d", bank, w, cycle_count);
        end
    end
    for (genvar s = 1; s < 15; s++) begin : g_absent
        if (s != 2 && s != 3) begin
            assign s_req_ready[s] = 1'b0;
            assign s_rsp_valid[s] = 1'b0;
            assign s_response[s] = '0;
        end
    end

    function automatic bus_req_t make_request(input int master, input int sequence_id);
        bus_req_t request;
        int bank, word_index, lane;
        request = '0;
        bank = (scenario == 3) ? 0 : (master == 0 ? 0 : 1);
        if (scenario == 4 && master != 0) bank = (sequence_id / 4 + master) % 2;
        word_index = (sequence_id / 3 + master * 7) % WORDS;
        request.addr = (bank == 0 ? xlen_t'(ITCM_BASE) : xlen_t'(DTCM_BASE)) + xlen_t'(word_index * DBUS_BYTES);
        request.execute = master == 0;
        request.size = MEM_WORD;
        request.write = master != 0 && sequence_id % 3 == 0;
        request.wdata = initial_word(master + 2, sequence_id + scenario * 17);
        request.wstrb = DBUS_BYTES'('1);
        if (master != 0) request.size = XLEN == 64 ? MEM_DWORD : MEM_WORD;
        if (request.write && sequence_id % 2 == 0) begin
            lane = (sequence_id / 6) % DBUS_BYTES;
            request.size = MEM_BYTE;
            request.addr += xlen_t'(lane);
            request.wstrb = DBUS_BYTES'(1 << lane);
        end
        // 错误请求也必须归还原 owner；无效写不允许碰到 TCM。
        if (scenario == 4 && sequence_id % 11 == 10)
            request.addr = xlen_t'(32'h20000000);
        return request;
    endfunction

    // 计分板先消费旧响应，再接受新请求、最后核对端点接受；热路源/bank 可同沿握手。
    // 连续 valid 可提前等待，但任何时候已接受且未完成的事务数不得大于一。
    always @(posedge clk) begin
        int master_fires, slave_fires;
        if (rst) begin
            cycle_count = 0;
            writes_expected = 0;
            writes_observed = 0;
            errors_expected = 0;
            parallel_cycles = 0;
            hold_m_req = '0; hold_f_req = '0; hold_m_rsp = '0; hold_f_rsp = '0;
            offer_pending = '0;
            hold_s_req = '0; hold_s_rsp = '0;
            for (int m = 0; m < 3; m++) begin
                accepted[m] = 0; issued[m] = 0; returned[m] = 0; completed[m] = 0;
                accept_cycle[m] = 0; last_accept[m] = 0; first_accept[m] = 0; last_complete[m] = 0;
                interval_min[m] = 100000; interval_max[m] = 0; interval_sum[m] = 0;
                latency_min[m] = 100000; latency_max[m] = 0; latency_sum[m] = 0;
                request_stalls[m] = 0; response_stalls[m] = 0;
                issue_wait[m] = 0; max_issue_wait[m] = 0;
                offer_cycle[m] = 0; accepted_offer_cycle[m] = 0;
                offer_wait_max[m] = 0; offer_wait_sum[m] = 0;
                total_latency_max[m] = 0; total_latency_sum[m] = 0;
                effective_bytes[m] = 0;
            end
            for (int b = 0; b < 2; b++) begin bank_accepts[b] = 0; bank_completes[b] = 0; end
        end else begin
            cycle_count++;
            master_fires = 0;
            slave_fires = 0;
            for (int s = 0; s < 15; s++) begin
                if (hold_s_req[s])
                    assert (s_req_valid[s] && s_request[s] === held_s_request[s]) else $fatal(1, "slave request changed s=%0d", s);
                if (hold_s_rsp[s])
                    assert (s_rsp_valid[s] && s_response[s] === held_s_response[s]) else $fatal(1, "slave response changed s=%0d", s);
                hold_s_req[s] = s_req_valid[s] && !s_req_ready[s]; held_s_request[s] = s_request[s];
                hold_s_rsp[s] = s_rsp_valid[s] && !s_rsp_ready[s]; held_s_response[s] = s_response[s];
                if (s == 0 && s_req_valid[s] && s_req_ready[s]) slave_fires++;
            end
            if (&(bank_req_valid & bank_ready & bank_allow)) parallel_cycles++;
            for (int b = 0; b < 2; b++) begin
                if (bank_req_valid[b] && bank_ready[b] && bank_allow[b]) begin
                    slave_fires++;
                    bank_accepts[b]++;
                    if (bank_request[b].write) writes_observed++;
                end
                if (bank_rsp_valid[b] && bank_rsp_ready[b]) bank_completes[b]++;
            end
            for (int m = 0; m < 3; m++) begin
                // 每笔 valid 首次在采样沿出现即记 offer；等待期间不重置，不能隐藏握手前仲裁。
                if (m_req_valid[m] && !offer_pending[m]) begin
                    offer_pending[m] = 1'b1;
                    offer_cycle[m] = cycle_count;
                end
                if (hold_m_req[m])
                    assert (m_req_valid[m] && m_request[m] === held_m_request[m]) else $fatal(1, "upper request changed m=%0d", m);
                if (hold_f_req[m])
                    assert (f_req_valid[m] && f_request[m] === held_f_request[m]) else $fatal(1, "lower request changed m=%0d", m);
                if (hold_m_rsp[m])
                    assert (m_rsp_valid[m] && m_response[m] === held_m_response[m]) else $fatal(1, "upper response changed m=%0d", m);
                if (hold_f_rsp[m])
                    assert (f_rsp_valid[m] && f_response[m] === held_f_response[m]) else $fatal(1, "lower response changed m=%0d", m);
                hold_m_req[m] = m_req_valid[m] && !m_req_ready[m]; held_m_request[m] = m_request[m];
                hold_f_req[m] = f_req_valid[m] && !f_req_ready[m]; held_f_request[m] = f_request[m];
                hold_m_rsp[m] = m_rsp_valid[m] && !m_rsp_ready[m]; held_m_response[m] = m_response[m];
                hold_f_rsp[m] = f_rsp_valid[m] && !f_rsp_ready[m]; held_f_response[m] = f_response[m];
                if (hold_f_req[m]) begin
                    request_stalls[m]++;
                    issue_wait[m]++;
                    if (issue_wait[m] > max_issue_wait[m]) max_issue_wait[m] = issue_wait[m];
                end else issue_wait[m] = 0;
                if (hold_m_rsp[m]) response_stalls[m]++;

                if (m_rsp_valid[m] && m_rsp_ready[m]) begin
                    int latency, total_latency;
                    assert (completed[m] < returned[m] && m_response[m] === expected_response[m])
                        else $fatal(1, "upper response owner/data/error m=%0d count=%0d got=%h expected=%h", m, completed[m], m_response[m], expected_response[m]);
                    latency = cycle_count - accept_cycle[m];
                    if (latency < latency_min[m]) latency_min[m] = latency;
                    if (latency > latency_max[m]) latency_max[m] = latency;
                    latency_sum[m] += latency;
                    total_latency = cycle_count - accepted_offer_cycle[m];
                    if (total_latency > total_latency_max[m]) total_latency_max[m] = total_latency;
                    total_latency_sum[m] += total_latency;
                    if (scenario < 3)
                        assert (latency == EXPECT_LATENCY) else $fatal(1, "latency measured=%0d expected=%0d", latency, EXPECT_LATENCY);
                    completed[m]++;
                    last_complete[m] = cycle_count;
                end
                if (f_rsp_valid[m] && f_rsp_ready[m]) begin
                    assert (returned[m] < issued[m] && f_response[m] === expected_response[m])
                        else $fatal(1, "lower response owner/data/error m=%0d got=%h expected=%h", m, f_response[m], expected_response[m]);
                    returned[m]++;
                end
                if (m_req_valid[m] && m_req_ready[m]) begin
                    int offer_wait;
                    offer_wait = cycle_count - offer_cycle[m];
                    if (offer_wait > offer_wait_max[m]) offer_wait_max[m] = offer_wait;
                    offer_wait_sum[m] += offer_wait;
                    accepted_offer_cycle[m] = offer_cycle[m];
                    offer_pending[m] = 1'b0;
                    if (accepted[m] != 0) begin
                        int interval_cycles;
                        interval_cycles = cycle_count - last_accept[m];
                        if (interval_cycles < interval_min[m]) interval_min[m] = interval_cycles;
                        if (interval_cycles > interval_max[m]) interval_max[m] = interval_cycles;
                        interval_sum[m] += interval_cycles;
                        if (scenario < 3)
                            assert (interval_cycles == EXPECT_INTERVAL) else $fatal(1, "interval measured=%0d expected=%0d", interval_cycles, EXPECT_INTERVAL);
                    end else first_accept[m] = cycle_count;
                    last_accept[m] = cycle_count;
                    accept_cycle[m] = cycle_count;
                    accepted_request[m] = m_request[m];
                    accepted[m]++;
                end
                if (f_req_valid[m] && f_req_ready[m]) begin
                    int bank, word_index, target;
                    master_fires++;
                    assert (issued[m] < accepted[m] && f_request[m] === accepted_request[m])
                        else $fatal(1, "request dropped/repeated/changed m=%0d", m);
                    expected_response[m] = '0;
                    if (f_request[m].addr == xlen_t'(32'h20000000)) begin
                        target = 0;
                        expected_response[m].error = BUS_DECERR;
                        errors_expected++;
                    end else begin
                        bank = f_request[m].addr >= xlen_t'(DTCM_BASE) ? 1 : 0;
                        target = bank + 2;
                        word_index = int'((f_request[m].addr - (bank == 0 ? xlen_t'(ITCM_BASE) : xlen_t'(DTCM_BASE))) / xlen_t'(DBUS_BYTES));
                        assert (word_index >= 0 && word_index < WORDS) else $fatal(1, "reference address bounds");
                        if (f_request[m].write) begin
                            writes_expected++;
                            effective_bytes[m] += $countones(f_request[m].wstrb);
                            for (int b = 0; b < DBUS_BYTES; b++)
                                if (f_request[m].wstrb[b]) reference_mem[bank][word_index][b*8 +: 8] = f_request[m].wdata[b*8 +: 8];
                        end else begin
                            expected_response[m].rdata = reference_mem[bank][word_index];
                            effective_bytes[m] += 1 << f_request[m].size;
                        end
                    end
                    if (target == 0) begin
                        assert (s_req_valid[0] && s_req_ready[0] && s_request[0] === f_request[m])
                            else $fatal(1, "slow error grant/target/payload m=%0d", m);
                    end else begin
                        assert (bank_req_valid[target-2] && bank_ready[target-2] && bank_allow[target-2] &&
                                bank_request[target-2] === f_request[m])
                            else $fatal(1, "TCM grant/target/payload m=%0d target=%0d", m, target);
                    end
                    issued[m]++;
                end
                assert (accepted[m] >= issued[m] && issued[m] >= returned[m] && returned[m] >= completed[m] &&
                        accepted[m] - completed[m] <= 1 && issued[m] - returned[m] <= 1)
                    else $fatal(1, "outstanding/order m=%0d accept=%0d issue=%0d return=%0d complete=%0d", m, accepted[m], issued[m], returned[m], completed[m]);
                // 此界限只适用于本 TB 的有限持续流和有界反压，不宣称 I 口具有无限流公平性。
                assert (accepted[m] == completed[m] || cycle_count - accept_cycle[m] <= SERVICE_BOUND)
                    else $fatal(1, "bounded service timeout scenario=%s m=%0d", scenario_name, m);
            end
            assert (master_fires == slave_fires) else $fatal(1, "fabric handshake cardinality");
            assert (writes_expected == writes_observed) else $fatal(1, "write side effect count");
        end
    end

    task automatic run_scenario(input int kind, input string name, input logic [2:0] active);
        int scenario_cycles, scenario_bytes;
        scenario = kind;
        scenario_name = name;
        rst = 1;
        m_req_valid = '0; m_rsp_ready = '0; bank_allow = '1;
        random_q = SEED;
        for (int m = 0; m < 3; m++) quota[m] = active[m] ? TRANSACTIONS : 0;
        repeat (3) @(negedge clk);
        rst = 0;
        while (completed[0] + completed[1] + completed[2] != quota[0] + quota[1] + quota[2]) begin
            // 驱动只发生在下降沿；后继请求持续等待，避免 testbench 人为多插一个空拍。
            random_q = {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
            for (int m = 0; m < 3; m++) begin
                m_req_valid[m] = accepted[m] < quota[m];
                m_request[m] = make_request(m, accepted[m]);
                m_rsp_ready[m] = kind != 4 || random_q[m+8] || cycle_count % 7 == 0;
            end
            for (int b = 0; b < 2; b++)
                bank_allow[b] = kind != 4 || random_q[b] || cycle_count % 5 == 0;
            @(negedge clk);
        end
        scenario_cycles = cycle_count;
        m_req_valid = '0;
        m_rsp_ready = '1;
        bank_allow = '1;
        // 排空后继续观察，迟到的重复响应或写同样必须失败。
        repeat (4) @(negedge clk);
        scenario_bytes = 0;
        for (int m = 0; m < 3; m++) begin
            assert (accepted[m] == quota[m] && issued[m] == quota[m] && returned[m] == quota[m] && completed[m] == quota[m])
                else $fatal(1, "scenario counts m=%0d", m);
            if (active[m]) begin
                $display("THROUGHPUT %s m=%0d count=%0d interval[min/max/avg]=%0d/%0d/%0.3f latency[min/max/avg]=%0d/%0d/%0.3f span=%0d req_stall=%0d rsp_stall=%0d max_issue_wait=%0d",
                         name, m, completed[m], interval_min[m], interval_max[m], real'(interval_sum[m]) / (completed[m]-1),
                         latency_min[m], latency_max[m], real'(latency_sum[m]) / completed[m],
                         last_complete[m]-first_accept[m]+1, request_stalls[m], response_stalls[m], max_issue_wait[m]);
                $display("OFFER %s m=%0d wait[avg/max]=%0.3f/%0d complete[avg/max]=%0.3f/%0d effective_bytes=%0d",
                         name, m, real'(offer_wait_sum[m]) / completed[m], offer_wait_max[m],
                         real'(total_latency_sum[m]) / completed[m], total_latency_max[m], effective_bytes[m]);
                $display("COUNTS %s m=%0d source_accept/lower_issue/lower_return/source_complete=%0d/%0d/%0d/%0d",
                         name, m, accepted[m], issued[m], returned[m], completed[m]);
                if (kind == 4)
                    assert (request_stalls[m] > 0 && response_stalls[m] > 0) else $fatal(1, "missing backpressure m=%0d", m);
            end
            total_transactions += completed[m];
            scenario_bytes += effective_bytes[m];
        end
        for (int b = 0; b < 2; b++)
            assert (bank_accepts[b] == bank_completes[b]) else $fatal(1, "physical bank did not drain b=%0d", b);
        if (kind == 2)
            assert (parallel_cycles == TRANSACTIONS) else $fatal(1, "different banks did not run in parallel count=%0d", parallel_cycles);
        $display("SCENARIO PASS %s writes=%0d errors=%0d parallel_cycles=%0d seed=%h", name, writes_observed, errors_expected, parallel_cycles, SEED);
        $display("SCENARIO METRIC %s local=%0d cycles=%0d effective_bytes=%0d bytes_per_cycle=%0.6f bank_accept=%0d/%0d bank_complete=%0d/%0d",
                 name, LOCAL_TCM_ENABLE, scenario_cycles, scenario_bytes, real'(scenario_bytes) / scenario_cycles,
                 bank_accepts[0], bank_accepts[1], bank_completes[0], bank_completes[1]);
        total_writes += writes_observed;
        total_errors += errors_expected;
        scenarios++;
    endtask

    initial begin
        assert (EXPECT_INTERVAL > 0 && EXPECT_LATENCY > 0) else $fatal(1, "invalid expected timing");
        m_req_valid = '0; m_rsp_ready = '0; bank_allow = '1;
        for (int m = 0; m < 3; m++) m_request[m] = '0;
        for (int b = 0; b < 2; b++)
            for (int w = 0; w < WORDS; w++) reference_mem[b][w] = initial_word(b, w);
        @(negedge clk);
        run_scenario(0, "single_instruction", 3'b001);
        run_scenario(1, "single_data", 3'b010);
        run_scenario(2, "different_banks", 3'b011);
        run_scenario(3, "same_bank_three_masters", 3'b111);
        run_scenario(4, "request_response_backpressure", 3'b111);
        $display("PASS tb_soc_local_tcm RV%0d local=%0d scenarios=%0d transactions=%0d writes=%0d errors=%0d EXPECT_INTERVAL=%0d EXPECT_LATENCY=%0d",
                 XLEN, LOCAL_TCM_ENABLE, scenarios, total_transactions, total_writes, total_errors, EXPECT_INTERVAL, EXPECT_LATENCY);
        $finish;
    end
    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "global throughput timeout");
    end
endmodule
