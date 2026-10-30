// Module: tb_axi_to_axil_mask_miter
// Description: Checks AW-mask precomputation against the preserved control bridge under independent channel backpressure.
module tb_axi_to_axil_mask_miter;
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk = 0, rst = 1;
    axi_req_t s_req;
    axi_rsp_t s_rsp_new, s_rsp_old;
    axil_req_t m_req_new, m_req_old;
    axil_rsp_t m_rsp;
    logic aw_seen = 0, w_seen = 0, read_pending = 0;
    logic [31:0] aw_addr = 0, read_addr = 0;
    logic [31:0] bp_state = 32'h38196b2f;
    logic [3:0] b_delay = 0, r_delay = 0;
    int checks = 0, writes = 0, reads = 0, aw_transfers = 0, w_transfers = 0, ar_transfers = 0;
    int input_w_beats = 0, write_start = 0, write_expected = 0;
    logic write_active = 0;
    axi_a_t active_address;
    logic [63:0] active_data;
    logic [7:0] active_strobe;
    logic expect_forward;
    int driver_state = 32'h42b19d83;

    axi_to_axil dut_new (.s_rsp(s_rsp_new), .m_req(m_req_new), .*);
    axi_to_axil_reference dut_old (.s_rsp(s_rsp_old), .m_req(m_req_old), .*);
    always #5 clk = ~clk;

    function automatic int unsigned random_word;
        driver_state ^= driver_state << 13;
        driver_state ^= driver_state >> 17;
        driver_state ^= driver_state << 5;
        return unsigned'(driver_state);
    endfunction
    function automatic logic legal(input axi_a_t address);
        logic timer64;
        timer64 = core_config_pkg::XLEN == 64 && address.addr[31:16] == 16'h0200 &&
                  (address.addr[15:0] == 16'h4000 || address.addr[15:0] == 16'hbff8);
        return address.len == 0 && !address.prot[2] && !address.lock && address.burst == 1 &&
               address.addr[1:0] == 0 && (address.size == 2 || (address.size == 3 && timer64));
    endfunction
    function automatic logic [31:0] strobe_mask(input axi_a_t address);
        return (32'hffffffff >> (32-(1<<address.size))) << address.addr[4:0];
    endfunction
    function automatic logic [63:0] read_value(input logic [31:0] address);
        return 64'h8f42c171eab569a3 ^ {address, ~address};
    endfunction
    function automatic axi_resp_e target_response(input logic [31:0] address);
        return address[8] ? AXI_SLVERR : AXI_OKAY;
    endfunction
    function automatic axi_a_t address_at(input logic [31:0] address, input int id);
        axi_a_t value;
        value = '0; value.addr = address; value.id = axi_id_t'(id); value.size = 2; value.burst = 1;
        return value;
    endfunction
    function automatic logic [255:0] write_data(input int index);
        logic [255:0] data;
        for (int word = 0; word < 8; word++) data[word*32+:32] = 32'h4a000000 ^ (word*'h12345) ^ index;
        return data;
    endfunction

    // 从设备独立接受AW/W，延后B/R，并在反压期间保持响应载荷。
    always_comb begin
        m_rsp = '0;
        m_rsp.aw_ready = !aw_seen && (bp_state[0] || bp_state[7]);
        m_rsp.w_ready = !w_seen && (bp_state[1] || bp_state[9]);
        m_rsp.b_valid = aw_seen && w_seen && b_delay == 0;
        m_rsp.b = target_response(aw_addr);
        m_rsp.ar_ready = !read_pending && (bp_state[2] || bp_state[11]);
        m_rsp.r_valid = read_pending && r_delay == 0;
        m_rsp.r = '{data:read_value(read_addr), resp:target_response(read_addr)};
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_seen <= 0; w_seen <= 0; read_pending <= 0;
            b_delay <= 0; r_delay <= 0; aw_addr <= 0; read_addr <= 0;
            bp_state <= 32'h38196b2f;
            aw_transfers <= 0; w_transfers <= 0; ar_transfers <= 0; input_w_beats <= 0;
        end else begin
            bp_state <= {bp_state[30:0], bp_state[31] ^ bp_state[21] ^ bp_state[1] ^ bp_state[0]};
            if (m_req_old.aw_valid && m_rsp.aw_ready) begin
                assert (write_active && expect_forward && m_req_old.aw.addr == active_address.addr &&
                        m_req_old.aw.prot == active_address.prot) else $fatal(1, "AXIL AW payload/eligibility wrong");
                aw_seen <= 1; aw_addr <= m_req_old.aw.addr; b_delay <= {1'b0, bp_state[6:4]};
                aw_transfers <= aw_transfers + 1;
            end
            if (m_req_old.w_valid && m_rsp.w_ready) begin
                assert (write_active && expect_forward && m_req_old.w.data == active_data &&
                        m_req_old.w.strb == active_strobe) else $fatal(1, "AXIL W byte lane/data wrong");
                w_seen <= 1; w_transfers <= w_transfers + 1;
            end
            if (aw_seen && w_seen && b_delay != 0) b_delay <= b_delay - 1'b1;
            if (m_rsp.b_valid && m_req_old.b_ready) begin aw_seen <= 0; w_seen <= 0; end
            if (m_req_old.ar_valid && m_rsp.ar_ready) begin
                read_pending <= 1; read_addr <= m_req_old.ar.addr; r_delay <= {1'b0, bp_state[14:12]};
                ar_transfers <= ar_transfers + 1;
            end
            if (read_pending && r_delay != 0) r_delay <= r_delay - 1'b1;
            if (m_rsp.r_valid && m_req_old.r_ready) read_pending <= 0;
            if (s_req.w_valid && s_rsp_old.w_ready) input_w_beats <= input_w_beats + 1;
            if (write_active && s_rsp_old.b_valid && s_req.b_ready)
                assert (input_w_beats >= write_start + write_expected)
                    else $fatal(1, "B response before complete invalid-burst drain");
        end
    end
    always @(negedge clk) begin
        s_req.b_ready = bp_state[3] || bp_state[13];
        s_req.r_ready = bp_state[5] || bp_state[15];
    end
    task automatic compare_all;
        assert (s_rsp_new === s_rsp_old) else $fatal(1, "AXI response mismatch check=%0d new=%p old=%p", checks, s_rsp_new, s_rsp_old);
        assert (m_req_new === m_req_old) else $fatal(1, "AXIL request mismatch check=%0d new=%p old=%p", checks, m_req_new, m_req_old);
        assert ({dut_new.ar_q, dut_new.aw_q, dut_new.w_q, dut_new.read_q, dut_new.write_q,
                 dut_new.aw_sent_q, dut_new.w_sent_q, dut_new.read_error_q, dut_new.write_error_q,
                 dut_new.write_collected_q, dut_new.drain_q, dut_new.read_beat_q} ===
                {dut_old.ar_q, dut_old.aw_q, dut_old.w_q, dut_old.read_q, dut_old.write_q,
                 dut_old.aw_sent_q, dut_old.w_sent_q, dut_old.read_error_q, dut_old.write_error_q,
                 dut_old.write_collected_q, dut_old.drain_q, dut_old.read_beat_q})
            else $fatal(1, "bridge common state mismatch check=%0d", checks);
        checks++;
    endtask
    always @(negedge clk) begin #1; compare_all(); end
    always @(posedge clk) begin #1; compare_all(); end

    task automatic send_aw(input axi_a_t address, input int delay);
        int timeout_count;
        repeat (delay) @(negedge clk);
        s_req.aw = address; s_req.aw_valid = 1; timeout_count = 0;
        do begin @(posedge clk); timeout_count++; if (timeout_count > 10000) $fatal(1, "AW timeout"); end
        while (!s_rsp_old.aw_ready);
        @(negedge clk); s_req.aw_valid = 0;
    endtask
    task automatic send_w(input axi_a_t address, input logic bad_strobe, input int last_mode, delay);
        int timeout_count;
        axi_w_t beat;
        repeat (delay) @(negedge clk);
        for (int index = 0; index <= int'(address.len); index++) begin
            beat.data = write_data(index);
            beat.strb = strobe_mask(address);
            if (bad_strobe) beat.strb ^= 32'h1 << ((int'(address.addr[4:0])+8)%32);
            beat.last = index == int'(address.len);
            if (last_mode == 1 && index == 0) beat.last = 1;
            if (last_mode == 2 && index == int'(address.len)) beat.last = 0;
            s_req.w = beat; s_req.w_valid = 1; timeout_count = 0;
            do begin @(posedge clk); timeout_count++; if (timeout_count > 10000) $fatal(1, "W timeout"); end
            while (!s_rsp_old.w_ready);
            @(negedge clk); s_req.w_valid = 0;
        end
    endtask
    task automatic write_transaction(input axi_a_t address, input int aw_delay, w_delay,
                                     input logic bad_strobe = 0, input int last_mode = 0);
        int timeout_count, old_aw, old_w;
        logic valid_write;
        axi_resp_e expected;
        old_aw = aw_transfers; old_w = w_transfers;
        valid_write = legal(address) && !bad_strobe && last_mode != 2;
        expected = valid_write ? target_response(address.addr) : AXI_SLVERR;
        active_address = address; expect_forward = valid_write;
        active_data = 64'(write_data(int'(address.len)) >> (64*int'(address.addr[4:3])));
        active_strobe = 8'(strobe_mask(address) >> (8*int'(address.addr[4:3])));
        write_active = 1; write_start = input_w_beats; write_expected = int'(address.len)+1;
        fork send_aw(address, aw_delay); send_w(address, bad_strobe, last_mode, w_delay); join
        timeout_count = 0;
        do begin @(posedge clk); timeout_count++; if (timeout_count > 10000) $fatal(1, "B timeout"); end
        while (!(s_rsp_old.b_valid && s_req.b_ready));
        assert (s_rsp_old.b.id == address.id && s_rsp_old.b.resp == expected)
            else $fatal(1, "B wrong id/response address=%p got=%p expected=%p", address, s_rsp_old.b, expected);
        @(negedge clk); write_active = 0;
        assert (aw_transfers == old_aw + int'(valid_write) && w_transfers == old_w + int'(valid_write))
            else $fatal(1, "invalid write reached AXIL or legal write missing");
        writes++;
    endtask
    task automatic read_transaction(input axi_a_t address);
        int timeout_count, old_ar;
        logic [255:0] expected_data;
        axi_resp_e expected;
        old_ar = ar_transfers;
        s_req.ar = address; s_req.ar_valid = 1; timeout_count = 0;
        do begin @(posedge clk); timeout_count++; if (timeout_count > 10000) $fatal(1, "AR timeout"); end
        while (!s_rsp_old.ar_ready);
        @(negedge clk); s_req.ar_valid = 0;
        expected = legal(address) ? target_response(address.addr) : AXI_SLVERR;
        expected_data = legal(address) ? 256'(read_value(address.addr)) << (64*int'(address.addr[4:3])) : '0;
        for (int beat = 0; beat <= int'(address.len); beat++) begin
            timeout_count = 0;
            do begin @(posedge clk); timeout_count++; if (timeout_count > 10000) $fatal(1, "R timeout"); end
            while (!(s_rsp_old.r_valid && s_req.r_ready));
            assert (s_rsp_old.r.id == address.id && s_rsp_old.r.resp == expected &&
                    s_rsp_old.r.data == expected_data && s_rsp_old.r.last == (beat == int'(address.len)))
                else $fatal(1, "R wrong id/data/resp/last address=%p beat=%0d got=%p", address, beat, s_rsp_old.r);
            @(negedge clk);
        end
        assert (ar_transfers == old_ar + int'(legal(address))) else $fatal(1, "invalid AR reached AXIL");
        reads++;
    endtask

    initial begin
        axi_a_t address;
        s_req = '0;
        repeat (3) @(negedge clk); rst = 0;
        for (int lane = 0; lane < 8; lane++) begin
            address = address_at(32'h10000000+lane*4, lane);
            write_transaction(address, lane%3 == 0 ? 9 : 0, lane%3 == 1 ? 9 : 0);
            read_transaction(address);
            write_transaction(address, 3, 0, 1);
        end
        // RV64定时器两个64位位置及其高低32位字节选通。
        for (int timer_reg = 0; timer_reg < 2; timer_reg++) begin
            address = address_at(timer_reg ? 32'h0200bff8 : 32'h02004000, timer_reg+9);
            address.size = 3; write_transaction(address, 0, 5); read_transaction(address);
            address.size = 2; write_transaction(address, 5, 0); read_transaction(address);
            address.addr += 4; write_transaction(address, 0, 0); read_transaction(address);
        end
        for (int fault = 0; fault < 9; fault++) begin
            address = address_at(32'h10000010, fault);
            unique case (fault)
                0: address.size = 0;
                1: address.size = 1;
                2: address.size = 3;
                3: address.size = 7;
                4: address.len = 1;
                5: address.prot[2] = 1;
                6: address.lock = 1;
                7: address.burst = 0;
                default: address.addr[1:0] = 2;
            endcase
            write_transaction(address, fault%2 == 0 ? 7 : 0, fault%2 == 1 ? 7 : 0);
            read_transaction(address);
        end
        address = address_at(32'h10000000, 7); write_transaction(address, 0, 0, 0, 2);
        address.len = 255; write_transaction(address, 11, 0, 0, 1); read_transaction(address);
        address = address_at(32'h10000118, 13); write_transaction(address, 0, 8); read_transaction(address);
        for (int trial = 0; trial < 300; trial++) begin
            address = address_at(32'h10000000 + ((random_word()%16)*4), int'(random_word()));
            if (trial%3 == 0) address.size = 3'(random_word());
            if (trial%7 == 0) address.len = 8'(random_word()%8);
            if (trial%11 == 0) address.prot = 3'(random_word());
            if (trial%13 == 0) address.lock = 1;
            if (trial%17 == 0) address.burst = 2'(random_word());
            write_transaction(address, int'(random_word()%9), int'(random_word()%9), trial%19 == 0, trial%23 == 0 ? 2 : 0);
            if (trial%2 == 0) read_transaction(address);
        end
        $display("PASS tb_axi_to_axil_mask_miter XLEN=%0d writes=%0d reads=%0d checks=%0d drain256=1 AW_W_orders=3 timer64=1 random_backpressure=1", core_config_pkg::XLEN, writes, reads, checks);
        $finish;
    end
endmodule
