// Module: tb_dcache_turnover
// Description: Checks bank ownership, held responses, maintenance, and optional cached response/request turnover.
module tb_dcache_turnover_case #(parameter bit BLOCK = 0, parameter int CACHE_BYTES = 256) (output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import cache_pkg::*;

    logic clk = 0, rst = 1;
    logic [1:0] req_valid = 0, req_ready, rsp_valid, rsp_ready = 3;
    logic [1:0] accepted = 0, completed = 0, pending = 0, stalled_q = 0;
    bus_req_t request [2];
    bus_rsp_t response [2], expected [2], saved_response [2], held_q [2];
    logic maint_req_valid = 0, maint_req_ready, maint_rsp_valid, maint_rsp_ready = 0;
    cache_maint_op_e maint_op = CACHE_NONE;
    cache_maint_error_e maint_error, fault_code;
    xlen_t maint_fault_addr, fault_addr;
    logic fault_valid;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    bus_req_t mem_request;
    bus_rsp_t mem_response;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid = 0, rd_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid = 0, wr_rsp_ready;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic writing = 0, force_scalar_stall = 0, force_scalar_ready = 0;
    xlen_t write_addr, bad_read_line = '1, bad_write_line = '1;
    logic [7:0] ram [8192];
    int cycles = 0, requests [2], replies [2], accesses = 0, scalar_accesses = 0;
    int maint_replies = 0, groups = 0, expect_turnover = 0, expect_block = -1;
    int stream_last_owner, stream_last_cycle, stream_accepts, stream_max_gap;
    bit stream_check = 0, bypass_turnover_seen = 0, bypass_pair_turnover_seen = 0;

    localparam int OTHER_BANK_ADDR = CACHE_BYTES/4;
    localparam int SAME_BANK_ADDR = 32 + ((`SOC_DCACHE_BANK_XOR_MASK & 1) ? OTHER_BANK_ADDR : 0);
    dcache_banked #(.DDR_BYTES(8192), .CACHE_BYTES(CACHE_BYTES), .BLOCK_ENABLE(BLOCK)) dut (.*);
    always #5 clk = ~clk;

    function automatic xlen_t ram_word(input int address);
        xlen_t data;
        for (int b = 0; b < DBUS_BYTES; b++) data[8*b +: 8] = ram[address+b];
        return data;
    endfunction
    function automatic bus_req_t load(input int offset);
        return '{addr:xlen_t'(soc_addr_pkg::DDR_BASE)+xlen_t'(offset), write:1'b0,
                 execute:1'b0, size:mem_size_e'($clog2(DBUS_BYTES)), wdata:'0, wstrb:'0};
    endfunction
    function automatic bus_req_t store(input int offset, input xlen_t value, input logic [DBUS_BYTES-1:0] mask);
        bus_req_t item;
        item = load(offset);
        item.write = 1;
        item.wdata = value;
        item.wstrb = mask;
        return item;
    endfunction

    // 下游响应保持到握手；读写反压具有固定周期，不依赖上游响应 ready。
    assign mem_req_ready = !rst && !force_scalar_stall && (!mem_rsp_valid || mem_rsp_ready) &&
                           (force_scalar_ready || cycles%4 != 2);
    assign rd_cmd_ready = !rst && (!rd_valid || rd_ready) && cycles%5 != 2;
    assign wr_cmd_ready = !rst && !writing && !wr_rsp_valid && cycles%3 != 1;
    assign wr_ready = writing && cycles%4 != 3;
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rsp_valid <= 0;
            rd_valid <= 0;
            writing <= 0;
            wr_rsp_valid <= 0;
        end else begin
            if (mem_rsp_ready) mem_rsp_valid <= 0;
            if (rd_ready) rd_valid <= 0;
            if (wr_rsp_ready) wr_rsp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                mem_rsp_valid <= 1;
                mem_response.error <= ((mem_request.addr & ~xlen_t'(31)) ==
                    (mem_request.write ? bad_write_line : bad_read_line)) ? BUS_SLVERR : BUS_OK;
                mem_response.rdata <= ram_word(int'(mem_request.addr & xlen_t'(8192-DBUS_BYTES)));
                if (mem_request.write && (mem_request.addr & ~xlen_t'(31)) != bad_write_line)
                    for (int b = 0; b < DBUS_BYTES; b++)
                        if (mem_request.wstrb[b])
                            ram[int'(mem_request.addr & xlen_t'(8192-DBUS_BYTES))+b] <= mem_request.wdata[8*b +: 8];
            end
            if (rd_cmd_valid && rd_cmd_ready) begin
                assert (rd_cmd.len == 0 && rd_cmd.size == 5 && !rd_cmd.execute)
                    else $fatal(1,"turnover block read framing");
                rd_valid <= 1;
                rd_data.last <= 1;
                rd_data.error <= rd_cmd.addr == bad_read_line ? BUS_SLVERR : BUS_OK;
                for (int b = 0; b < DDR_BEAT_BYTES; b++)
                    rd_data.data[8*b +: 8] <= ram[int'(rd_cmd.addr & xlen_t'(8191))+b];
            end
            if (wr_cmd_valid && wr_cmd_ready) begin
                assert (wr_cmd.len == 0 && wr_cmd.size == 5) else $fatal(1,"turnover block write framing");
                writing <= 1;
                write_addr <= wr_cmd.addr;
            end
            if (wr_valid && wr_ready) begin
                assert (wr_data.last) else $fatal(1,"turnover block write last");
                writing <= 0;
                wr_rsp_valid <= 1;
                wr_rsp.error <= write_addr == bad_write_line ? BUS_SLVERR : BUS_OK;
                if (write_addr != bad_write_line)
                    for (int b = 0; b < DDR_BEAT_BYTES; b++)
                        if (wr_data.strb[b]) ram[int'(write_addr & xlen_t'(8191))+b] <= wr_data.data[8*b +: 8];
            end
        end
    end

    // 先消费旧 owner 的响应，再记录同沿新请求；稳定性检查覆盖整个反压区间。
    always @(posedge clk) if (!rst) begin
        cycles = cycles + 1;
        accepted = req_valid & req_ready;
        completed = rsp_valid & rsp_ready;
        if (mem_req_valid && mem_req_ready) begin accesses++; scalar_accesses++; end
        if (rd_cmd_valid && rd_cmd_ready) accesses++;
        if (maint_rsp_valid && maint_rsp_ready) maint_replies++;
        for (int p = 0; p < 2; p++) begin
            if (stalled_q[p])
                assert (rsp_valid[p] && response[p] == held_q[p])
                    else $fatal(1,"held response changed block=%0d port=%0d",BLOCK,p);
            stalled_q[p] = rsp_valid[p] && !rsp_ready[p];
            held_q[p] = response[p];
            if (completed[p]) begin
                assert (pending[p]) else $fatal(1,"response without owner port=%0d",p);
                assert (response[p].error == expected[p].error &&
                        (expected[p].error != BUS_OK || response[p].rdata == expected[p].rdata))
                    else $fatal(1,"response mismatch block=%0d port=%0d got=%h want=%h",BLOCK,p,response[p],expected[p]);
                pending[p] = 0;
                replies[p]++;
                saved_response[p] = response[p];
            end
            if (accepted[p]) begin
                assert (!pending[p]) else $fatal(1,"accepted before prior response port=%0d",p);
                pending[p] = 1;
                requests[p]++;
                if (stream_check) begin
                    if (stream_accepts != 0) begin
                        assert (p != stream_last_owner) else $fatal(1,"same-bank round-robin starvation");
                        assert (cycles-stream_last_cycle <= 3) else $fatal(1,"continuous hit extra bubble");
                        if (cycles-stream_last_cycle > stream_max_gap) stream_max_gap = cycles-stream_last_cycle;
                    end
                    stream_last_owner = p;
                    stream_last_cycle = cycles;
                    stream_accepts++;
                end
            end
        end
        assert (cycles < 20000) else $fatal(1,"turnover semantic timeout block=%0d",BLOCK);
    end

    task automatic tick;
        @(posedge clk);
        #1;
        @(negedge clk);
    endtask
    task automatic drain;
        while (|pending) tick();
    endtask
    task automatic transact(input int port, input bus_req_t item, input xlen_t data,
                            input bus_error_e error = BUS_OK);
        request[port] = item;
        expected[port] = '{rdata:data,error:error};
        req_valid[port] = 1;
        do tick(); while (!accepted[port]);
        req_valid[port] = 0;
        drain();
    endtask
    task automatic warm;
        transact(0,load(0),ram_word(0));
        transact(1,load(SAME_BANK_ADDR),ram_word(SAME_BANK_ADDR));
        transact(0,load(OTHER_BANK_ADDR),ram_word(OTHER_BANK_ADDR));
    endtask
    task automatic queued_store_load(input bus_req_t item, input xlen_t data);
        request[0] = item;
        expected[0] = '{rdata:'0,error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        request[1] = load(0);
        expected[1] = '{rdata:data,error:BUS_OK};
        req_valid[1] = 1;
        while (!rsp_valid[0]) begin
            tick();
            assert (!accepted[1]) else $fatal(1,"load overtook uncompleted store");
        end
        repeat (3) begin tick(); assert (!accepted[1]) else $fatal(1,"load overwrote held store response"); end
        rsp_ready = 3;
        do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        drain();
    endtask
    task automatic maintain(input cache_maint_op_e operation, input cache_maint_error_e error);
        cache_maint_error_e held_error;
        xlen_t held_addr;
        maint_op = operation;
        maint_req_valid = 1;
        do tick(); while (!dut.maintenance_q);
        maint_req_valid = 0;
        while (!maint_rsp_valid) tick();
        assert (maint_error == error) else $fatal(1,"maintenance error got=%0d want=%0d",maint_error,error);
        held_error = maint_error;
        held_addr = maint_fault_addr;
        repeat (3) begin
            tick();
            assert (maint_rsp_valid && maint_error == held_error && maint_fault_addr == held_addr)
                else $fatal(1,"held maintenance payload changed");
        end
        maint_rsp_ready = 1;
        tick();
        maint_rsp_ready = 0;
        tick();
    endtask

    task automatic continuous_hits;
        int before_accesses;
        before_accesses = accesses;
        stream_last_owner = 0;
        stream_last_cycle = 0;
        stream_accepts = 0;
        stream_max_gap = 0;
        request[0] = load(0);
        request[1] = load(SAME_BANK_ADDR);
        expected[0] = '{rdata:ram_word(0),error:BUS_OK};
        expected[1] = '{rdata:ram_word(SAME_BANK_ADDR),error:BUS_OK};
        req_valid = 3;
        stream_check = 1;
        while (stream_accepts < 16) tick();
        // 另一端口的展示请求也完成后停止，避免撤回未握手的 valid。
        req_valid[stream_last_owner] = 0;
        while (|req_valid) begin tick(); req_valid &= ~accepted; end
        stream_check = 0;
        drain();
        assert (accesses == before_accesses) else $fatal(1,"warm stream missed cache");
        $display("TURNOVER_STREAM block=%0d accepted=%0d max_hit_accept_gap=%0d",BLOCK,stream_accepts,stream_max_gap);
        groups++;
    endtask

    task automatic cross_bank;
        int before_replies;
        request[0] = load(0);
        expected[0] = '{rdata:ram_word(0),error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        while (!rsp_valid[0]) tick();
        before_replies = replies[1];
        request[1] = load(OTHER_BANK_ADDR);
        expected[1] = '{rdata:ram_word(OTHER_BANK_ADDR),error:BUS_OK};
        req_valid[1] = 1;
        do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        while (pending[1]) tick();
        assert (rsp_valid[0] && pending[0] && replies[1] == before_replies+1)
            else $fatal(1,"one blocked bank prevented other-bank response");
        repeat (4) tick();
        rsp_ready = 3;
        drain();
        groups++;
    endtask

    task automatic pending_invalidate;
        int before_accesses;
        request[0] = load(0);
        expected[0] = '{rdata:ram_word(0),error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        while (!rsp_valid[0]) tick();
        request[1] = load(SAME_BANK_ADDR);
        expected[1] = '{rdata:ram_word(SAME_BANK_ADDR),error:BUS_OK};
        req_valid[1] = 1;
        maint_op = CACHE_INVALIDATE;
        maint_req_valid = 1;
        tick();
        assert (dut.maintenance_q && !accepted[1]) else $fatal(1,"pending invalidate lost arbitration");
        maint_req_valid = 0;
        repeat (3) begin tick(); assert (!accepted[1]) else $fatal(1,"request bypassed pending invalidate"); end
        before_accesses = accesses;
        rsp_ready = 3;
        while (!maint_rsp_valid) begin tick(); assert (!accepted[1]) else $fatal(1,"request bypassed active invalidate"); end
        assert (maint_error == CACHE_OK) else $fatal(1,"clean invalidate failed");
        repeat (3) begin
            tick();
            assert (maint_rsp_valid && maint_error == CACHE_OK && !accepted[1])
                else $fatal(1,"held maintenance admitted request");
        end
        maint_rsp_ready = 1;
        tick();
        assert (!accepted[1]) else $fatal(1,"request admitted before maintenance response consumed");
        maint_rsp_ready = 0;
        do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        drain();
        assert (accesses > before_accesses) else $fatal(1,"invalidated line did not refill");
        groups++;
    endtask

    // cached→bypass 不能在旧缓存响应沿宣称已接受，旧 refill 仍拥有下游选择。
    task automatic cached_to_bypass;
        int before_scalar;
        transact(0,load(0),ram_word(0));
        request[0] = load(0);
        expected[0] = '{rdata:ram_word(0),error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        while (!rsp_valid[0]) tick();
        request[1] = load(0);
        request[1].addr = xlen_t'(soc_addr_pkg::DTCM_BASE);
        expected[1] = '{rdata:ram_word(0),error:BUS_OK};
        req_valid[1] = 1;
        repeat (3) begin tick(); assert (!accepted[1]) else $fatal(1,"bypass accepted while cached response held"); end
        before_scalar = scalar_accesses;
        force_scalar_stall = 1;
        rsp_ready = 3;
        tick();
        assert (completed[0] && !accepted[1]) else $fatal(1,"cached-to-bypass premature acceptance");
        // 旁路展示项先被锁定；后到缓存命中不能替换它，也不能抢先完成。
        tick();
        request[0] = load(0);
        req_valid[0] = 1;
        repeat (4) begin
            tick();
            assert (accepted == 0 && mem_req_valid && mem_request == request[1])
                else $fatal(1,"held bypass offer changed under cached competitor");
        end
        force_scalar_stall = 0;
        rsp_ready = 1;
        do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        while (!rsp_valid[1]) begin
            tick();
            assert (!accepted[0]) else $fatal(1,"cached request overtook bypass response");
        end
        repeat (3) begin
            tick();
            assert (rsp_valid[1] && !accepted[0]) else $fatal(1,"cached request overwrote held bypass response");
        end
        rsp_ready = 3;
        tick();
        assert (completed[1]) else $fatal(1,"bypass response not consumed before ownership transfer");
        bypass_turnover_seen = accepted[0];
        $display("BYPASS_TURNOVER_PROBE block=%0d bypass_response_and_cached_request_same_edge=%0d",BLOCK,bypass_turnover_seen);
        if (!bypass_turnover_seen) do tick(); while (!accepted[0]);
        req_valid[0] = 0;
        drain();
        assert (scalar_accesses == before_scalar+1) else $fatal(1,"bypass request lost or repeated");
        maintain(CACHE_CLEAN,CACHE_OK);
        groups++;
    endtask

    task automatic buffered_bypass_turnover;
        int before_scalar;
        before_scalar = scalar_accesses;
        request[0] = load(DBUS_BYTES);
        request[0].addr = xlen_t'(soc_addr_pkg::DTCM_BASE)+xlen_t'(DBUS_BYTES);
        expected[0] = '{rdata:ram_word(DBUS_BYTES),error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        while (!rsp_valid[0]) tick();
        // 留足缓冲保存时间，下游标量 owner 已释放而 CPU 的旧响应仍未消费。
        repeat (3) tick();
        request[1] = load(2*DBUS_BYTES);
        request[1].addr = xlen_t'(soc_addr_pkg::DTCM_BASE)+xlen_t'(2*DBUS_BYTES);
        expected[1] = '{rdata:ram_word(2*DBUS_BYTES),error:BUS_OK};
        req_valid[1] = 1;
        repeat (3) begin
            tick();
            assert (rsp_valid[0] && !accepted[1]) else $fatal(1,"new bypass overwrote buffered old response");
        end
        force_scalar_ready = 1;
        rsp_ready = 3;
        tick();
        assert (completed[0]) else $fatal(1,"buffered bypass old owner did not complete");
        bypass_pair_turnover_seen = accepted[1];
        $display("BYPASS_PAIR_PROBE block=%0d buffered_bypass_response_and_request_same_edge=%0d",BLOCK,bypass_pair_turnover_seen);
        if (!bypass_pair_turnover_seen) do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        drain();
        force_scalar_ready = 0;
        assert (scalar_accesses == before_scalar+2) else $fatal(1,"buffered bypass pair lost or repeated a request");
        maintain(CACHE_CLEAN,CACHE_OK);
        groups++;
    endtask

    task automatic bank_distribution;
        int start_cycle, before_accesses, offset;
        // 每种步长先填热两行，再测双口同时请求；输出同 bank 与跨 bank 的实际代价。
        for (int stride = 32; stride <= 4096; stride *= 2) begin
            transact(0,load(0),ram_word(0));
            transact(1,load(stride),ram_word(stride));
            start_cycle = cycles; before_accesses = accesses;
            for (int repeat_no = 0; repeat_no < 16; repeat_no++) begin
                request[0] = load(0); request[1] = load(stride);
                expected[0] = '{rdata:ram_word(0),error:BUS_OK};
                expected[1] = '{rdata:ram_word(stride),error:BUS_OK};
                req_valid = 3;
                do begin tick(); req_valid &= ~accepted; end while (|req_valid);
                drain();
            end
            assert (accesses == before_accesses) else $fatal(1,"warm stride caused unexpected refill");
            $display("BANK_STRIDE block=%0d capacity=%0d mask=%0d stride=%0d same_bank=%0d cycles=%0d pairs=16",
                BLOCK,CACHE_BYTES,dut.BANK_XOR_MASK,stride,dut.bank_of(xlen_t'(0))==dut.bank_of(xlen_t'(stride)),cycles-start_cycle);
        end
        // 带非零行索引的部分写跨两个 bank；flush 后核对真实 RAM 地址和字节。
        for (int n = 1; n <= 4; n++) begin
            offset = 32*n;
            transact(0,store(offset,xlen_t'(8'hc0+n),DBUS_BYTES'(1)),0);
        end
        maintain(CACHE_FLUSH,CACHE_OK);
        for (int n = 1; n <= 4; n++) begin
            assert (ram[32*n] == 8'(8'hc0+n)) else $fatal(1,"bank hash writeback address/byte mismatch");
            transact(1,load(32*n),ram_word(32*n));
        end
    endtask

    task automatic cached_turnover_probe;
        bit same_edge;
        warm();
        request[0] = load(0);
        expected[0] = '{rdata:ram_word(0),error:BUS_OK};
        req_valid = 1;
        rsp_ready = 2;
        do tick(); while (!accepted[0]);
        req_valid = 0;
        while (!rsp_valid[0]) tick();
        request[1] = load(SAME_BANK_ADDR);
        expected[1] = '{rdata:ram_word(SAME_BANK_ADDR),error:BUS_OK};
        req_valid[1] = 1;
        repeat (4) begin
            tick();
            assert (!accepted[1] && rsp_valid[0]) else $fatal(1,"cached offer overwrote stalled response");
        end
        rsp_ready = 3;
        tick();
        assert (completed[0]) else $fatal(1,"turnover old response not consumed");
        same_edge = accepted[1];
        $display("TURNOVER_PROBE block=%0d cached_response_and_request_same_edge=%0d expected=%0d",BLOCK,same_edge,expect_turnover);
        if (expect_turnover != 0 && (expect_block == -1 || expect_block == int'(BLOCK))) begin
            assert (same_edge) else $fatal(1,"TURNOVER_EXPECTATION_FAILED: cached response consumed without next cached request block=%0d",BLOCK);
            assert (stream_max_gap == 2)
                else $fatal(1,"TURNOVER_THROUGHPUT_FAILED: continuous cached hit gap=%0d block=%0d",stream_max_gap,BLOCK);
            assert (bypass_turnover_seen)
                else $fatal(1,"BYPASS_TURNOVER_FAILED: bypass response did not transfer to next cached request block=%0d",BLOCK);
            assert (bypass_pair_turnover_seen)
                else $fatal(1,"BYPASS_PAIR_TURNOVER_FAILED: buffered bypass response did not transfer to next bypass request block=%0d",BLOCK);
        end
        if (!same_edge) do tick(); while (!accepted[1]);
        req_valid[1] = 0;
        drain();
        groups++;
    endtask

    initial begin
        xlen_t original, changed, value;
        logic [DBUS_BYTES-1:0] mask;
        done = 0;
        void'($value$plusargs("EXPECT_TURNOVER=%d",expect_turnover));
        void'($value$plusargs("EXPECT_BLOCK=%d",expect_block));
        assert (expect_turnover == 0 || expect_turnover == 1) else $fatal(1,"EXPECT_TURNOVER must be 0 or 1");
        assert (expect_block >= -1 && expect_block <= 1) else $fatal(1,"EXPECT_BLOCK must be -1, 0 or 1");
        request[0] = '0; request[1] = '0;
        expected[0] = '0; expected[1] = '0;
        mem_response = '0; rd_data = '0; wr_rsp = '0;
        for (int i = 0; i < 8192; i++) ram[i] = 8'(i ^ (i>>4) ^ 8'h5a);
        repeat (3) @(negedge clk);
        rst = 0;
        warm();
        continuous_hits();
        cross_bank();
        pending_invalidate();

        original = ram_word(0);
        value = xlen_t'(64'h76543210fedcba98);
        mask = '0;
        changed = original;
        for (int b = 0; b < DBUS_BYTES; b++)
            if (b%2 == 0) begin mask[b] = 1; changed[8*b +: 8] = value[8*b +: 8]; end
        queued_store_load(store(0,value,mask),changed);
        transact(0,store(0,'1,'0),0);
        transact(1,load(0),changed);
        assert (ram_word(0) == original) else $fatal(1,"masked writeback store escaped early");
        maintain(CACHE_INVALIDATE,CACHE_DIRTY_ERROR);
        transact(1,load(0),changed);
        bad_write_line = xlen_t'(soc_addr_pkg::DDR_BASE);
        maintain(CACHE_FLUSH,CACHE_WRITEBACK_ERROR);
        transact(0,load(0),changed);
        assert (ram_word(0) == original) else $fatal(1,"failed writeback altered RAM");
        bad_write_line = '1;
        maintain(CACHE_FLUSH,CACHE_OK);
        assert (ram_word(0) == changed) else $fatal(1,"masked writeback bytes mismatch");
        transact(1,load(0),changed);
        groups++;

        bad_read_line = xlen_t'(soc_addr_pkg::DDR_BASE)+xlen_t'(512);
        transact(0,load(512),0,BUS_SLVERR);
        bad_read_line = '1;
        transact(1,load(512),ram_word(512));
        transact(0,load(0),ram_word(0));
        groups++;
        cached_to_bypass();
        buffered_bypass_turnover();
        $display("TURNOVER_SEMANTICS block=%0d groups=%0d requests=%0d responses=%0d maintenance=%0d",
                 BLOCK,groups,requests[0]+requests[1],replies[0]+replies[1],maint_replies);
        cached_turnover_probe();
        assert (requests[0] == replies[0] && requests[1] == replies[1] && maint_replies == 6 && groups == 8)
            else $fatal(1,"turnover coverage/accounting incomplete");
        $display("PASS tb_dcache_turnover_case XLEN=%0d block=%0d groups=%0d requests=%0d responses=%0d expect_turnover=%0d",
                 XLEN,BLOCK,groups,requests[0]+requests[1],replies[0]+replies[1],expect_turnover);
        bank_distribution();
        done = 1;
    end
endmodule

module tb_dcache_turnover #(parameter int CACHE_BYTES = 256);
    timeunit 1ns;
    timeprecision 1ps;
    logic [1:0] done;
    for (genvar b = 0; b < 2; b++) begin : g_mode
        tb_dcache_turnover_case #(.BLOCK(b != 0), .CACHE_BYTES(CACHE_BYTES)) u_case (.done(done[b]));
    end
    initial begin
        wait (&done);
        $display("PASS tb_dcache_turnover XLEN=%0d configurations=2 SKIP=0",core_config_pkg::XLEN);
        $finish;
    end
endmodule
