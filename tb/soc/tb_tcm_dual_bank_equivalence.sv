// Module: tb_tcm_dual_bank_equivalence
// Description: Exhaustive arbitration comparison plus cycle-accurate RAM, backpressure and throughput checks.
module tb_tcm_dual_bank_equivalence;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    localparam int BYTES = 256;
    localparam int WORDS = BYTES / DBUS_BYTES;
    logic clk = 0, clock_enable = 1, rst = 1;
    logic [3:0] req_valid = 0, req_ready, ref_ready, rsp_valid, ref_valid, rsp_ready = 0;
    bus_req_t request [4];
    logic [63:0] rsp_data [4], ref_data [4], expected_data [4];
    xlen_t memory [WORDS];
    logic [3:0] expected_valid = 0, pending_valid = 0;
    logic [1:0] probe_next = 0;
    logic [3:0] probe_block = 0, probe_valid = 0, probe_ready = 0, probe_grant;
    logic [1:0] probe_needed [4], probe_selected [2], probe_bank_fire, probe_first;
    logic [3:0] probe_bank_grant [2];
    logic [31:0] random_q = 32'h19a2c53d;
    int exhaustive_checks = 0, cycle_checks = 0, accepted = 0, writes = 0, dual_cycles = 0;
    int grant_count [4], wait_count [4];
    int seed_value;

    always #5 if (clock_enable) clk = ~clk;
    tcm_dual_bank #(.BYTES(BYTES)) dut (.*);
    tcm_dual_bank_reference #(.BYTES(BYTES)) reference (
        .clk, .rst, .req_valid, .req_ready(ref_ready), .request,
        .rsp_valid(ref_valid), .rsp_ready, .rsp_data(ref_data)
    );

    tcm_bank_arbiter probe (
        .rst(1'b0), .req_valid(probe_valid), .rsp_valid(probe_block), .rsp_ready(probe_ready),
        .needed(probe_needed), .next_q(probe_next), .req_ready(probe_grant),
        .bank_grant(probe_bank_grant), .bank_fire(probe_bank_fire),
        .selected(probe_selected), .first_selected(probe_first)
    );

    function automatic logic [31:0] random_word();
        random_q ^= random_q << 13;
        random_q ^= random_q >> 17;
        random_q ^= random_q << 5;
        return random_q;
    endfunction

    task automatic compare_control;
        assert (req_ready == ref_ready && rsp_valid == ref_valid &&
                dut.bank_fire == reference.bank_fire)
            else $fatal(1, "TCM control differs next=%0d req=%b block=%b ready=%b got=%b ref=%b",
                        dut.next_q, req_valid, probe_block, rsp_ready, req_ready, ref_ready);
        for (int bank = 0; bank < 2; bank++)
            if (dut.bank_fire[bank])
                assert (dut.selected[bank] == reference.selected[bank])
                    else $fatal(1, "TCM bank %0d winner differs", bank);
        if (dut.bank_fire[0])
            assert (dut.g_bank[0].access == reference.g_bank[0].access)
                else $fatal(1, "TCM bank0 payload differs");
        if (dut.bank_fire[1])
            assert (dut.g_bank[1].access == reference.g_bank[1].access)
                else $fatal(1, "TCM bank1 payload differs");
    endtask

    // 直接驱动纯组合仲裁器，穷举所有轮询/阻塞/bank 输入，避免向运行状态强制写值。
    task automatic exhaustive_arbitration;
        logic [1:0] used, expected_bank_fire, expected_first, expected_selected [2];
        logic [3:0] expected_grant;
        logic found;
        int client;
        @(negedge clk);
        clock_enable = 0;
        for (int start = 0; start < 4; start++) begin
            probe_next = 2'(start);
            for (int bank_mask = 0; bank_mask < (XLEN == 32 ? 8 : 16); bank_mask++) begin
                for (int c = 0; c < 4; c++) begin
                    if (XLEN == 32 && c == 0) probe_needed[c] = 2'b11;
                    else probe_needed[c] = ((bank_mask >> (XLEN == 32 ? c-1 : c)) & 1) != 0 ? 2'b10 : 2'b01;
                end
                for (int valid_mask = 0; valid_mask < 16; valid_mask++) begin
                    probe_valid = 4'(valid_mask);
                    for (int blocked = 0; blocked < 16; blocked++) begin
                        probe_block = 4'(blocked);
                        for (int ready_mask = 0; ready_mask < 16; ready_mask++) begin
                            probe_ready = 4'(ready_mask);
                            used = 0;
                            expected_grant = 0;
                            expected_bank_fire = 0;
                            expected_selected[0] = 0;
                            expected_selected[1] = 0;
                            expected_first = 0;
                            found = 0;
                            // 独立参考保留原来的四步贪心次序，不复用 DUT 的优先级矩阵。
                            for (int offset = 0; offset < 4; offset++) begin
                                client = (start + offset) % 4;
                                if (probe_valid[client] && (!probe_block[client] || probe_ready[client]) &&
                                    ((probe_needed[client] & used) == 0)) begin
                                    expected_grant[client] = 1;
                                    used |= probe_needed[client];
                                    if (!found) begin found = 1; expected_first = 2'(client); end
                                    for (int bank = 0; bank < 2; bank++) begin
                                        if (probe_needed[client][bank]) begin
                                            expected_bank_fire[bank] = 1;
                                            expected_selected[bank] = 2'(client);
                                        end
                                    end
                                end
                            end
                            #1;
                            assert (probe_grant == expected_grant && probe_bank_fire == expected_bank_fire &&
                                    (!found || probe_first == expected_first))
                                else $fatal(1, "TCM exhaustive grant mismatch next=%0d valid=%b blocked=%b ready=%b", start,
                                            probe_valid, probe_block, probe_ready);
                            for (int bank = 0; bank < 2; bank++) begin
                                if (expected_bank_fire[bank])
                                    assert (probe_selected[bank] == expected_selected[bank] &&
                                            probe_bank_grant[bank] == (4'b0001 << expected_selected[bank]))
                                        else $fatal(1, "TCM exhaustive bank selection mismatch");
                                else assert (probe_bank_grant[bank] == 0)
                                    else $fatal(1, "TCM exhaustive idle bank granted");
                            end
                            exhaustive_checks++;
                        end
                    end
                end
            end
        end
        clock_enable = 1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
    endtask

    // 参考字数组独立计算读旧值/字节写掩码；有效响应和完整载荷在每拍消费前核对。
    task automatic step(input logic [3:0] new_requests, input logic [3:0] response_ready,
                        input int mode);
        logic [3:0] fires;
        int word_index;
        @(negedge clk);
        req_valid = pending_valid | new_requests;
        rsp_ready = response_ready;
        for (int c = 0; c < 4; c++) begin
            if (!pending_valid[c]) begin
                request[c] = '0;
                word_index = int'(random_word() % WORDS);
                if (c == 0 && XLEN == 32) word_index &= ~1;
                if (mode == 1 && c != 0)
                    word_index = (word_index & ~1) | ((c-1) & 1);
                request[c].addr = xlen_t'(word_index * DBUS_BYTES);
                request[c].wdata = xlen_t'({random_word(), random_word()});
                request[c].wstrb = DBUS_BYTES'(random_word());
                request[c].size = XLEN == 64 ? MEM_DWORD : MEM_WORD;
                request[c].write = c != 0 && (mode == 2 || (mode == 0 && random_word()[0]));
            end
        end
        #1;
        compare_control();
        assert (dut.next_q == reference.next_q && rsp_valid == expected_valid)
            else $fatal(1, "TCM state/response count differs at cycle %0d valid=%b expected=%b", cycle_checks, rsp_valid, expected_valid);
        for (int c = 0; c < 4; c++) begin
            if (rsp_valid[c])
                assert (rsp_data[c] == ref_data[c] && rsp_data[c] == expected_data[c])
                    else $fatal(1, "TCM data client=%0d cycle=%0d got=%h ref=%h expected=%h", c, cycle_checks,
                                rsp_data[c], ref_data[c], expected_data[c]);
            if (rsp_valid[c] && rsp_ready[c]) expected_valid[c] = 0;
        end
        fires = req_valid & req_ready;
        if ($countones(fires) == 2) dual_cycles++;
        if (mode == 1)
            assert (fires == 4'b0110) else $fatal(1, "TCM sustained dual-bank throughput lost");
        for (int c = 0; c < 4; c++) begin
            if (fires[c]) begin
                assert (!expected_valid[c]) else $fatal(1, "TCM overwrote outstanding client %0d", c);
                expected_valid[c] = 1;
                word_index = int'(request[c].addr) / DBUS_BYTES;
                if (c == 0 && XLEN == 32)
                    expected_data[c] = {32'(memory[word_index+1]), 32'(memory[word_index])};
                else expected_data[c] = 64'(memory[word_index]);
                if (request[c].write) begin
                    for (int lane = 0; lane < DBUS_BYTES; lane++)
                        if (request[c].wstrb[lane])
                            memory[word_index][8*lane +: 8] = request[c].wdata[8*lane +: 8];
                    writes++;
                end
                accepted++;
                grant_count[c]++;
            end
            if (mode == 3 && req_valid[c] && !fires[c]) wait_count[c]++;
            else wait_count[c] = 0;
            assert (wait_count[c] < 5) else $fatal(1, "TCM fair arbitration starved client %0d", c);
        end
        pending_valid = req_valid & ~req_ready;
        cycle_checks++;
        @(posedge clk);
    endtask

    task automatic drain;
        repeat (12) step(0, 4'b1111, 0);
        assert (expected_valid == 0 && pending_valid == 0)
            else $fatal(1, "TCM did not drain");
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed_value)) random_q = 32'(seed_value);
        for (int c = 0; c < 4; c++) begin
            request[c] = '0;
            expected_data[c] = 0;
            grant_count[c] = 0;
            wait_count[c] = 0;
        end
        for (int index = 0; index < WORDS/2; index++) begin
            memory[2*index] = xlen_t'(32'h12345678 ^ (2*index*97));
            memory[2*index+1] = xlen_t'(32'h12345678 ^ ((2*index+1)*97));
            dut.g_bank[0].mem[index] = memory[2*index];
            dut.g_bank[1].mem[index] = memory[2*index+1];
            reference.g_bank[0].mem[index] = memory[2*index];
            reference.g_bank[1].mem[index] = memory[2*index+1];
        end
        repeat (3) @(posedge clk);
        exhaustive_arbitration();
        // 每拍两个异 bank 读请求，精确检查接收连续性和下一拍同步响应。
        repeat (128) step(4'b0110, 4'b1111, 1);
        drain();
        repeat (128) step(4'b1111, 4'b1111, 3);
        drain();
        repeat (128) step(4'b1110, 4'b1111, 2);
        drain();
        // 长时间停住任一响应，再逐个放行；其他客户端仍然推进。
        for (int c = 0; c < 4; c++) begin
            repeat (24) step(4'b1111, ~(4'b0001 << c), 0);
            drain();
        end
        repeat (5000) step(4'(random_word()), 4'(random_word()), 0);
        drain();
        for (int c = 0; c < 4; c++)
            assert (grant_count[c] > 20) else $fatal(1, "TCM client %0d not exercised", c);
        for (int index = 0; index < WORDS/2; index++) begin
            assert (dut.g_bank[0].mem[index] == memory[2*index] &&
                    dut.g_bank[1].mem[index] == memory[2*index+1])
                else $fatal(1, "TCM final byte-write memory mismatch index=%0d", index);
        end
        $display("PASS tb_tcm_dual_bank_equivalence RV%0d exhaustive=%0d cycles=%0d accepted=%0d writes=%0d dual_cycles=%0d",
                 XLEN, exhaustive_checks, cycle_checks, accepted, writes, dual_cycles);
        $finish;
    end
endmodule

// Module: tcm_dual_bank_reference
// Description: Frozen pre-optimization greedy implementation used only as an independent cycle reference.
module tcm_dual_bank_reference #(
    parameter int unsigned BYTES = soc_config_pkg::ITCM_BYTES,
    parameter INIT_FILE = ""
) (
    input logic clk, rst,
    input logic [3:0] req_valid,
    output logic [3:0] req_ready,
    input bus_types_pkg::bus_req_t request [4],
    output logic [3:0] rsp_valid,
    input logic [3:0] rsp_ready,
    output logic [63:0] rsp_data [4]
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    localparam int BYTE_W = $clog2(DBUS_BYTES);
    localparam int WORDS = BYTES / (2 * DBUS_BYTES);
    localparam int INDEX_W = $clog2(WORDS);
    logic [1:0] bank_valid_q, used, bank_fire;
    logic [1:0] bank_owner_q [2], selected [2], next_q;
    logic [1:0] needed [4];
    logic [XLEN-1:0] bank_data [2];
    logic [3:0] request_fire;
    logic [3:0] buffer_valid_q, direct_valid;
    logic [63:0] buffer_data_q [4], direct_data [4];
    logic found;
    logic [1:0] first_selected;
    logic [1:0] client;

    for (genvar c = 0; c < 4; c++) begin : g_bank_mask
        if (c == 0 && XLEN == 32) begin : g_if_pair
            assign needed[c] = 2'b11;
        end else begin : g_one_word
            assign needed[c] = request[c].addr[BYTE_W] ? 2'b10 : 2'b01;
        end
    end
    // 同步 RAM 的输出只保留一拍归属。反压数据移入客户端缓冲，不能占住共享 bank，
    // 否则满 IF 队列可能堵住解除流水停顿所需的 D Load，形成互相等待。
    always_comb begin
        direct_valid = 0;
        for (int c = 0; c < 4; c++) direct_data[c] = 0;
        for (int b = 0; b < 2; b++) begin
            if (bank_valid_q[b]) begin
                direct_valid[bank_owner_q[b]] = 1;
                if (XLEN == 32 && bank_owner_q[b] == 0)
                    direct_data[0][32*b +: 32] = 32'(bank_data[b]);
                else direct_data[bank_owner_q[b]] = 64'(bank_data[b]);
            end
        end
    end
    assign rsp_valid = direct_valid | buffer_valid_q;
    for (genvar c = 0; c < 4; c++) begin : g_response_buffer
        assign rsp_data[c] = buffer_valid_q[c] ? buffer_data_q[c] : direct_data[c];
        always_ff @(posedge clk) begin
            if (rst) buffer_valid_q[c] <= 0;
            else begin
                if (rsp_ready[c]) buffer_valid_q[c] <= 0;
                if (direct_valid[c] && !rsp_ready[c]) begin
                    buffer_valid_q[c] <= 1; buffer_data_q[c] <= direct_data[c];
                end
            end
        end
    end
    // 轮询首选后贪心填入不冲突请求；宽 IF 的两个 bank 原子接纳，避免半个请求占死。
    always_comb begin
        used = 0; req_ready = 0; bank_fire = 0;
        selected[0] = 0; selected[1] = 0; found = 0; first_selected = next_q;
        client = 0;
        for (int offset = 0; offset < 4; offset++) begin
            // 两位无符号索引自然回绕，避免综合器保留有符号余数单元。
            client = next_q + 2'(offset);
            if (req_valid[client] && !rst && (!rsp_valid[client] || rsp_ready[client]) &&
                (needed[client] & used) == 0) begin
                req_ready[client] = 1;
                used |= needed[client];
                if (!found) begin found = 1; first_selected = 2'(client); end
                for (int b = 0; b < 2; b++) begin
                    if (needed[client][b]) begin
                        bank_fire[b] = 1; selected[b] = 2'(client);
                    end
                end
            end
        end
    end
    assign request_fire = req_valid & req_ready;
    always_ff @(posedge clk) begin
        if (rst) begin
            bank_valid_q <= 0; next_q <= 0;
            bank_owner_q[0] <= 0; bank_owner_q[1] <= 0;
        end else begin
            if (|request_fire) next_q <= first_selected + 2'd1;
            bank_valid_q <= bank_fire;
            for (int b = 0; b < 2; b++) begin
                if (bank_fire[b]) bank_owner_q[b] <= selected[b];
            end
        end
    end
    for (genvar b = 0; b < 2; b++) begin : g_bank
        logic [XLEN-1:0] mem [WORDS];
        logic [INDEX_W-1:0] index;
        bus_types_pkg::bus_req_t access;
        assign access = request[selected[b]];
        assign index = access.addr[BYTE_W+1 +: INDEX_W];
        initial begin
            if (INIT_FILE != "")
                $readmemh({INIT_FILE, b == 0 ? ".bank0" : ".bank1"}, mem);
        end
        // 每个物理 bank 仅一个同步读写口，不复位 RAM；同 bank 请求由上面的仲裁串行化。
        always_ff @(posedge clk) begin
            if (bank_fire[b]) begin
                bank_data[b] <= mem[index];
                if (access.write)
                    for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++)
                        if (access.wstrb[byte_no])
                            mem[index][8*byte_no +: 8] <= access.wdata[8*byte_no +: 8];
            end
        end
    end
`ifndef SYNTHESIS
    task automatic load_image(input string path);
        logic [XLEN-1:0] words [2*WORDS];
        $readmemh(path, words);
        for (int idx = 0; idx < WORDS; idx++) begin
            g_bank[0].mem[idx] = words[2*idx];
            g_bank[1].mem[idx] = words[2*idx+1];
        end
    endtask
    always_ff @(posedge clk) if (!rst)
        assert ((direct_valid & buffer_valid_q) == 0) else $fatal(1, "TCM client response overrun");
    always_ff @(posedge clk) if (!rst && XLEN == 32)
        assert (!(bank_valid_q[0] && bank_owner_q[0] == 0) ||
                (bank_valid_q[1] && bank_owner_q[1] == 0))
            else $fatal(1, "IF64 bank ownership split");
`endif
endmodule
