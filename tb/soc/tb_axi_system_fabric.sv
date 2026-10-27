// Module: tb_axi_system_fabric
// Description: Concurrent masters, reordered targets, independent AW/W, backpressure, errors and CDC.
module tb_axi_system_fabric #(
    parameter int SYS_HALF_PS = 5000,
    parameter int TARGET_HALF_PS = 6250,
    parameter int CDC_DEPTH = 8,
    parameter bit NATIVE_DDR = 0
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk = 0, device_clk = 0, rst = 1;
    always #(SYS_HALF_PS * 1ps) clk = !clk;
    initial begin #1700ps; forever #(TARGET_HALF_PS * 1ps) device_clk = !device_clk; end
    axi_req_t m_req [4], s_req [7], device_req [7];
    axi_rsp_t m_rsp [4], s_rsp [7], device_rsp [7];
    logic [3:0] done = 0;
    int cycles = 0;
    int early_completions = 0;
    logic slow_stall;
    assign slow_stall = cycles < 200;
    axi_system_fabric #(.DDR_BYTES(65536), .FLASH_BYTES(65536), .NPU_BYTES(65536)) dut (.*);
    for (genvar t = 0; t < 7; t++) begin : g_target
        axi_clock_bridge #(.DEPTH(CDC_DEPTH)) u_cdc (.s_clk(clk), .s_rst(rst), .m_clk(device_clk), .m_rst(rst),
            .s_req(s_req[t]), .s_rsp(s_rsp[t]), .m_req(device_req[t]), .m_rsp(device_rsp[t]));
        if (t == 0 || t == 1 || t == 4 || t == 5) begin : g_error
            axi_error_target u_target (.clk(device_clk), .rst, .req(device_req[t]), .rsp(device_rsp[t]));
        end else if (t == 3 && NATIVE_DDR) begin : g_native
            axi_native_memory_model #(.BYTES(65536)) u_target (.clk(device_clk),.rst,.stall(1'b0),.memory_ready(1'b1),
                .req(device_req[t]),.rsp(device_rsp[t]));
        end else begin : g_ram
            localparam logic [31:0] BASE = t == 2 ? 32'h01000000 : t == 3 ? 32'h80000000 : 32'h20000000;
            axi_system_memory_model #(.BASE(BASE)) u_target (.clk(device_clk), .rst,
                .stall(t == 2 && slow_stall), .req(device_req[t]), .rsp(device_rsp[t]),
                .fault_read_addr(32'hffffffff), .fault_write_addr(32'hffffffff));
        end
    end
    function automatic logic [31:0] address(input int master, input int n);
        logic [31:0] base;
        base = n%4 == 0 ? 32'h01000000 : n%4 == 1 ? 32'h80000000 :
               n%4 == 2 ? 32'h20000000 : 32'hdead0000;
        return base + 32'(master*8192 + n*128);
    endfunction
    function automatic logic [255:0] pattern(input int master, input int n, input int beat);
        logic [255:0] result;
        for (int byte_n = 0; byte_n < 32; byte_n++) result[byte_n*8 +: 8] = 8'(master*37+n*13+beat*7+byte_n);
        return result;
    endfunction
    for (genvar m = 0; m < 4; m++) begin : g_master
        int ai, wi, wb, bi, ari, ri;
        int aw_cycle[32], max_write_latency=0, w_streak=0, max_w_streak=0;
        int b_seq [4], r_seq [4], r_beat [4];
        initial begin
            m_req[m] = '0;
            ai=0; wi=0; wb=0; bi=0; ari=0; ri=0;
            for (int id=0; id<4; id++) begin b_seq[id]=id; r_seq[id]=id; r_beat[id]=0; end
            wait (!rst);
            while (ri < 32) begin
                @(negedge clk);
                m_req[m].aw_valid = ai < 32;
                m_req[m].aw = '{id:axi_id_t'(ai%4), addr:address(m,ai), len:8'(ai%3),
                               size:3'd5, burst:2'b01, default:'0};
                // W 可先于 AW 被入口缓冲；之后连续 W 检查 owner FIFO 的周转。
                m_req[m].w_valid = wi < 32;
                m_req[m].w = '{data:pattern(m,wi,wb), strb:'1, last:wb==wi%3};
                m_req[m].b_ready = cycles%7 != m && cycles%7 != m+1;
                m_req[m].ar_valid = bi == 32 && ari < 32;
                m_req[m].ar = '{id:axi_id_t'(ari%4), addr:address(m,ari), len:8'(ari%3),
                               size:3'd5, burst:2'b01, default:'0};
                m_req[m].r_ready = cycles%9 != m && cycles%9 != m+1;
                @(posedge clk);
                if (m_req[m].aw_valid && m_rsp[m].aw_ready) begin aw_cycle[ai]=cycles; ai++; end
                if (m_req[m].w_valid && m_rsp[m].w_ready) begin
                    w_streak++; if(w_streak>max_w_streak) max_w_streak=w_streak;
                    if (wb == wi%3) begin wi++; wb=0; end else wb++;
                end else w_streak=0;
                if (m_rsp[m].b_valid && m_req[m].b_ready) begin
                    int id, n;
                    id=int'(m_rsp[m].b.id); n=b_seq[id];
                    assert (id < 4 && n < 32 && m_rsp[m].b.resp == (n%4 == 3 ? AXI_DECERR : AXI_OKAY))
                        else $fatal(1,"B owner/error m=%0d id=%0d n=%0d resp=%0d",m,id,n,m_rsp[m].b.resp);
                    if(cycles-aw_cycle[n]>max_write_latency) max_write_latency=cycles-aw_cycle[n];
                    b_seq[id]+=4; bi++;
                    if (cycles < 200) early_completions++;
                end
                if (m_req[m].ar_valid && m_rsp[m].ar_ready) ari++;
                if (m_rsp[m].r_valid && m_req[m].r_ready) begin
                    int id, n, beat;
                    id=int'(m_rsp[m].r.id); n=r_seq[id]; beat=r_beat[id];
                    assert (id<4 && n<32 && m_rsp[m].r.last == (beat==n%3) &&
                            m_rsp[m].r.resp == (n%4==3 ? AXI_DECERR : AXI_OKAY))
                        else $fatal(1,"R framing/owner m=%0d id=%0d n=%0d beat=%0d",m,id,n,beat);
                    if (n%4 != 3) assert (m_rsp[m].r.data == pattern(m,n,beat))
                        else $fatal(1,"R data m=%0d n=%0d beat=%0d",m,n,beat);
                    if (m_rsp[m].r.last) begin r_seq[id]+=4; r_beat[id]=0; ri++; end
                    else r_beat[id]++;
                end
            end
            @(negedge clk); m_req[m]='0; done[m]=1;
            assert(max_w_streak>=2) else $fatal(1,"write stream became serialized");
            $display("FABRIC_METRIC master=%0d max_write_response_cycles=%0d max_w_accept_streak=%0d",m,max_write_latency,max_w_streak);
        end
    end
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (cycles > 30000) $fatal(1,"fabric timeout done=%b",done);
    end
    initial begin
        repeat (8) @(negedge clk);
        rst=0;
        wait (&done);
        assert (early_completions > 0) else $fatal(1,"slow target blocked unrelated targets");
        $display("PASS tb_axi_system_fabric writes=128 reads=128 masters=4 depth=%0d sys_half_ps=%0d target_half_ps=%0d early=%0d cycles=%0d",
                 CDC_DEPTH,SYS_HALF_PS,TARGET_HALF_PS,early_completions,cycles);
        $finish;
    end
endmodule
