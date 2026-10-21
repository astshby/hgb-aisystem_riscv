// Module: tb_scoreboard_tcm
// Description: Checks native IF64, parallel data banks, fair DMA arbitration and held responses against RAM.
module tb_scoreboard_tcm;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    localparam int BYTES = 256, WORDS = BYTES/DBUS_BYTES;
    logic clk = 0, rst = 1;
    logic [3:0] req_valid, req_ready, rsp_valid, rsp_ready, accepted;
    bus_req_t request [4];
    logic [63:0] rsp_data [4], expected [4];
    xlen_t memory [WORDS];
    logic [3:0] pending, was_write;
    int count [4], replies [4], dual_data, cycles, if_streak, max_if_streak;
    logic [31:0] random_q = 32'h4623ace9;
    tcm_dual_bank #(.BYTES(BYTES)) dut (.*);
    always #5 clk = ~clk;
    function automatic logic [31:0] random_word;
        random_q ^= random_q << 13; random_q ^= random_q >> 17; random_q ^= random_q << 5;
        return random_q;
    endfunction
    function automatic bus_req_t access(input int index, input bit write_enable, input xlen_t value = 0);
        return '{addr:xlen_t'(index*DBUS_BYTES), write:write_enable, execute:1'b0,
                 size:mem_size_e'($clog2(DBUS_BYTES)), wdata:value, wstrb:'1};
    endfunction
    always @(posedge clk) if (!rst) begin
        cycles++;
        accepted = req_valid & req_ready;
        if (accepted[1] && accepted[2]) dual_data++;
        if_streak = accepted[0] ? if_streak+1 : 0;
        if (if_streak > max_if_streak) max_if_streak = if_streak;
        for (int p = 0; p < 4; p++) begin
            if (rsp_valid[p]) begin
                assert (pending[p]) else $fatal(1, "unsolicited TCM response p=%0d",p);
                if (!was_write[p]) assert (rsp_data[p] == expected[p])
                    else $fatal(1, "TCM data p=%0d got=%h expected=%h",p,rsp_data[p],expected[p]);
                if (rsp_ready[p]) begin pending[p] = 0; replies[p]++; end
            end
            if (accepted[p]) begin
                assert (!pending[p]) else $fatal(1, "TCM client response overwritten");
                pending[p] = 1; was_write[p] = request[p].write; count[p]++;
                expected[p] = 64'(memory[int'(request[p].addr)/DBUS_BYTES]);
                if (p == 0 && XLEN == 32)
                    expected[p][63:32] = 32'(memory[int'(request[p].addr)/DBUS_BYTES+1]);
            end
        end
        // 同 bank 仲裁排除了同 word 读写同时成功；所有读的参考值取这一沿写入之前。
        for (int p = 1; p < 4; p++) if (accepted[p] && request[p].write)
            for (int b = 0; b < DBUS_BYTES; b++) if (request[p].wstrb[b])
                memory[int'(request[p].addr)/DBUS_BYTES][8*b +: 8] = request[p].wdata[8*b +: 8];
    end
    initial begin
        req_valid = 0; rsp_ready = 15; pending = 0; accepted = 0; was_write = 0;
        for (int p = 0; p < 4; p++) begin request[p] = '0; count[p] = 0; replies[p] = 0; end
        repeat (3) @(negedge clk); rst = 0;
        for (int i = 0; i < WORDS; i++) begin
            req_valid = 2; request[1] = access(i,1,xlen_t'(32'h13240000+i));
            @(posedge clk); #1; assert (accepted[1]) else $fatal;
            @(negedge clk);
        end
        req_valid = 0; repeat (2) @(negedge clk);
        // IF 单独连续读；两数据口在不同 bank 可同拍并行，均保持一拍返回。
        for (int i = 0; i < 80; i++) begin
            req_valid = 1; request[0] = access((i*8 % BYTES)/DBUS_BYTES,0);
            @(posedge clk); #1; assert (accepted[0]) else $fatal(1, "native IF II != 1");
            @(negedge clk);
        end
        req_valid = 0; repeat (2) @(negedge clk);
        for (int i = 0; i < 80; i++) begin
            req_valid = 6; request[1] = access(2*(i%(WORDS/2)),0); request[2] = access(2*(i%(WORDS/2))+1,0);
            @(posedge clk); #1; assert (accepted[2:1] == 3) else $fatal(1, "different data banks serialized");
            @(negedge clk);
        end
        req_valid = 0; repeat (2) @(negedge clk);
        // IF 被反压时，其旧响应进入专用缓冲；两数据口仍须连续使用同一块 TCM。
        req_valid = 1; request[0] = access(0,0); rsp_ready[0] = 0;
        @(posedge clk); #1; assert (accepted[0]) else $fatal;
        @(negedge clk); req_valid = 0; repeat (3) @(negedge clk);
        for (int i = 0; i < 20; i++) begin
            req_valid = 6; request[1] = access(0,0); request[2] = access(1,0);
            @(posedge clk); #1;
            assert (accepted[2:1] == 3 && rsp_valid[0]) else $fatal(1, "stalled IF holds shared RAM banks");
            @(negedge clk);
        end
        req_valid = 0; rsp_ready = 15; repeat (2) @(negedge clk);
        // 四客户端持续争用，其中 IF 的双 bank 请求必须得到原子且公平的服务。
        begin
            int before_count [4];
            for (int p = 0; p < 4; p++) begin before_count[p] = count[p]; request[p] = access(p == 0 ? 0 : p,0); end
            req_valid = 15;
            repeat (100) @(negedge clk);
            for (int p = 0; p < 4; p++)
                assert (count[p]-before_count[p] >= 20) else $fatal(1, "TCM arbitration starved p=%0d",p);
        end
        req_valid = 0; repeat (2) @(negedge clk);
        // 固定种子随机 byte-mask Store、同 bank 冲突与响应反压；展示后请求保持到接受。
        for (int i = 0; i < 500; i++) begin
            for (int p = 0; p < 4; p++) begin
                if (!req_valid[p] || accepted[p]) begin
                    req_valid[p] = 1'(random_word());
                    request[p] = access(int'(random_word()%WORDS),p != 0 && (random_word()%4 == 0),xlen_t'(random_word()));
                    if (p == 0) request[p].addr &= ~xlen_t'(7);
                    request[p].wstrb = DBUS_BYTES'(random_word());
                end
                rsp_ready[p] = random_word()%5 != 0;
            end
            @(negedge clk);
        end
        // 排空仍展示的请求后才停止输入。
        rsp_ready = 15;
        while (|req_valid) begin @(negedge clk); req_valid &= ~accepted; end
        repeat (3) @(negedge clk);
        for (int p = 0; p < 4; p++) assert (count[p] == replies[p]) else $fatal(1, "response balance");
        assert (max_if_streak >= 80 && dual_data >= 80 && pending == 0) else $fatal;
        $display("PASS tb_scoreboard_tcm XLEN=%0d IF_streak=%0d dual_data=%0d requests=%0d/%0d/%0d/%0d",
                 XLEN,max_if_streak,dual_data,count[0],count[1],count[2],count[3]);
        $finish;
    end
endmodule
