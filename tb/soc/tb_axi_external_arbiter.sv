// Module: tb_axi_external_arbiter
// Description: Independent read/write ownership, all AXI backpressure channels, burst fairness and common-reset cancellation.
module tb_axi_external_arbiter;
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk = 0, rst = 1, stall = 1;
    always #5ns clk = !clk;
    axi_req_t s_req [2], m_req;
    axi_rsp_t s_rsp [2], m_rsp;
    logic [1:0] done = 0;
    int cycles = 0, read_transactions = 0, write_transactions = 0;
    int previous_owner = -1, fairness_checks = 0;
    int previous_write_owner = -1, write_fairness_checks = 0;
    axi_external_arbiter dut (.*);
    axi_system_memory_model u_ram (.clk, .rst, .stall, .req(m_req), .rsp(m_rsp),
        .fault_read_addr(32'hffffffff), .fault_write_addr(32'hffffffff));
    function automatic logic [255:0] payload(input int master, number, beat);
        logic [255:0] data;
        for (int b = 0; b < 32; b++) data[b*8+:8] = 8'(master*97+number*11+beat*7+b);
        return data;
    endfunction
    always @(posedge clk) begin
        cycles++;
        if (!rst) begin
            if (m_req.ar_valid && m_rsp.ar_ready) begin
                read_transactions++;
                if (s_req[0].ar_valid && s_req[1].ar_valid) begin
                    if (previous_owner >= 0) assert (int'(dut.read_owner) != previous_owner)
                        else $fatal(1, "read arbitration starved a continuously waiting owner");
                    previous_owner = int'(dut.read_owner);
                    fairness_checks++;
                end else previous_owner = -1;
            end
            if (m_req.aw_valid && m_rsp.aw_ready) begin
                write_transactions++;
                if (s_req[0].aw_valid && s_req[1].aw_valid) begin
                    if (previous_write_owner >= 0) assert (int'(dut.write_owner) != previous_write_owner)
                        else $fatal(1, "write arbitration starved a continuously waiting owner");
                    previous_write_owner = int'(dut.write_owner);
                    write_fairness_checks++;
                end else previous_write_owner = -1;
            end
            assert (!(s_rsp[0].r_valid && s_rsp[1].r_valid)) else $fatal(1, "R broadcast to two owners");
            assert (!(s_rsp[0].b_valid && s_rsp[1].b_valid)) else $fatal(1, "B broadcast to two owners");
        end
    end
    initial begin
        s_req[0] = '0; s_req[1] = '0;
        repeat (4) @(negedge clk);
        rst = 0;
        // 同时挂起两个地址，地址受阻时不能换 owner；公共复位取消尚未被目标接收的旧请求。
        s_req[0].ar_valid = 1; s_req[1].ar_valid = 1;
        s_req[0].ar = '{addr:32'h80000000, len:3, size:5, burst:1, default:'0};
        s_req[1].ar = '{addr:32'h80001000, len:3, size:5, burst:1, default:'0};
        repeat (6) @(negedge clk);
        assert (dut.read_state_q == dut.ADDRESS && dut.read_owner_q == 0)
            else $fatal(1, "stalled address owner not retained");
        rst = 1; s_req[0] = '0; s_req[1] = '0;
        repeat (3) @(negedge clk);
        rst = 0; stall = 0;
    end
    for (genvar m = 0; m < 2; m++) begin : g_master
        int n, beat;
        bit aw_done, data_done, response_done;
        logic [31:0] addr;
        initial begin
            wait (!rst && !stall);
            for (n = 0; n < 24; n++) begin
                addr = 32'h80000000+32'(m*16384+n*128);
                aw_done = 0; data_done = 0; response_done = 0; beat = 0;
                while (!response_done) begin
                    @(negedge clk);
                    s_req[m].aw_valid = !aw_done;
                    s_req[m].aw = '{id:axi_id_t'(m), addr:addr, len:8'(n%4), size:5, burst:1, default:'0};
                    s_req[m].w_valid = !data_done && cycles%5 != m;
                    s_req[m].w = '{data:payload(m,n,beat), strb:'1, last:beat == n%4};
                    s_req[m].b_ready = cycles%7 != m;
                    @(posedge clk);
                    if (s_req[m].aw_valid && s_rsp[m].aw_ready) aw_done = 1;
                    if (s_req[m].w_valid && s_rsp[m].w_ready) begin
                        if (beat == n%4) data_done = 1;
                        else beat++;
                    end
                    if (s_rsp[m].b_valid && s_req[m].b_ready) begin
                        assert (aw_done && data_done && s_rsp[m].b.id == axi_id_t'(m) && s_rsp[m].b.resp == AXI_OKAY)
                            else $fatal(1, "write owner/ID error master=%0d", m);
                        response_done = 1;
                    end
                end
                @(negedge clk); s_req[m] = '0;
                aw_done = 0; response_done = 0; beat = 0;
                while (!response_done) begin
                    @(negedge clk);
                    s_req[m].ar_valid = !aw_done;
                    s_req[m].ar = '{id:axi_id_t'(m), addr:addr, len:8'(n%4), size:5, burst:1, default:'0};
                    s_req[m].r_ready = cycles%5 != m;
                    @(posedge clk);
                    if (s_req[m].ar_valid && s_rsp[m].ar_ready) aw_done = 1;
                    if (s_rsp[m].r_valid && s_req[m].r_ready) begin
                        assert (s_rsp[m].r.id == axi_id_t'(m) && s_rsp[m].r.resp == AXI_OKAY &&
                            s_rsp[m].r.data == payload(m,n,beat) && s_rsp[m].r.last == (beat == n%4))
                            else $fatal(1, "read owner/data error master=%0d n=%0d beat=%0d", m,n,beat);
                        if (s_rsp[m].r.last) response_done = 1;
                        else beat++;
                    end
                end
                @(negedge clk); s_req[m] = '0;
            end
            done[m] = 1;
        end
    end
    initial begin
        wait (&done);
        // 两路持续保持 AR 请求，响应可反压；每路八笔，检查真正同时等待时的轮换。
        begin
            int accepted [2], completed [2];
            for (int m = 0; m < 2; m++) begin accepted[m] = 0; completed[m] = 0; end
            while (completed[0] != 8 || completed[1] != 8) begin
                @(negedge clk);
                for (int m = 0; m < 2; m++) begin
                    s_req[m] = '0;
                    s_req[m].ar_valid = accepted[m] < 8;
                    s_req[m].ar = '{id:axi_id_t'(m), addr:32'h80000000+32'(m*16384),
                        len:3, size:5, burst:1, default:'0};
                    s_req[m].r_ready = cycles%5 != m;
                end
                @(posedge clk);
                for (int m = 0; m < 2; m++) begin
                    if (s_req[m].ar_valid && s_rsp[m].ar_ready) accepted[m]++;
                    if (s_rsp[m].r_valid && s_req[m].r_ready) begin
                        assert (s_rsp[m].r.id == axi_id_t'(m)) else $fatal(1, "fair-read response misrouted");
                        if (s_rsp[m].r.last) completed[m]++;
                    end
                end
            end
        end
        @(negedge clk); s_req[0] = '0; s_req[1] = '0;
        assert (fairness_checks >= 10) else $fatal(1, "continuous contention was not exercised");
        // 两路持续保持 AW 请求，独立错开 W 与 B；下一地址在接收后立即推进并保持稳定。
        begin
            int accepted [2], completed [2], beats [2];
            bit data_done [2];
            for (int m = 0; m < 2; m++) begin
                accepted[m] = 0; completed[m] = 0; beats[m] = 0; data_done[m] = 0;
            end
            while (completed[0] != 8 || completed[1] != 8) begin
                @(negedge clk);
                for (int m = 0; m < 2; m++) begin
                    s_req[m] = '0;
                    s_req[m].aw_valid = accepted[m] < 8;
                    s_req[m].aw = '{id:axi_id_t'(m),
                        addr:32'h80003000+32'(m*16384+accepted[m]*128),
                        len:3, size:5, burst:1, default:'0};
                    s_req[m].w_valid = accepted[m] > completed[m] && !data_done[m] && cycles%5 != m;
                    s_req[m].w = '{data:payload(m,30+completed[m],beats[m]), strb:'1, last:beats[m] == 3};
                    s_req[m].b_ready = cycles%7 != m;
                end
                @(posedge clk);
                for (int m = 0; m < 2; m++) begin
                    if (s_req[m].aw_valid && s_rsp[m].aw_ready) begin
                        accepted[m]++; beats[m] = 0; data_done[m] = 0;
                    end
                    if (s_req[m].w_valid && s_rsp[m].w_ready) begin
                        if (beats[m] == 3) data_done[m] = 1;
                        else beats[m]++;
                    end
                    if (s_rsp[m].b_valid && s_req[m].b_ready) begin
                        assert (s_rsp[m].b.id == axi_id_t'(m) && s_rsp[m].b.resp == AXI_OKAY && data_done[m])
                            else $fatal(1, "fair-write response misrouted");
                        completed[m]++;
                    end
                end
            end
        end
        @(negedge clk); s_req[0] = '0; s_req[1] = '0;
        assert (write_fairness_checks >= 10) else $fatal(1, "continuous write contention was not exercised");
        // AR 已接收、R 被反压，同时 AW 已接收而 W 尚未来到：公共复位取消两个 owner。
        begin
            bit ar_accepted, aw_accepted;
            ar_accepted = 0; aw_accepted = 0;
            while (!ar_accepted || !aw_accepted) begin
                @(negedge clk);
                s_req[0].ar_valid = !ar_accepted;
                s_req[0].ar = '{addr:32'h80000000, len:3, size:5, burst:1, default:'0};
                s_req[1].aw_valid = !aw_accepted;
                s_req[1].aw = '{addr:32'h80001000, len:1, size:5, burst:1, default:'0};
                @(posedge clk);
                if (s_req[0].ar_valid && s_rsp[0].ar_ready) ar_accepted = 1;
                if (s_req[1].aw_valid && s_rsp[1].aw_ready) aw_accepted = 1;
            end
        end
        @(negedge clk); s_req[0] = '0; s_req[1] = '0;
        repeat (4) @(negedge clk);
        assert (dut.read_state_q == dut.RESPONSE && dut.write_state_q == dut.DATA)
            else $fatal(1, "in-flight cancel states not reached");
        rst = 1;
        repeat (3) @(negedge clk);
        assert (dut.read_state_q == dut.IDLE && dut.write_state_q == dut.IDLE &&
                !s_rsp[0].r_valid && !s_rsp[1].b_valid)
            else $fatal(1, "old owner survived coordinated reset");
        rst = 0;
        s_req[1].ar_valid = 1;
        s_req[1].ar = '{id:3, addr:32'h80001000, len:0, size:5, burst:1, default:'0};
        do @(posedge clk); while (!s_rsp[1].ar_ready);
        @(negedge clk); s_req[1].ar_valid = 0; s_req[1].r_ready = 1;
        do @(posedge clk); while (!s_rsp[1].r_valid);
        assert (s_rsp[1].r.id == 3 && s_rsp[1].r.last && !s_rsp[0].r_valid)
            else $fatal(1, "response after reset used an old owner");
        assert (read_transactions == 66 && write_transactions == 65) else $fatal(1, "transactions lost/duplicated");
        $display("PASS tb_axi_external_arbiter reads=%0d writes=%0d fairness_R=%0d fairness_W=%0d reset_cancel=3", read_transactions, write_transactions, fairness_checks, write_fairness_checks);
        $finish;
    end
    initial begin #1ms; $fatal(1, "arbiter timeout"); end
endmodule
