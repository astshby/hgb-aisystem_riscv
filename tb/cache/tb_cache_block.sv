// Module: tb_cache_block
// Description: Byte-reference cache integration checks for scalar and block fills, dirty recovery and maintenance.
module tb_cache_block #(
    parameter bit BLOCK_ENABLE = 1'b1,
    parameter bit INSTRUCTION = 1'b0,
    parameter int LINE_BYTES = 32
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import cache_pkg::*;
    localparam int MEMORY_BYTES = 4096, DDR_BYTES = MEMORY_BYTES-4;
    localparam xlen_t BASE = xlen_t'(soc_addr_pkg::DDR_BASE);
    logic clk = 0, rst = 1, invalidate = 0;
    always #5 clk = ~clk;
    logic req_valid = 0, req_ready, rsp_valid, rsp_ready = 0;
    bus_req_t request = '0, mem_request, scalar_saved;
    bus_rsp_t response, mem_response = '0;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid = 0, mem_rsp_ready;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid = 0, rd_ready;
    block_cmd_t rd_cmd, read_saved, wr_cmd, write_saved;
    block_r_t rd_data = '0;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid = 0, wr_rsp_ready;
    block_w_t wr_data;
    block_b_t wr_rsp = '0;
    logic maint_req_valid = 0, maint_req_ready, maint_rsp_valid, maint_rsp_ready = 0;
    cache_maint_op_e maint_op = CACHE_NONE;
    cache_maint_error_e maint_error, fault_code;
    xlen_t maint_fault_addr, fault_addr;
    logic fault_valid, fill_write;
    byte unsigned memory [MEMORY_BYTES], golden [MEMORY_BYTES];
    logic scalar_pending = 0, read_pending = 0, write_pending = 0, b_pending = 0;
    logic read_fail = 0, write_fail = 0, fallback_fail = 0, captured_write_fail;
    xlen_t fail_addr;
    int fail_beat = 0, cycles = 0, scalar_delay = 0, read_delay = 0, b_delay = 0;
    int read_beat = 0, write_beat = 0;
    int scalar_reads = 0, scalar_writes = 0, block_reads = 0, block_writes = 0;
    int read_responses = 0, write_responses = 0, checks = 0, held_cycles = 0;
    int write_held_cycles = 0;

    // 使用同一字节参考检查两种XLEN；缓存脏数据进入golden，但DDR仅在真实写握手后改变。
    function automatic xlen_t reference_word(input xlen_t addr, input bit physical);
        xlen_t result;
        int offset;
        result = '0;
        offset = int'((addr-BASE) & ~xlen_t'(DBUS_BYTES-1));
        for (int b = 0; b < DBUS_BYTES; b++)
            result[8*b +: 8] = physical ? memory[offset+b] : golden[offset+b];
        return result;
    endfunction

    if (INSTRUCTION) begin
        icache #(.CACHE_BYTES(4*LINE_BYTES), .LINE_BYTES(LINE_BYTES),
            .DDR_BYTES(DDR_BYTES), .BLOCK_ENABLE(BLOCK_ENABLE)) dut (
            .clk, .rst, .invalidate, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready,
            .response, .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid,
            .mem_rsp_ready, .mem_response, .rd_cmd_valid, .rd_cmd_ready, .rd_cmd,
            .rd_valid, .rd_ready, .rd_data
        );
        assign fill_write = dut.fill_write;
        assign wr_cmd_valid = 0;
        assign wr_cmd = '0;
        assign wr_valid = 0;
        assign wr_data = '0;
        assign wr_rsp_ready = 0;
        assign maint_req_ready = 0;
        assign maint_rsp_valid = 0;
        assign maint_error = CACHE_OK;
        assign maint_fault_addr = '0;
        assign fault_valid = 0;
        assign fault_code = CACHE_OK;
        assign fault_addr = '0;
    end else begin
        dcache #(.CACHE_BYTES(4*LINE_BYTES), .LINE_BYTES(LINE_BYTES),
            .DDR_BYTES(DDR_BYTES), .BLOCK_ENABLE(BLOCK_ENABLE)) dut (
            .clk, .rst, .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response,
            .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready,
            .mem_response, .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid,
            .maint_rsp_ready, .maint_error, .maint_fault_addr, .fault_valid, .fault_code, .fault_addr,
            .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
            .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
            .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
        );
        assign fill_write = dut.fill_write;
    end

    // 所有外部状态在上升沿NBA更新；请求ready与响应valid不会因TB active排序提前变化。
    assign mem_req_ready = !rst && !scalar_pending && !mem_rsp_valid && cycles % 3 != 0;
    assign rd_cmd_ready = !rst && !read_pending && !rd_valid && cycles % 3 == 0;
    assign wr_cmd_ready = !rst && !write_pending && !b_pending && !wr_rsp_valid && cycles % 4 == 0;
    assign wr_ready = !rst && write_pending && cycles % 3 != 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            scalar_pending <= 0; read_pending <= 0; write_pending <= 0; b_pending <= 0;
            mem_rsp_valid <= 0; rd_valid <= 0; wr_rsp_valid <= 0;
            scalar_reads <= 0; scalar_writes <= 0; block_reads <= 0; block_writes <= 0;
            read_responses <= 0; write_responses <= 0;
        end else begin
            cycles <= cycles + 1;
            if (mem_rsp_valid && mem_rsp_ready) mem_rsp_valid <= 0;
            if (mem_req_valid && mem_req_ready) begin
                scalar_saved <= mem_request;
                scalar_pending <= 1;
                scalar_delay <= 2;
                if (mem_request.write) scalar_writes <= scalar_writes + 1;
                else scalar_reads <= scalar_reads + 1;
            end
            if (scalar_pending) begin
                if (scalar_delay != 0) scalar_delay <= scalar_delay-1;
                else begin
                    scalar_pending <= 0;
                    mem_rsp_valid <= 1;
                    mem_response.rdata <= reference_word(scalar_saved.addr, 1'b1);
                    mem_response.error <= (scalar_saved.write ? write_fail :
                        (fallback_fail || (read_fail && scalar_saved.addr == fail_addr))) ? BUS_SLVERR : BUS_OK;
                    if (scalar_saved.write)
                        for (int b = 0; b < DBUS_BYTES; b++)
                            if (scalar_saved.wstrb[b] && (!write_fail || b % 2 == 0))
                                memory[int'((scalar_saved.addr-BASE)&~xlen_t'(DBUS_BYTES-1))+b] <=
                                    scalar_saved.wdata[8*b +: 8];
                end
            end

            if (rd_cmd_valid && rd_cmd_ready) begin
                assert (BLOCK_ENABLE && rd_cmd.addr % LINE_BYTES == 0 &&
                    rd_cmd.len == LINE_BYTES/DDR_BEAT_BYTES-1 && rd_cmd.size == 5 &&
                    rd_cmd.execute == INSTRUCTION) else $fatal(1, "Bad block read command");
                read_saved <= rd_cmd;
                read_pending <= 1; read_beat <= 0; read_delay <= 2;
                block_reads <= block_reads + 1;
            end
            if (rd_valid && rd_ready) begin
                rd_valid <= 0;
                read_responses <= read_responses + 1;
                if (rd_data.last) read_pending <= 0;
                else begin read_beat <= read_beat+1; read_delay <= 1; end
            end
            if (read_pending && !rd_valid) begin
                if (read_delay != 0) read_delay <= read_delay-1;
                else begin
                    rd_valid <= 1;
                    rd_data.last <= read_beat == int'(read_saved.len);
                    rd_data.error <= read_fail && read_beat == fail_beat ? BUS_SLVERR : BUS_OK;
                    for (int b = 0; b < DDR_BEAT_BYTES; b++)
                        rd_data.data[8*b +: 8] <= memory[int'(read_saved.addr-BASE)+read_beat*DDR_BEAT_BYTES+b];
                end
            end
            if (BLOCK_ENABLE && read_pending)
                assert (!fill_write) else $fatal(1, "RAM changed before entire block response drained");

            if (wr_cmd_valid && wr_cmd_ready) begin
                assert (!INSTRUCTION && BLOCK_ENABLE && wr_cmd.addr % LINE_BYTES == 0 &&
                    wr_cmd.len == LINE_BYTES/DDR_BEAT_BYTES-1 && wr_cmd.size == 5 && !wr_cmd.execute)
                    else $fatal(1, "Bad block write command");
                write_saved <= wr_cmd;
                captured_write_fail <= write_fail;
                write_pending <= 1; write_beat <= 0;
                block_writes <= block_writes + 1;
            end
            if (wr_valid && wr_ready) begin
                assert (write_pending && wr_data.last == (write_beat == int'(write_saved.len)) &&
                    wr_data.strb == '1) else $fatal(1, "Bad W framing/strobe");
                for (int b = 0; b < DDR_BEAT_BYTES; b++) begin
                    assert (wr_data.data[8*b +: 8] == golden[int'(write_saved.addr-BASE)+write_beat*DDR_BEAT_BYTES+b])
                        else $fatal(1, "Writeback differs from architectural byte beat=%0d byte=%0d", write_beat,b);
                    if (!captured_write_fail || b % 2 == 0)
                        memory[int'(write_saved.addr-BASE)+write_beat*DDR_BEAT_BYTES+b] <= wr_data.data[8*b +: 8];
                end
                if (wr_data.last) begin
                    write_pending <= 0; b_pending <= 1; b_delay <= 4;
                end else write_beat <= write_beat+1;
            end
            if (b_pending) begin
                if (b_delay != 0) b_delay <= b_delay-1;
                else begin
                    b_pending <= 0; wr_rsp_valid <= 1;
                    wr_rsp.error <= captured_write_fail ? BUS_SLVERR : BUS_OK;
                end
            end
            if (wr_rsp_valid && wr_rsp_ready) begin
                wr_rsp_valid <= 0;
                write_responses <= write_responses+1;
            end
            if (write_pending || b_pending)
                assert (!rsp_valid && !maint_rsp_valid) else $fatal(1, "Writeback acknowledged before B");
        end
    end

    // 独立跨拍快照检查持包，不能只与当前源比较而漏掉源和输出一起变化。
    logic rd_hold = 0, wc_hold = 0, w_hold = 0, scalar_hold = 0;
    block_cmd_t held_rd, held_wc;
    block_w_t held_w;
    bus_req_t held_scalar;
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_hold <= 0; wc_hold <= 0; w_hold <= 0; scalar_hold <= 0;
            held_cycles <= 0; write_held_cycles <= 0;
        end
        else begin
            if (rd_hold) assert (rd_cmd_valid && rd_cmd == held_rd) else $fatal(1, "Read cmd changed");
            if (wc_hold) assert (wr_cmd_valid && wr_cmd == held_wc) else $fatal(1, "Write cmd changed");
            if (w_hold) assert (wr_valid && wr_data == held_w) else $fatal(1, "W changed");
            if (scalar_hold) assert (mem_req_valid && mem_request == held_scalar) else $fatal(1, "Scalar changed");
            rd_hold <= rd_cmd_valid && !rd_cmd_ready; held_rd <= rd_cmd;
            wc_hold <= wr_cmd_valid && !wr_cmd_ready; held_wc <= wr_cmd;
            w_hold <= wr_valid && !wr_ready; held_w <= wr_data;
            scalar_hold <= mem_req_valid && !mem_req_ready; held_scalar <= mem_request;
            if (rd_hold || wc_hold || w_hold || scalar_hold) held_cycles <= held_cycles+1;
            if (w_hold) write_held_cycles <= write_held_cycles+1;
        end
    end

    task automatic access_line(input int offset, input bit store = 0,
        input xlen_t data = '0, input logic [DBUS_BYTES-1:0] mask = '0,
        input bus_error_e expected_error = BUS_OK, input bit kill_fill = 0);
        bus_rsp_t held;
        int timeout, lane;
        bit invalidated;
        @(negedge clk);
        request = '{write:store, execute:INSTRUCTION, size:MEM_WORD,
                    addr:BASE+xlen_t'(offset), wdata:data, wstrb:mask};
        req_valid = 1; timeout = 0; invalidated = 0;
        do begin @(posedge clk); timeout++; assert(timeout<3000) else $fatal(1,"request timeout"); end while (!req_ready);
        @(negedge clk); req_valid = 0;
        while (!rsp_valid) begin
            if (kill_fill && !invalidated && (rd_valid || mem_rsp_valid)) begin
                invalidate = 1; invalidated = 1;
            end else invalidate = 0;
            @(negedge clk);
            timeout++; assert(timeout<3000) else $fatal(1,"response timeout offset=%0d",offset);
        end
        invalidate = 0;
        assert (response.error == expected_error) else $fatal(1,"Error got=%0d expected=%0d",response.error,expected_error);
        if (kill_fill) assert (invalidated) else $fatal(1,"No invalidate during fill");
        if (store && expected_error == BUS_OK)
            for (int b=0; b<DBUS_BYTES; b++)
                if (mask[b]) golden[(offset & ~(DBUS_BYTES-1))+b] = data[8*b +: 8];
        if (!store && expected_error == BUS_OK) begin
            lane = INSTRUCTION ? (offset % DBUS_BYTES)*8 : 0;
            if (INSTRUCTION)
                assert (32'(response.rdata >> lane) == 32'(reference_word(request.addr,0) >> lane))
                    else $fatal(1,"I data/lane mismatch offset=%0d",offset);
            else assert (response.rdata == reference_word(request.addr,0))
                else $fatal(1,"D data mismatch offset=%0d got=%h expected=%h",offset,response.rdata,reference_word(request.addr,0));
        end
        held = response;
        repeat (3) begin @(negedge clk); assert(rsp_valid && response==held) else $fatal(1,"CPU response changed"); end
        rsp_ready = 1;
        @(negedge clk); rsp_ready = 0;
        assert (!rsp_valid) else $fatal(1,"Duplicate response");
        checks++;
    endtask

    task automatic maintain(input cache_maint_op_e op, input cache_maint_error_e expected_error);
        int timeout;
        @(negedge clk); maint_req_valid=1; maint_op=op; timeout=0;
        do begin @(posedge clk); timeout++; assert(timeout<3000) else $fatal(1,"maint request timeout"); end while(!maint_req_ready);
        @(negedge clk); maint_req_valid=0;
        while(!maint_rsp_valid) begin @(negedge clk); timeout++; assert(timeout<3000) else $fatal(1,"maint timeout"); end
        assert(maint_error==expected_error) else $fatal(1,"maintenance error got=%0d expected=%0d",maint_error,expected_error);
        if (expected_error==CACHE_WRITEBACK_ERROR && BLOCK_ENABLE)
            assert (maint_fault_addr % LINE_BYTES == 0) else $fatal(1,"B fault must report line base");
        repeat(2) @(negedge clk);
        maint_rsp_ready=1; @(negedge clk); maint_rsp_ready=0;
        checks++;
    endtask

    int before_count, before_scalar, before_blocks, before_responses;
    initial begin
        foreach(memory[i]) begin memory[i]=8'((i*13)^'ha6); golden[i]=memory[i]; end
        repeat(3) @(negedge clk); rst=0;
        access_line(4);
        before_count=scalar_reads+block_reads;
        access_line(LINE_BYTES-4);
        assert(scalar_reads+block_reads==before_count) else $fatal(1,"Expected cached hit");

        // 邻近beat故障只触发一次原地址回退；原需求失败也不能安装不完整行。
        read_fail=1; fail_addr=BASE+xlen_t'(2*LINE_BYTES);
        for (int bad_beat=0; bad_beat<(BLOCK_ENABLE ? LINE_BYTES/DDR_BEAT_BYTES : 1); bad_beat++) begin
            fail_beat=bad_beat;
            before_scalar=scalar_reads; before_blocks=block_reads; before_responses=read_responses;
            access_line(2*LINE_BYTES+4);
            assert (BLOCK_ENABLE ? block_reads==before_blocks+1 && scalar_reads==before_scalar+1 &&
                read_responses==before_responses+LINE_BYTES/DDR_BEAT_BYTES :
                scalar_reads==before_scalar+2) else $fatal(1,"Wrong fallback/drain count");
        end
        fallback_fail=1;
        access_line(2*LINE_BYTES+4,0,'0,'0,BUS_SLVERR);
        read_fail=0; fallback_fail=0;
        before_count=scalar_reads+block_reads;
        access_line(2*LINE_BYTES+4);
        assert(scalar_reads+block_reads>before_count) else $fatal(1,"Failed fill was installed");

        if (INSTRUCTION) begin
            before_count=scalar_reads+block_reads;
            access_line(4*LINE_BYTES+4,0,'0,'0,BUS_OK,1);
            access_line(4*LINE_BYTES+4);
            assert(scalar_reads+block_reads>=before_count+2) else $fatal(1,"Invalidated fill installed");
        end else begin
            // 先清空旧干净行，再构造两路同set逐出；B失败后脏数据必须仍可命中。
            maintain(CACHE_FLUSH,CACHE_OK);
            access_line(4,1,xlen_t'('h95c32ab7) << (8*(4%DBUS_BYTES)),
                (DBUS_BYTES'(4'b0101) << (4%DBUS_BYTES)));
            access_line(2*LINE_BYTES+4);
            write_fail=1;
            access_line(4*LINE_BYTES+4,0,'0,'0,BUS_SLVERR);
            before_count=scalar_reads+block_reads;
            access_line(4);
            assert(scalar_reads+block_reads==before_count) else $fatal(1,"Failed victim lost");
            write_fail=0;
            // 原脏行hit会改变LRU；维护重试同一脏行，独立比较完整发布的字节。
            maintain(CACHE_CLEAN,CACHE_OK);
            for(int b=0;b<LINE_BYTES;b++) assert(memory[b]==golden[b]) else $fatal(1,"Retry lost dirty bytes");
            access_line(4,1,xlen_t'('h4b7e31d2) << (8*(4%DBUS_BYTES)),
                DBUS_BYTES'(4'b1010) << (4%DBUS_BYTES));
            write_fail=1; maintain(CACHE_CLEAN,CACHE_WRITEBACK_ERROR);
            before_count=scalar_reads+block_reads; access_line(4);
            assert(scalar_reads+block_reads==before_count) else $fatal(1,"Maintenance failure lost dirty line");
            write_fail=0; maintain(CACHE_FLUSH,CACHE_OK);
            // 写分配失败后只转交原store，不能把整行读变成写；零strobe无外部副作用。
            read_fail=1; fail_addr=BASE+xlen_t'(6*LINE_BYTES);
            before_scalar=scalar_writes;
            access_line(6*LINE_BYTES+4,1,xlen_t'('h11223344) << (8*(4%DBUS_BYTES)),
                DBUS_BYTES'(4'b1111) << (4%DBUS_BYTES));
            assert(scalar_writes==before_scalar+1) else $fatal(1,"Store fallback not exactly once");
            read_fail=0;
            before_count=scalar_reads+block_reads+scalar_writes+block_writes;
            access_line(8*LINE_BYTES+4,1,'0,'0);
            assert(scalar_reads+block_reads+scalar_writes+block_writes==before_count) else $fatal(1,"Zero store touched lower port");
        end
        // DDR末尾不足一整行只能走原请求，不能通过块接口扩大访问范围。
        before_blocks=block_reads; before_scalar=scalar_reads;
        access_line(DDR_BYTES-4);
        assert(block_reads==before_blocks && scalar_reads==before_scalar+1) else $fatal(1,"Boundary widened");
        assert(held_cycles>0 && (!BLOCK_ENABLE || read_responses>=LINE_BYTES/DDR_BEAT_BYTES))
            else $fatal(1,"Missing backpressure/stream coverage");
        if (BLOCK_ENABLE && !INSTRUCTION) assert(write_held_cycles>0)
            else $fatal(1,"No W backpressure observed");
        $display("PASS tb_cache_block RV%0d block=%0d instruction=%0d line=%0d checks=%0d scalar=%0d/%0d blockcmd=%0d/%0d R/B=%0d/%0d held=%0d Wheld=%0d",
            XLEN,BLOCK_ENABLE,INSTRUCTION,LINE_BYTES,checks,scalar_reads,scalar_writes,block_reads,block_writes,
            read_responses,write_responses,held_cycles,write_held_cycles);
        $finish;
    end
endmodule
