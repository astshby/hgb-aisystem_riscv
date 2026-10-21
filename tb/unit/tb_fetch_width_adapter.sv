// Module: tb_fetch_width_adapter
// Description: Checks word ownership, independent errors, backpressure, reset and true one-cycle wide simulation memory.
module tb_fetch_width_adapter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    localparam int WORDS = FETCH_DATA_W / 32;

    logic clk = 0, rst = 1;
    logic s_req_valid = 0, s_req_ready, s_rsp_valid, s_rsp_ready = 0;
    xlen_t s_req_addr = '0;
    logic [FETCH_DATA_W-1:0] s_rsp_data;
    logic s_rsp_error, s_rsp_error_1;
    logic m_req_valid, m_req_ready = 0, m_rsp_valid = 0, m_rsp_ready, m_rsp_error = 0;
    xlen_t m_req_addr;
    logic [31:0] m_rsp_data = '0;
    logic memory_req_valid = 0, memory_req_ready, memory_rsp_valid, memory_rsp_ready = 0;
    xlen_t memory_req_addr = '0;
    logic [FETCH_DATA_W-1:0] memory_rsp_data;
    logic memory_rsp_error, memory_rsp_error_1;
    int source_accepts = 0, downstream_accepts = 0, source_replies = 0, checks = 0;

    always #5 clk = ~clk;
    fetch_width_adapter dut (.*);
    sim_imem #(.DEPTH_WORDS(3)) u_memory (
        .clk, .rst, .req_valid(memory_req_valid), .req_ready(memory_req_ready),
        .req_addr(memory_req_addr), .rsp_valid(memory_rsp_valid), .rsp_ready(memory_rsp_ready),
        .rsp_data(memory_rsp_data), .rsp_error(memory_rsp_error), .rsp_error_1(memory_rsp_error_1)
    );

    // 计数器只观察采样沿，不反过来驱动接口；所有请求、响应刺激在下降沿之后改变。
    always @(posedge clk) begin
        if (!rst) begin
            if (s_req_valid && s_req_ready) source_accepts++;
            if (m_req_valid && m_req_ready) downstream_accepts++;
            if (s_rsp_valid && s_rsp_ready) source_replies++;
        end
    end
    task automatic tick;
        @(posedge clk);
        @(negedge clk);
        #1;
    endtask
    task automatic check(input logic condition, input string message);
        assert (condition) else $fatal(1, "%s", message);
        checks++;
    endtask

    task automatic transfer(input xlen_t address, input logic [1:0] errors);
        logic [FETCH_DATA_W-1:0] expected;
        int old_source, old_memory, old_replies;
        expected = '0;
        old_source = source_accepts;
        old_memory = downstream_accepts;
        old_replies = source_replies;
        s_req_valid = 1;
        s_req_addr = address;
        s_rsp_ready = 0;
        m_req_ready = 0;
        #1;
        if (WORDS == 2) begin
            check(s_req_ready && !m_req_valid, "wide request must enter its owner before subrequest");
            tick();
            s_req_valid = 0;
            s_req_addr = xlen_t'('1);
        end else begin
            check(m_req_valid && m_req_addr == address && !s_req_ready,
                  "single-word request must bypass without a new register");
        end
        for (int word_index = 0; word_index < WORDS; word_index++) begin
            repeat (2) begin
                #1;
                check(m_req_valid && m_req_addr == address + xlen_t'(4*word_index),
                      "subrequest address or valid changed under backpressure");
                check(!s_rsp_valid, "response preceded the corresponding memory response");
                tick();
            end
            m_req_ready = 1;
            #1;
            if (WORDS == 1) check(s_req_ready, "single-word ready must bypass in the same cycle");
            tick();
            m_req_ready = 0;
            if (WORDS == 1) begin s_req_valid = 0; s_req_addr = xlen_t'('1); end
            m_rsp_valid = 1;
            m_rsp_data = 32'h12000000 ^ 32'(address) ^ 32'(word_index*16'h1001);
            m_rsp_error = errors[word_index];
            expected[word_index*32 +: 32] = m_rsp_data;
            #1;
            if (WORDS == 2) begin
                check(m_rsp_ready, "wide response capture must not depend on source ready");
                tick();
                m_rsp_valid = 0;
                m_rsp_data = '1;
                m_rsp_error = !errors[word_index];
            end else begin
                check(s_rsp_valid && !m_rsp_ready && s_rsp_data == expected,
                      "single-word response must bypass and propagate backpressure");
            end
        end
        repeat (3) begin
            #1;
            check(s_rsp_valid && s_rsp_data == expected && s_rsp_error == errors[0] &&
                  s_rsp_error_1 == (WORDS == 2 && errors[1]), "held response/error word ownership");
            if (WORDS == 2) check(!s_req_ready && !m_req_valid, "wide reply must retain its owner");
            tick();
        end
        s_rsp_ready = 1;
        tick();
        m_rsp_valid = 0;
        s_rsp_ready = 0;
        #1;
        check(source_accepts == old_source+1 && downstream_accepts == old_memory+WORDS &&
              source_replies == old_replies+1, "one source owner must produce exactly its words and one reply");
        check(!s_rsp_valid, "reply repeated after consumption");
    endtask

    task automatic memory_read(input xlen_t address, input logic [1:0] errors,
                               input logic [FETCH_DATA_W-1:0] expected);
        memory_req_valid = 1;
        memory_req_addr = address;
        memory_rsp_ready = 0;
        #1;
        check(memory_req_ready, "simulation memory initially ready");
        tick();
        memory_req_valid = 0;
        memory_req_addr = '1;
        #1;
        check(memory_rsp_valid && memory_rsp_data == expected && memory_rsp_error == errors[0] &&
              memory_rsp_error_1 == (WORDS == 2 && errors[1]), "one-cycle memory data or per-word boundary error");
        repeat (2) begin
            tick();
            check(memory_rsp_valid && !memory_req_ready && memory_rsp_data == expected &&
                  memory_rsp_error == errors[0] && memory_rsp_error_1 == (WORDS == 2 && errors[1]),
                  "simulation memory response changed while held");
        end
        memory_rsp_ready = 1;
        tick();
        memory_rsp_ready = 0;
        check(!memory_rsp_valid, "simulation memory response repeated");
    endtask

    task automatic queued_successor;
        int old_source, old_memory, old_replies;
        old_source = source_accepts;
        old_memory = downstream_accepts;
        old_replies = source_replies;
        s_req_valid = 1;
        s_req_addr = xlen_t'(32'h400);
        m_req_ready = 1;
        tick();
        s_req_valid = 0;
        for (int transaction = 0; transaction < 2; transaction++) begin
            for (int word_index = 0; word_index < 2; word_index++) begin
                #1;
                check(m_req_valid && m_req_addr == xlen_t'(32'h400) + xlen_t'(transaction*256 + word_index*4),
                      "queued successor changed its subrequest identity");
                tick();
                m_req_ready = 0;
                m_rsp_valid = 1;
                m_rsp_data = 32'(transaction*16 + word_index);
                m_rsp_error = 0;
                tick();
                m_rsp_valid = 0;
                m_req_ready = 1;
            end
            if (transaction == 0) begin
                // 真实后继不能撤回：valid/地址一直保持到旧响应释放后的实际接受沿。
                s_req_valid = 1;
                s_req_addr = xlen_t'(32'h500);
                repeat (2) begin
                    #1;
                    check(!s_req_ready && s_rsp_valid && s_rsp_data == FETCH_DATA_W'(64'h0000000100000000),
                          "old reply lost ownership to an unaccepted successor");
                    tick();
                end
            end
            s_rsp_ready = 1;
            tick();
            s_rsp_ready = 0;
            if (transaction == 0) begin
                check(s_req_ready, "released wide slot did not accept the held successor");
                tick();
                s_req_valid = 0;
            end
        end
        m_req_ready = 0;
        check(source_accepts == old_source+2 && downstream_accepts == old_memory+4 &&
              source_replies == old_replies+2, "queued successor duplicated or dropped a transaction");
    endtask

    initial begin
        u_memory.mem[0] = 32'h11223344;
        u_memory.mem[1] = 32'h55667788;
        u_memory.mem[2] = 32'h99aabbcc;
        repeat (4) tick();
        rst = 0;
        #1;
        transfer(xlen_t'(32'h100), 2'b00);
        transfer(xlen_t'(32'h180), 2'b01);
        transfer(xlen_t'(32'h200), 2'b10);
        transfer(xlen_t'(32'h280), 2'b11);
        transfer(~xlen_t'(7), 2'b11);
        if (XLEN == 64) transfer(xlen_t'(64'h100000080), 2'b10);
        if (WORDS == 2) queued_successor();

        // 接受后等待返回时协调复位，旧 owner 和半包不能成为下一请求的响应。
        s_req_valid = 1;
        s_req_addr = xlen_t'(32'h300);
        m_req_ready = 1;
        tick();
        if (WORDS == 2) tick();
        s_req_valid = 0;
        m_req_ready = 0;
        rst = 1;
        tick();
        m_rsp_valid = 0;
        rst = 0;
        #1;
        check(!s_rsp_valid && !m_req_valid, "reset retained an old fetch owner");
        transfer(xlen_t'(32'h380), 2'b00);

        if (WORDS == 2) begin
            // 低字已经保存、高字尚未接受时复位；下一响应不能拼进复位前的半包。
            s_req_valid = 1;
            s_req_addr = xlen_t'(32'h600);
            m_req_ready = 1;
            tick();
            s_req_valid = 0;
            tick();
            m_req_ready = 0;
            m_rsp_valid = 1;
            m_rsp_data = 32'hdeadbeef;
            m_rsp_error = 1;
            tick();
            m_rsp_valid = 0;
            rst = 1;
            tick();
            rst = 0;
            #1;
            check(!s_rsp_valid && !m_req_valid, "reset retained a half-completed fetch");
            transfer(xlen_t'(32'h680), 2'b00);
        end

        // 奇数深度使最后一个合法低字与越界高字同时返回，不能整体报错或回绕。
        memory_read('0, 2'b00, FETCH_DATA_W'(64'h5566778811223344));
        memory_read(xlen_t'(8), WORDS == 2 ? 2'b10 : 2'b00, FETCH_DATA_W'(32'h99aabbcc));
        memory_read(xlen_t'(16), 2'b11, '0);
        memory_read(xlen_t'(2), 2'b11, '0);
        if (XLEN == 64) memory_read(xlen_t'(64'h100000000), 2'b11, '0);
        $display("PASS tb_fetch_width_adapter RV%0d issue=%0d checks=%0d", XLEN, ISSUE_WIDTH, checks);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "fetch width compatibility timeout");
    end
endmodule
