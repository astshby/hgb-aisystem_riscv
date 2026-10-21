// Module: tb_cache_block_protocol
// Description: Exercises atomic block refill, framing errors, fallback and coordinated reset independently of caches.
module tb_cache_block_protocol #(
    parameter int LINE_BYTES = 64,
    parameter int WORD_BYTES = 4
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    localparam int WORD_W = $clog2(LINE_BYTES/WORD_BYTES), BEATS = LINE_BYTES/DDR_BEAT_BYTES;
    logic clk=0, rst=1, start_valid=0, start_ready, fallback_enable=0;
    always #5 clk=~clk;
    bus_req_t request='0, mem_request;
    bus_rsp_t response, mem_response='0;
    logic done_valid, done_ready=0, installable, write_valid, mem_req_valid, mem_req_ready=0, mem_rsp_valid=0;
    logic [WORD_W-1:0] write_word;
    logic [WORD_BYTES*8-1:0] write_data;
    logic rd_cmd_valid, rd_cmd_ready=0, rd_valid=0, rd_ready;
    block_cmd_t rd_cmd;
    block_r_t rd_data='0;
    int writes=0, commands=0, fallbacks=0, checks=0;
    cache_refill #(.LINE_BYTES(LINE_BYTES), .WORD_BYTES(WORD_BYTES), .BLOCK_ENABLE(1)) dut (.*);

    function automatic logic [WORD_BYTES*8-1:0] word_value(input int word_index);
        logic [WORD_BYTES*8-1:0] result;
        for(int b=0;b<WORD_BYTES;b++) result[8*b +: 8]=8'('h80+word_index*WORD_BYTES+b);
        return result;
    endfunction

    // 独立序号只由外部write握手推进，不读取DUT的beat/word状态来构造期望。
    always @(posedge clk) begin
        if(rst) begin writes=0; commands=0; fallbacks=0; end
        else begin
            if(write_valid) begin
                assert(int'(write_word)==writes && write_data==word_value(writes))
                    else $fatal(1,"Buffered line word mismatch word=%0d expected=%0d",write_word,writes);
                writes++;
            end
            if(rd_cmd_valid && rd_cmd_ready) commands++;
            if(mem_req_valid && mem_req_ready) begin
                assert(mem_request==request) else $fatal(1,"Fallback changed original request");
                fallbacks++;
            end
        end
    end

    task automatic reset_owner;
        @(negedge clk); rst=1; start_valid=0; done_ready=0; rd_valid=0;
        rd_cmd_ready=0; mem_req_ready=0; mem_rsp_valid=0;
        repeat(2) @(negedge clk);
        rst=0;
        @(negedge clk);
        assert(start_ready && !done_valid && !write_valid && !rd_cmd_valid && !rd_ready)
            else $fatal(1,"Reset did not release owner");
    endtask
    task automatic launch(input bit fallback);
        block_cmd_t saved;
        @(negedge clk);
        request='{write:1'b0,execute:1'b1,size:MEM_WORD,addr:xlen_t'('h80000004),wdata:'0,wstrb:'0};
        fallback_enable=fallback; start_valid=1;
        do @(posedge clk); while(!start_ready);
        @(negedge clk); start_valid=0;
        while(!rd_cmd_valid) @(negedge clk);
        saved=rd_cmd;
        assert(saved.addr==xlen_t'('h80000000) && saved.len==BEATS-1 && saved.size==5 && saved.execute)
            else $fatal(1,"Command payload");
        repeat(3) begin @(negedge clk); assert(rd_cmd_valid && rd_cmd==saved) else $fatal(1,"Command unstable"); end
        rd_cmd_ready=1; @(negedge clk); rd_cmd_ready=0;
    endtask
    task automatic send_beat(input int index, input bit last, input bus_error_e error=BUS_OK);
        @(negedge clk);
        for(int b=0;b<DDR_BEAT_BYTES;b++) rd_data.data[8*b +: 8]=8'('h80+index*DDR_BEAT_BYTES+b);
        rd_data.last=last; rd_data.error=error; rd_valid=1;
        assert(rd_ready && writes==0 && !done_valid) else $fatal(1,"Premature install/write or missed R ownership");
        @(negedge clk); rd_valid=0;
    endtask
    task automatic complete(input bit installed, input bus_error_e error, input int expected_writes);
        bus_rsp_t saved;
        int timeout;
        timeout=0;
        while(!done_valid) begin @(negedge clk); timeout++; assert(timeout<200) else $fatal(1,"done timeout"); end
        assert(installable==installed && response.error==error && writes==expected_writes && commands==1)
            else $fatal(1,"Wrong atomic completion install=%0d writes=%0d err=%0d",installable,writes,response.error);
        saved=response;
        repeat(3) begin @(negedge clk); assert(done_valid && response==saved && installable==installed) else $fatal(1,"done changed"); end
        done_ready=1; @(negedge clk); done_ready=0;
        assert(start_ready && !done_valid) else $fatal(1,"Duplicate done");
        checks++;
    endtask

    initial begin
        reset_owner(); launch(0);
        for(int beat=0;beat<BEATS;beat++) send_beat(beat,beat==BEATS-1);
        complete(1,BUS_OK,LINE_BYTES/WORD_BYTES);
        assert(response.rdata == (xlen_t'(word_value(4/WORD_BYTES)) << (8*((4/WORD_BYTES*WORD_BYTES)%DBUS_BYTES))))
            else $fatal(1,"Demand word lane mismatch");

        reset_owner(); launch(0);
        for(int beat=0;beat<BEATS;beat++) send_beat(beat,beat==BEATS-1,beat==0?BUS_DECERR:BUS_OK);
        complete(0,BUS_DECERR,0);
        assert(fallbacks==0) else $fatal(1,"Disabled fallback emitted request");

        if(BEATS>1) begin
            reset_owner(); launch(0); send_beat(0,1);
            complete(0,BUS_SLVERR,0);
        end
        // late-last不能回卷覆盖第一beat，也不能在预期长度处提前结束并泄漏后续R。
        reset_owner(); launch(0);
        for(int beat=0;beat<BEATS;beat++) send_beat(beat,0);
        repeat(3) begin @(negedge clk); assert(rd_ready && !done_valid && !rd_cmd_valid) else $fatal(1,"Late-last was not drained"); end
        send_beat(BEATS,1); complete(0,BUS_SLVERR,0);

        reset_owner(); launch(1);
        for(int beat=0;beat<BEATS;beat++) send_beat(beat,beat==BEATS-1,beat==BEATS-1?BUS_SLVERR:BUS_OK);
        while(!mem_req_valid) @(negedge clk);
        repeat(3) begin @(negedge clk); assert(mem_req_valid && mem_request==request && !done_valid) else $fatal(1,"Fallback unstable"); end
        mem_req_ready=1; @(negedge clk); mem_req_ready=0;
        repeat(2) @(negedge clk);
        mem_response='{rdata:xlen_t'('h12345678),error:BUS_OK}; mem_rsp_valid=1;
        @(negedge clk); mem_rsp_valid=0;
        complete(0,BUS_OK,0);
        assert(fallbacks==1 && response==mem_response) else $fatal(1,"Fallback not exactly once");

        // 复位必须与外部owner一起协调；不声称仅复位Cache即可识别任意迟到无ID响应。
        reset_owner(); launch(0);
        if(BEATS>1) send_beat(0,0);
        reset_owner(); launch(0);
        for(int beat=0;beat<BEATS;beat++) send_beat(beat,beat==BEATS-1);
        complete(1,BUS_OK,LINE_BYTES/WORD_BYTES);
        $display("PASS tb_cache_block_protocol RV%0d line=%0d word=%0d checks=%0d",XLEN,LINE_BYTES,WORD_BYTES,checks);
        $finish;
    end
endmodule
