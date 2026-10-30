// Module: tb_tcm_bram
// Description: Independent byte memory and response ownership checking for dedicated-port TCM.
module tb_tcm_bram #(
    parameter bit INSTRUCTION = 1,
    parameter bit COMPARE_REFERENCE = 0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    localparam int BYTES = 1024;
    localparam int PRIMARY = INSTRUCTION ? 0 : 1;
    logic clk = 0, rst = 1;
    logic [3:0] req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
    bus_req_t request [4];
    logic [63:0] rsp_data [4];
    logic [3:0] outstanding = 0, previous_fire = 0;
    logic [63:0] expected_data [4];
    byte unsigned memory [BYTES];
    logic [XLEN-1:0] init_words [BYTES/DBUS_BYTES];
    int cycles = 0, accepted = 0, responses = 0, checked = 0, reset_discarded = 0;
    int waited [4], grants [4];
    int phase = 0;
    int unsigned random_q, seed;
    string image_path;
    always #5 clk = ~clk;
    tcm_bram #(.BYTES(BYTES), .INSTRUCTION(INSTRUCTION)) dut (.*);
    if (COMPARE_REFERENCE) begin : g_reference
        logic [3:0] reference_ready, reference_valid;
        logic [63:0] reference_data [4];
        tcm_bram_reference #(.BYTES(BYTES), .INSTRUCTION(INSTRUCTION)) reference_bram (
            .clk, .rst, .req_valid, .req_ready(reference_ready), .request,
            .rsp_valid(reference_valid), .rsp_ready, .rsp_data(reference_data)
        );
        initial begin
            string path;
            if (!$value$plusargs("IMAGE=%s",path)) $fatal(1, "missing reference init image");
            reference_bram.load_image(path);
        end
        always @(posedge clk) if (!rst) begin
            assert (req_ready == reference_ready && rsp_valid == reference_valid)
                else $fatal(1, "BRAM reference handshake mismatch cycle=%0d",cycles);
            for (int c = 0; c < 4; c++)
                if (rsp_valid[c]) assert (rsp_data[c] == reference_data[c])
                    else $fatal(1, "BRAM reference data mismatch cycle=%0d client=%0d",cycles,c);
        end
    end

    function automatic int unsigned next_random;
        random_q ^= random_q << 13;
        random_q ^= random_q >> 17;
        random_q ^= random_q << 5;
        return random_q;
    endfunction

    // 每笔被接纳的请求先取得写入前快照，再统一应用当拍字节写入。
    // 独立模型不使用DUT端口选择、bank owner、读数据或存储数组。
    always @(posedge clk) begin
        cycles <= cycles + 1;
        previous_fire <= req_valid & req_ready;
        if (rst) outstanding = 0;
        else begin
            for (int c = 0; c < 4; c++) begin
                if (rsp_valid[c]) begin
                    assert (outstanding[c] && rsp_data[c] == expected_data[c])
                        else $fatal(1, "BRAM response RV%0d IF%0d cycle=%0d client=%0d got=%h expected=%h pending=%b",
                                    XLEN,INSTRUCTION,cycles,c,rsp_data[c],expected_data[c],outstanding[c]);
                    checked++;
                    if (rsp_ready[c]) begin outstanding[c] = 0; responses++; end
                end
                if (req_valid[c] && req_ready[c]) begin
                    assert (!outstanding[c]) else $fatal(1, "client response overwrite");
                    outstanding[c] = 1;
                    expected_data[c] = 0;
                    for (int lane = 0; lane < (c == 0 ? 8 : DBUS_BYTES); lane++)
                        expected_data[c][8*lane +: 8] = memory[(int'(request[c].addr)/DBUS_BYTES)*DBUS_BYTES+lane];
                    accepted++;
                    grants[c]++;
                end
                if (phase == 2 && req_valid[c]) begin
                    if (req_ready[c]) waited[c] = 0;
                    else waited[c]++;
                    assert (waited[c] < 16) else $fatal(1, "auxiliary/CPU starvation client=%0d",c);
                end else waited[c] = 0;
            end
            for (int c = 0; c < 4; c++) begin
                if (req_valid[c] && req_ready[c] && request[c].write)
                    for (int lane = 0; lane < DBUS_BYTES; lane++)
                        if (request[c].wstrb[lane])
                            memory[(int'(request[c].addr)/DBUS_BYTES)*DBUS_BYTES+lane] = request[c].wdata[8*lane +: 8];
            end
            if (phase == 1)
                assert (req_ready[PRIMARY] && req_ready[2]) else $fatal(1, "two-read steady throughput lost");
        end
        if (cycles > 25000) $fatal(1, "BRAM test timeout");
    end

    task automatic drain;
        @(negedge clk);
        phase = 0;
        req_valid = 0;
        rsp_ready = '1;
        repeat (4) @(negedge clk);
        assert (outstanding == 0 && rsp_valid == 0) else $fatal(1, "BRAM drain did not finish");
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d",seed)) seed = 430097725;
        random_q = seed;
        if (!$value$plusargs("IMAGE=%s",image_path)) $fatal(1, "missing test init image");
        $readmemh(image_path,init_words);
        dut.load_image(image_path);
        for (int i = 0; i < BYTES; i++) memory[i] = init_words[i/DBUS_BYTES][8*(i%DBUS_BYTES) +: 8];
        for (int c = 0; c < 4; c++) begin request[c] = '0; waited[c] = 0; grants[c] = 0; end
        repeat (5) @(negedge clk);
        rst = 0;
        // 两路同bank读连续接纳；ITCM还验证IF64和数据读可以同时服务。
        req_valid[PRIMARY] = 1;
        req_valid[2] = 1;
        rsp_ready = '1;
        request[PRIMARY] = '{addr:0, size:INSTRUCTION ? MEM_WORD : (XLEN == 64 ? MEM_DWORD : MEM_WORD),
                             execute:INSTRUCTION, default:'0};
        request[2] = '{addr:xlen_t'(2*DBUS_BYTES), size:XLEN == 64 ? MEM_DWORD : MEM_WORD, default:'0};
        phase = 1;
        repeat (128) @(negedge clk);
        drain();
        // 所有客户端争同一字，辅助写与主口读写冲突；无响应反压时须有界前进。
        phase = 2;
        req_valid = INSTRUCTION ? 4'b1111 : 4'b1110;
        for (int c = 0; c < 4; c++)
            request[c] = '{addr:0, write:c != 0, execute:c == 0,
                           size:c == 0 ? MEM_WORD : (XLEN == 64 ? MEM_DWORD : MEM_WORD),
                           wdata:xlen_t'(32'h9182c3d4 ^ 32'(c)), wstrb:'1};
        repeat (256) @(negedge clk);
        drain();
        for (int step = 0; step < 10000; step++) begin
            for (int c = 0; c < 4; c++) begin
                rsp_ready[c] = next_random()%4 != 0;
                if (!req_valid[c] || previous_fire[c]) begin
                    req_valid[c] = (INSTRUCTION || c != 0) && next_random()%4 != 0;
                    request[c] = '{addr:xlen_t'((next_random()%16)*(c == 0 ? 8 : DBUS_BYTES)),
                                   write:c != 0 && next_random()%2 != 0, execute:c == 0,
                                   size:c == 0 ? MEM_WORD : (XLEN == 64 ? MEM_DWORD : MEM_WORD),
                                   wdata:xlen_t'({next_random(),next_random()}), wstrb:DBUS_BYTES'(next_random())};
                end
            end
            @(negedge clk);
        end
        drain();
        // 协调复位丢弃已有响应，但保持BRAM内容；复位后逐字验证随机写入的结果。
        req_valid[PRIMARY] = 1;
        request[PRIMARY] = '{addr:0, execute:INSTRUCTION, size:MEM_WORD, default:'0};
        rsp_ready = 0;
        do @(posedge clk); while (!req_ready[PRIMARY]);
        @(negedge clk); req_valid = 0;
        repeat (3) @(negedge clk);
        assert (rsp_valid[PRIMARY]) else $fatal(1, "missing response before reset");
        reset_discarded = $countones(outstanding);
        rst = 1;
        repeat (3) @(negedge clk);
        assert (rsp_valid == 0 && req_ready == 0) else $fatal(1, "reset did not clear ownership");
        rst = 0;
        rsp_ready = '1;
        for (int address = 0; address < BYTES; address += INSTRUCTION ? 8 : DBUS_BYTES) begin
            req_valid[PRIMARY] = 1;
            request[PRIMARY] = '{addr:xlen_t'(address), execute:INSTRUCTION,
                size:INSTRUCTION ? MEM_WORD : (XLEN == 64 ? MEM_DWORD : MEM_WORD), default:'0};
            do @(posedge clk); while (!req_ready[PRIMARY]);
            @(negedge clk);
        end
        drain();
        assert (accepted == responses + reset_discarded) else $fatal(1, "lost/extra responses");
        for (int c = INSTRUCTION ? 0 : 1; c < 4; c++)
            assert (grants[c] > 300) else $fatal(1, "missing randomized client coverage");
        $display("PASS TCM BRAM RV%0d IF%0d seed=%0d requests=%0d responses=%0d reset_discarded=%0d checks=%0d dual_read_cycles=128 fairness_cycles=256 random_cycles=10000",
                 XLEN, INSTRUCTION, seed, accepted, responses, reset_discarded, checked);
        $finish;
    end
endmodule
