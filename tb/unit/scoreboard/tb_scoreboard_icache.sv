// Module: tb_scoreboard_icache
// Description: Checks IF64 hit throughput, held data, invalidate during fill and per-word error fallback.
module tb_scoreboard_icache_case #(parameter bit BLOCK = 0) (output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    logic clk = 0, rst = 1, invalidate = 0, req_valid = 0, req_ready, rsp_valid, rsp_ready = 1;
    xlen_t req_addr;
    logic [63:0] rsp_data, expected_data;
    logic [1:0] rsp_error, expected_error;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    bus_req_t mem_request;
    bus_rsp_t mem_response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid = 0, rd_ready;
    block_cmd_t rd_cmd;
    block_r_t rd_data;
    xlen_t fault_word = '1;
    bit block_fault = 0, pending = 0, accepted = 0;
    int cycles, requests, replies, accesses, streak, max_streak, hits;
    icache_native #(.DDR_BYTES(8192), .CACHE_BYTES(256), .BLOCK_ENABLE(BLOCK)) dut (.*);
    always #5 clk = ~clk;
    function automatic logic [7:0] byte_value(input xlen_t addr);
        return 8'(addr ^ (addr >> 5) ^ xlen_t'(8'ha3));
    endfunction
    function automatic logic [63:0] pair_value(input xlen_t addr);
        logic [63:0] value;
        for (int b = 0; b < 8; b++) value[8*b +: 8] = byte_value(addr+xlen_t'(b));
        return value;
    endfunction
    assign mem_req_ready = !rst && (!mem_rsp_valid || mem_rsp_ready) && cycles%4 != 2;
    assign rd_cmd_ready = !rst && (!rd_valid || rd_ready) && cycles%5 != 2;
    always_ff @(posedge clk) begin
        if (rst) begin mem_rsp_valid <= 0; rd_valid <= 0; end
        else begin
            if (mem_rsp_ready) mem_rsp_valid <= 0;
            if (rd_ready) rd_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                mem_rsp_valid <= 1;
                mem_response.error <= mem_request.addr == fault_word ? BUS_SLVERR : BUS_OK;
                for (int b = 0; b < DBUS_BYTES; b++)
                    mem_response.rdata[8*b +: 8] <= byte_value((mem_request.addr & ~xlen_t'(int'(DBUS_BYTES)-1))+xlen_t'(b));
            end
            if (rd_cmd_valid && rd_cmd_ready) begin
                assert (rd_cmd.len == 0 && rd_cmd.size == 5 && rd_cmd.execute) else $fatal(1,"IF block command");
                rd_valid <= 1; rd_data.last <= 1; rd_data.error <= block_fault ? BUS_SLVERR : BUS_OK;
                for (int b = 0; b < DDR_BEAT_BYTES; b++) rd_data.data[8*b +: 8] <= byte_value(rd_cmd.addr+xlen_t'(b));
            end
        end
    end
    always @(posedge clk) if (!rst) begin
        cycles <= cycles + 1;
        accepted = req_valid && req_ready;
        if (mem_req_valid && mem_req_ready || rd_cmd_valid && rd_cmd_ready) accesses++;
        if (dut.touch && !dut.install) hits++;
        streak = accepted ? streak+1 : 0;
        if (streak > max_streak) max_streak = streak;
        if (rsp_valid) begin
            assert (pending && rsp_error == expected_error) else $fatal(1,"IF response ownership/error block=%0d got=%b want=%b",BLOCK,rsp_error,expected_error);
            for (int w = 0; w < 2; w++) if (!expected_error[w])
                assert (rsp_data[32*w +: 32] == expected_data[32*w +: 32])
                    else $fatal(1,"IF64 data block=%0d got=%h want=%h",BLOCK,rsp_data,expected_data);
            if (rsp_ready) begin pending = 0; replies++; end
        end
        if (accepted) begin
            assert (!pending) else $fatal(1,"IF overwritten response");
            pending = 1; requests++;
            expected_data = pair_value(req_addr);
            expected_error = {req_addr+xlen_t'(4) == fault_word, req_addr == fault_word};
        end
        assert (cycles < 5000) else $fatal(1,"IF timeout");
    end
    task automatic send(input xlen_t addr);
        req_valid = 1; req_addr = addr;
        do begin @(posedge clk); #1; @(negedge clk); end while (!accepted);
        req_valid = 0;
    endtask
    task automatic drain;
        while (pending) @(negedge clk);
        @(negedge clk);
    endtask
    initial begin
        done = 0; req_addr = 0; mem_response = '0; rd_data = '0;
        repeat (3) @(negedge clk); rst = 0;
        send(xlen_t'(32'h80000000)); drain();
        // 同一行的四对指令全部已装入，接纳与返回连续 80 拍。
        for (int i = 0; i < 80; i++) begin
            req_valid = 1; req_addr = xlen_t'(32'h80000000) + xlen_t'((i%4)*8);
            @(posedge clk); #1; assert (accepted) else $fatal(1,"I-cache hit II != 1");
            @(negedge clk);
        end
        req_valid = 0; drain();
        rsp_ready = 0; send(xlen_t'(32'h80000010));
        wait (rsp_valid); repeat (5) @(negedge clk); rsp_ready = 1; drain();
        // 已接受 miss 遇失效仍排空并回复，填行不能重新安装失效的 tag。
        send(xlen_t'(32'h80000040));
        wait (dut.u_refill.start_valid); @(negedge clk); invalidate = 1;
        @(negedge clk); invalidate = 0; drain();
        begin
            int before_accesses;
            before_accesses = accesses;
            send(xlen_t'(32'h80000040)); drain();
            assert (accesses > before_accesses) else $fatal(1,"invalidated fill installed");
        end
        // ROM 旁路与 DDR 填行失败都按 word 返回故障；高 word 错误不能污染低 word。
        fault_word = 20; send(16); drain();
        fault_word = xlen_t'(32'h8000008c); block_fault = 1;
        send(xlen_t'(32'h80000088)); drain();
        fault_word = '1; block_fault = 0; send(xlen_t'(32'h80000088)); drain();
        assert (requests == replies && !pending && max_streak >= 80 && hits >= 80) else $fatal(1,"IF coverage");
        $display("ICACHE block=%0d requests=%0d hits=%0d accesses=%0d streak=%0d",BLOCK,requests,hits,accesses,max_streak);
        done = 1;
    end
endmodule
module tb_scoreboard_icache;
    timeunit 1ns;
    timeprecision 1ps;
    logic [1:0] done;
    for (genvar b = 0; b < 2; b++) begin : g_mode
        tb_scoreboard_icache_case #(.BLOCK(b != 0)) u_case (.done(done[b]));
    end
    initial begin
        wait (&done);
        $display("PASS tb_scoreboard_icache XLEN=%0d modes=2 native64 hit_II=1 invalidate errors backpressure",core_config_pkg::XLEN);
        $finish;
    end
endmodule
