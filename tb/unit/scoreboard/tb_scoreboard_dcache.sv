// Module: tb_scoreboard_dcache
// Description: Checks disjoint line banks, dual hits, owner backpressure and joint dirty-cache maintenance.
module tb_scoreboard_dcache_case #(parameter bit BLOCK = 0) (output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import cache_pkg::*;
    logic clk = 0, rst = 1;
    logic [1:0] req_valid = 0, req_ready, rsp_valid, rsp_ready = 3, accepted, pending = 0;
    bus_req_t request [2];
    bus_rsp_t response [2], saved_response [2];
    logic maint_req_valid = 0, maint_req_ready, maint_rsp_valid, maint_rsp_ready = 0, fault_valid;
    cache_maint_op_e maint_op = CACHE_NONE;
    cache_maint_error_e maint_error, fault_code;
    xlen_t maint_fault_addr, fault_addr;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    bus_req_t mem_request;
    bus_rsp_t mem_response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid = 0, rd_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid = 0, wr_rsp_ready, writing = 0;
    block_w_t wr_data;
    block_b_t wr_rsp;
    xlen_t write_addr, bad_write_line = '1;
    logic [7:0] ram [8192];
    int cycles, requests [2], replies [2], dual_requests, dual_replies, accesses, maint_replies;
    dcache_banked #(.DDR_BYTES(8192), .CACHE_BYTES(256), .BLOCK_ENABLE(BLOCK)) dut (.*);
    always #5 clk = ~clk;
    function automatic xlen_t ram_word(input int address);
        xlen_t data;
        for (int b = 0; b < DBUS_BYTES; b++) data[8*b +: 8] = ram[address+b];
        return data;
    endfunction
    function automatic bus_req_t load(input int offset);
        return '{addr:xlen_t'(32'h80000000)+xlen_t'(offset), write:1'b0, execute:1'b0,
                 size:mem_size_e'($clog2(DBUS_BYTES)), wdata:'0, wstrb:'0};
    endfunction
    function automatic bus_req_t store(input int offset, input xlen_t value);
        bus_req_t item;
        item = load(offset); item.write = 1; item.wdata = value; item.wstrb = '1;
        return item;
    endfunction
    assign mem_req_ready = !rst && (!mem_rsp_valid || mem_rsp_ready) && cycles%4 != 2;
    assign rd_cmd_ready = !rst && (!rd_valid || rd_ready) && cycles%5 != 2;
    assign wr_cmd_ready = !rst && !writing && !wr_rsp_valid && cycles%3 != 1;
    assign wr_ready = writing && cycles%4 != 3;
    always_ff @(posedge clk) begin
        if (rst) begin mem_rsp_valid <= 0; rd_valid <= 0; writing <= 0; wr_rsp_valid <= 0; end
        else begin
            if (mem_rsp_ready) mem_rsp_valid <= 0;
            if (rd_ready) rd_valid <= 0;
            if (wr_rsp_ready) wr_rsp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                mem_rsp_valid <= 1;
                mem_response.error <= mem_request.write && (mem_request.addr & ~xlen_t'(31)) == bad_write_line ? BUS_SLVERR : BUS_OK;
                mem_response.rdata <= ram_word(int'(mem_request.addr & xlen_t'(8192-DBUS_BYTES)));
                if (mem_request.write && (mem_request.addr & ~xlen_t'(31)) != bad_write_line)
                    for (int b = 0; b < DBUS_BYTES; b++) if (mem_request.wstrb[b])
                        ram[int'(mem_request.addr & xlen_t'(8192-DBUS_BYTES))+b] <= mem_request.wdata[8*b +: 8];
            end
            if (rd_cmd_valid && rd_cmd_ready) begin
                assert (rd_cmd.len == 0 && rd_cmd.size == 5 && !rd_cmd.execute) else $fatal(1,"D read block");
                rd_valid <= 1; rd_data.last <= 1; rd_data.error <= BUS_OK;
                for (int b = 0; b < DDR_BEAT_BYTES; b++) rd_data.data[8*b +: 8] <= ram[int'(rd_cmd.addr & xlen_t'(8191))+b];
            end
            if (wr_cmd_valid && wr_cmd_ready) begin
                assert (wr_cmd.len == 0 && wr_cmd.size == 5) else $fatal(1,"D write block");
                writing <= 1; write_addr <= wr_cmd.addr;
            end
            if (wr_valid && wr_ready) begin
                assert (wr_data.last) else $fatal(1,"D write block framing");
                writing <= 0; wr_rsp_valid <= 1; wr_rsp.error <= write_addr == bad_write_line ? BUS_SLVERR : BUS_OK;
                if (write_addr != bad_write_line)
                    for (int b = 0; b < DDR_BEAT_BYTES; b++) if (wr_data.strb[b])
                        ram[int'(write_addr & xlen_t'(8191))+b] <= wr_data.data[8*b +: 8];
            end
        end
    end
    always @(posedge clk) if (!rst) begin
        cycles <= cycles + 1;
        accepted = req_valid & req_ready;
        if (accepted == 3) dual_requests++;
        if ((rsp_valid & rsp_ready) == 3) dual_replies++;
        if (mem_req_valid && mem_req_ready || rd_cmd_valid && rd_cmd_ready) accesses++;
        if (maint_rsp_valid && maint_rsp_ready) maint_replies++;
        for (int p = 0; p < 2; p++) begin
            if (rsp_valid[p] && rsp_ready[p]) begin
                assert (pending[p]) else $fatal(1,"D response owner");
                pending[p] = 0; replies[p]++; saved_response[p] = response[p];
            end
            if (accepted[p]) begin
                assert (!pending[p]) else $fatal(1,"D response overwritten");
                pending[p] = 1; requests[p]++;
            end
        end
        assert (cycles < 10000) else $fatal(1,"D timeout");
    end
    task automatic pair(input bus_req_t a, b, input bit hold = 0);
        request[0] = a; request[1] = b; req_valid = 3; rsp_ready = hold ? 0 : 3;
        while (|req_valid) begin @(posedge clk); #1; @(negedge clk); req_valid &= ~accepted; end
        if (hold) begin
            bus_rsp_t held [2];
            wait (&rsp_valid); @(negedge clk); held[0] = response[0]; held[1] = response[1];
            repeat (4) begin
                @(negedge clk);
                assert (rsp_valid == 3 && response[0] == held[0] && response[1] == held[1]) else $fatal(1,"D held owner");
            end
            rsp_ready = 3;
        end
        while (|pending) @(negedge clk);
        @(negedge clk);
        assert (saved_response[0].error == BUS_OK && saved_response[1].error == BUS_OK) else $fatal(1,"D access failed");
    endtask
    task automatic maintain(input cache_maint_op_e operation, input cache_maint_error_e error);
        maint_op = operation; maint_req_valid = 1;
        do begin @(posedge clk); #1; @(negedge clk); end while (!dut.maintenance_q);
        maint_req_valid = 0;
        wait (maint_rsp_valid); @(negedge clk);
        assert (maint_error == error && dut.maint_done_q == 3) else $fatal(1,"both banks maintenance completion");
        repeat (3) begin
            @(negedge clk); assert (maint_rsp_valid && maint_error == error) else $fatal(1,"held maintenance result");
        end
        maint_rsp_ready = 1; @(negedge clk); maint_rsp_ready = 0;
        repeat (2) @(negedge clk);
    endtask
    initial begin
        xlen_t original0, original64, value0, value64;
        done = 0; request[0] = '0; request[1] = '0; mem_response = '0; rd_data = '0; wr_rsp = '0;
        for (int i = 0; i < 8192; i++) ram[i] = 8'(i ^ (i>>4) ^ 8'h5a);
        original0 = ram_word(0); original64 = ram_word(64);
        value0 = xlen_t'(64'h12345678deadbeef); value64 = xlen_t'(64'h76543210fedc9876);
        repeat (3) @(negedge clk); rst = 0;
        pair(load(0),load(64));
        assert (saved_response[0].rdata == original0 && saved_response[1].rdata == original64) else $fatal(1,"D fills");
        begin
            int before_accesses;
            before_accesses = accesses; pair(load(64),load(0),1);
            assert (saved_response[0].rdata == original64 && saved_response[1].rdata == original0 &&
                    accesses == before_accesses) else $fatal(1,"D dual hit routed to memory");
        end
        // 同 bank 两客户端也应按 owner 返回，不能把同一行复制成两个可独立修改的副本。
        pair(load(0),load(0));
        pair(store(0,value0),load(64));
        assert (ram_word(0) == original0) else $fatal(1,"write-back Store escaped before clean");
        pair(store(64,value64),load(0));
        assert (saved_response[1].rdata == value0) else $fatal(1,"dirty line ownership");
        maintain(CACHE_INVALIDATE,CACHE_DIRTY_ERROR);
        bad_write_line = xlen_t'(32'h80000040);
        maintain(CACHE_FLUSH,CACHE_WRITEBACK_ERROR);
        assert (ram_word(0) == value0 && ram_word(64) == original64) else $fatal(1,"writeback error/other bank");
        bad_write_line = '1; maintain(CACHE_FLUSH,CACHE_OK);
        assert (ram_word(0) == value0 && ram_word(64) == value64) else $fatal(1,"joint flush data");
        pair(load(0),load(64));
        assert (saved_response[0].rdata == value0 && saved_response[1].rdata == value64) else $fatal(1,"refill after flush");
        assert (dual_requests >= 4 && dual_replies >= 1 && maint_replies == 3 &&
                requests[0] == replies[0] && requests[1] == replies[1]) else $fatal(1,"D coverage");
        $display("DCACHE block=%0d dual_requests=%0d dual_replies=%0d accesses=%0d maintenance=%0d",
                 BLOCK,dual_requests,dual_replies,accesses,maint_replies);
        done = 1;
    end
endmodule
module tb_scoreboard_dcache;
    timeunit 1ns;
    timeprecision 1ps;
    logic [1:0] done;
    for (genvar b = 0; b < 2; b++) begin : g_mode
        tb_scoreboard_dcache_case #(.BLOCK(b != 0)) u_case (.done(done[b]));
    end
    initial begin
        wait (&done);
        $display("PASS tb_scoreboard_dcache XLEN=%0d modes=2 dual_hits same_bank dirty maintenance errors",core_config_pkg::XLEN);
        $finish;
    end
endmodule
