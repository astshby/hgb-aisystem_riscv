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
            if (m_req.aw_valid && m_rsp.aw_ready) write_transactions++;
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
        assert (read_transactions == 48 && write_transactions == 48) else $fatal(1, "transactions lost/duplicated");
        $display("PASS tb_axi_external_arbiter reads=%0d writes=%0d fairness=%0d reset_cancel=1", read_transactions, write_transactions, fairness_checks);
        $finish;
    end
    initial begin #1ms; $fatal(1, "arbiter timeout"); end
endmodule
