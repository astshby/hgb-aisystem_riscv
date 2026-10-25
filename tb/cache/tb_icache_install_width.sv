// Module: tb_icache_install_width_case
// Description: Byte-reference native IF64 checks for scalar/block installation widths and canceled or faulty fills.
module tb_icache_install_width_case #(
    parameter bit BLOCK = 0,
    parameter int LINE_BYTES = 32
) (output logic done);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    localparam int FILL_BYTES = `SOC_ICACHE_FILL_BYTES;
    localparam int BEATS = LINE_BYTES/DDR_BEAT_BYTES;
    localparam xlen_t BASE = xlen_t'(32'h80000000);
    typedef enum int {GOOD, ERROR_FIRST, ERROR_LAST, EARLY_LAST, LATE_LAST} fault_e;
    logic clk=0, rst=1, invalidate=0, req_valid=0, req_ready, rsp_valid, rsp_ready=1;
    xlen_t req_addr=0, fault_word='1;
    logic [63:0] rsp_data, expected_data, previous_response;
    logic [1:0] rsp_error, expected_error, previous_error;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid=0, mem_rsp_ready;
    bus_req_t mem_request, scalar_request_q, previous_request;
    bus_rsp_t mem_response='0;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid=0, rd_ready;
    block_cmd_t rd_cmd, block_request_q, previous_command;
    block_r_t rd_data='0;
    fault_e fault=GOOD, captured_fault=GOOD;
    logic scalar_pending=0, block_pending=0, pending=0, accepted=0;
    logic previous_request_stall=0, previous_command_stall=0, previous_response_stall=0;
    logic frame_closed=0;
    int scalar_delay=0, block_delay=0, block_index=0, block_length=0;
    int cycles=0, requests=0, replies=0, accesses=0, hits=0, installs=0, checks=0;
    int fill_words=0, last_block_cycle=0, tail_checks=0, held_cycles=0, streak=0, max_streak=0;
    int framing_checks=0, invalidate_checks=0;
    always #5 clk=~clk;
    icache_native #(.DDR_BYTES(8192), .CACHE_BYTES(512), .LINE_BYTES(LINE_BYTES), .BLOCK_ENABLE(BLOCK)) dut (.*);

    function automatic logic [7:0] byte_value(input xlen_t addr);
        return 8'(addr ^ (addr>>5) ^ xlen_t'(8'ha3));
    endfunction
    function automatic logic [63:0] pair_value(input xlen_t addr);
        logic [63:0] value;
        for(int b=0;b<8;b++) value[8*b +: 8]=byte_value(addr+xlen_t'(b));
        return value;
    endfunction
    assign mem_req_ready=!rst && !scalar_pending && !mem_rsp_valid && cycles%4!=2;
    assign rd_cmd_ready=!rst && !block_pending && !rd_valid && cycles%5!=2;
    // 所有返回都先寄存；等待下游握手时保持valid和载荷，不借用DUT内部索引生成数据。
    always_ff @(posedge clk) begin
        if(rst) begin
            scalar_pending<=0; block_pending<=0; mem_rsp_valid<=0; rd_valid<=0;
        end else begin
            if(mem_rsp_valid && mem_rsp_ready) mem_rsp_valid<=0;
            if(mem_req_valid && mem_req_ready) begin
                assert(mem_request.execute && !mem_request.write && mem_request.size==MEM_WORD && mem_request.addr[1:0]==0)
                    else $fatal(1,"I-cache scalar access widened or changed permission");
                scalar_pending<=1; scalar_request_q<=mem_request; scalar_delay<=2;
            end
            if(scalar_pending) begin
                if(scalar_delay!=0) scalar_delay<=scalar_delay-1;
                else begin
                    scalar_pending<=0; mem_rsp_valid<=1;
                    mem_response.error<=scalar_request_q.addr==fault_word ? BUS_SLVERR : BUS_OK;
                    for(int b=0;b<DBUS_BYTES;b++)
                        mem_response.rdata[8*b +: 8]<=byte_value((scalar_request_q.addr & ~xlen_t'(DBUS_BYTES-1))+xlen_t'(b));
                end
            end
            if(rd_cmd_valid && rd_cmd_ready) begin
                assert(rd_cmd.len==8'(BEATS-1) && rd_cmd.size==5 && rd_cmd.execute)
                    else $fatal(1,"I-cache block command changed");
                block_pending<=1; block_request_q<=rd_cmd; block_index<=0; block_delay<=2;
                captured_fault<=fault;
                block_length<=fault==EARLY_LAST ? 1 : (fault==LATE_LAST ? BEATS+1 : BEATS);
            end
            if(rd_valid && rd_ready) begin
                rd_valid<=0; block_index<=block_index+1; block_delay<=1;
                if(rd_data.last) block_pending<=0;
            end
            if(block_pending && !rd_valid) begin
                if(block_delay!=0) block_delay<=block_delay-1;
                else begin
                    rd_valid<=1; rd_data.last<=block_index==block_length-1;
                    rd_data.error<=((captured_fault==ERROR_FIRST && block_index==0) ||
                                    (captured_fault==ERROR_LAST && block_index==block_length-1)) ? BUS_SLVERR : BUS_OK;
                    for(int b=0;b<DDR_BEAT_BYTES;b++)
                        rd_data.data[8*b +: 8]<=byte_value(block_request_q.addr+xlen_t'(block_index*DDR_BEAT_BYTES+b));
                end
            end
        end
    end
    // 独立字节参考同时检查安装次序、末beat之前不写RAM，以及整行成功后的安装尾延迟。
    always @(posedge clk) if(!rst) begin
        cycles<=cycles+1;
        if(previous_request_stall)
            assert(mem_req_valid && mem_request==previous_request) else $fatal(1,"scalar request unstable");
        if(previous_command_stall)
            assert(rd_cmd_valid && rd_cmd==previous_command) else $fatal(1,"block command unstable");
        if(previous_response_stall) begin
            assert(rsp_valid && rsp_data==previous_response && rsp_error==previous_error)
                else $fatal(1,"IF64 response unstable under backpressure");
            held_cycles++;
        end
        previous_request_stall=mem_req_valid&&!mem_req_ready; previous_request=mem_request;
        previous_command_stall=rd_cmd_valid&&!rd_cmd_ready; previous_command=rd_cmd;
        previous_response_stall=rsp_valid&&!rsp_ready; previous_response=rsp_data; previous_error=rsp_error;
        if(dut.u_refill.start_valid && dut.u_refill.start_ready) fill_words=0;
        if(rd_cmd_valid && rd_cmd_ready) frame_closed=0;
        if(dut.fill_write) begin
            if(BLOCK) assert(frame_closed && captured_fault==GOOD) else $fatal(1,"faulty/incomplete block wrote RAM");
            assert(int'(dut.fill_word)==fill_words) else $fatal(1,"installation word order");
            for(int b=0;b<FILL_BYTES;b++)
                assert(dut.fill_data[8*b +: 8]==byte_value((dut.request_q.addr & ~xlen_t'(LINE_BYTES-1))+xlen_t'(fill_words*FILL_BYTES+b)))
                    else $fatal(1,"installation byte mismatch word=%0d byte=%0d",fill_words,b);
            fill_words++;
        end
        if(rd_valid && rd_ready && rd_data.last) begin frame_closed=1; last_block_cycle=cycles; end
        if(dut.install) begin
            assert(fill_words==LINE_BYTES/FILL_BYTES && !invalidate) else $fatal(1,"tag installed before full line");
            if(BLOCK) begin
                assert(cycles-last_block_cycle==LINE_BYTES/FILL_BYTES+1)
                    else $fatal(1,"installation tail cycles=%0d expected=%0d",cycles-last_block_cycle,LINE_BYTES/FILL_BYTES+1);
                tail_checks++;
            end
            installs++;
        end
        if(BLOCK && dut.fill_done && !dut.fill_installable)
            assert(fill_words==0) else $fatal(1,"failed block partially installed");
        if((mem_req_valid && mem_req_ready) || (rd_cmd_valid && rd_cmd_ready)) accesses++;
        if(dut.touch && !dut.install) hits++;
        accepted=req_valid && req_ready;
        streak=accepted ? streak+1 : 0;
        if(streak>max_streak) max_streak=streak;
        if(rsp_valid) begin
            assert(pending && rsp_error==expected_error) else $fatal(1,"IF response owner/error block=%0d line=%0d",BLOCK,LINE_BYTES);
            for(int w=0;w<2;w++) if(!expected_error[w])
                assert(rsp_data[32*w +: 32]==expected_data[32*w +: 32]) else $fatal(1,"IF64 half data mismatch");
            if(rsp_ready) begin pending=0; replies++; end
        end
        if(accepted) begin
            assert(!pending) else $fatal(1,"IF64 owner overwritten");
            pending=1; requests++; expected_data=pair_value(req_addr);
            expected_error={req_addr+xlen_t'(4)==fault_word,req_addr==fault_word};
        end
        assert(cycles<30000) else $fatal(1,"I-cache installation timeout");
    end
    task automatic send(input xlen_t addr);
        req_valid=1; req_addr=addr;
        do begin @(posedge clk); #1; @(negedge clk); end while(!accepted);
        req_valid=0;
    endtask
    task automatic drain;
        while(pending) @(negedge clk);
        @(negedge clk); checks++;
    endtask
    task automatic expect_refill(input xlen_t addr);
        int before_accesses;
        before_accesses=accesses; send(addr); drain();
        assert(accesses>before_accesses) else $fatal(1,"failed or invalidated line became a cache hit");
    endtask
    task automatic failed_block(input fault_e mode, input int offset, input int bad_half);
        xlen_t addr;
        addr=BASE+xlen_t'(offset); fault=mode;
        fault_word=bad_half<0 ? '1 : addr+xlen_t'(4*bad_half);
        send(addr); drain();
        fault=GOOD; fault_word='1;
        expect_refill(addr); framing_checks++;
    endtask
    initial begin
        done=0;
        repeat(3) @(negedge clk); rst=0;
        send(BASE+xlen_t'(LINE_BYTES-8)); drain();
        for(int i=0;i<64;i++) begin
            req_valid=1; req_addr=BASE+xlen_t'((i%(LINE_BYTES/8))*8);
            @(posedge clk); #1; assert(accepted) else $fatal(1,"IF64 hit initiation interval changed");
            @(negedge clk);
        end
        req_valid=0; drain();
        rsp_ready=0; send(BASE); wait(rsp_valid); repeat(6) @(negedge clk); rsp_ready=1; drain();
        // ROM旁路分别验证低/高32位错误，不能把64位安装宽度传播到标量执行权限。
        fault_word=16; send(16); drain(); fault_word=20; send(16); drain(); fault_word='1; send(16); drain();
        if(BLOCK) begin
            failed_block(ERROR_FIRST,512,0);
            failed_block(ERROR_LAST,768,1);
            if(BEATS>1) failed_block(EARLY_LAST,1024,-1);
            failed_block(LATE_LAST,1280,-1);
        end else begin
            fault_word=BASE+xlen_t'(512+4);
            send(BASE+xlen_t'(512+LINE_BYTES-8)); drain(); fault_word='1;
            expect_refill(BASE+xlen_t'(512+LINE_BYTES-8));
        end
        // 接受后不能撤销外部所有权；四个时点的失效都排空并回复，但禁止重新安装tag。
        for(int phase=0;phase<4;phase++) begin
            xlen_t addr;
            addr=BASE+xlen_t'(2048+phase*256);
            send(addr);
            case(phase)
                0: wait(dut.u_refill.start_valid);
                1: begin if(BLOCK) wait(rd_valid); else wait(mem_rsp_valid); end
                2: wait(dut.fill_write);
                default: wait(dut.fill_done);
            endcase
            @(negedge clk); invalidate=1;
            @(negedge clk); invalidate=0; drain();
            expect_refill(addr); invalidate_checks++;
        end
        assert(requests==replies && !pending && max_streak>=64 && hits>=64 && held_cycles>=5 && invalidate_checks==4 &&
               (!BLOCK || tail_checks>0)) else $fatal(1,"I-cache installation coverage");
        $display("PASS ICACHE_INSTALL_CASE RV%0d fill=%0d block=%0d line=%0d requests=%0d hits=%0d installs=%0d tail=%0d framing=%0d invalidates=%0d",
            XLEN,FILL_BYTES,BLOCK,LINE_BYTES,requests,hits,installs,tail_checks,framing_checks,invalidate_checks);
        done=1;
    end
endmodule

// Module: tb_icache_install_width
// Description: Runs scalar/block 32/64-byte lines and the minimum scalar line using the selected installation width.
module tb_icache_install_width;
    timeunit 1ns;
    timeprecision 1ps;
    logic [4:0] done;
    for(genvar line=0;line<2;line++) begin : g_line
        for(genvar block_mode=0;block_mode<2;block_mode++) begin : g_mode
            tb_icache_install_width_case #(.LINE_BYTES(32<<line),.BLOCK(block_mode!=0)) u_case (.done(done[2*line+block_mode]));
        end
    end
    tb_icache_install_width_case #(.LINE_BYTES(8),.BLOCK(0)) u_small (.done(done[4]));
    initial begin
        wait(&done);
        $display("PASS tb_icache_install_width RV%0d fill=%0d cases=5 scalar_word32 hit_II=1 atomic_block framing invalidate held_response",
            core_config_pkg::XLEN,`SOC_ICACHE_FILL_BYTES);
        $finish;
    end
endmodule
