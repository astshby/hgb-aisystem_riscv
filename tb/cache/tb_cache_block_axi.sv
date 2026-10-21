// Module: tb_cache_block_axi
// Description: Real cache-to-AXI integration with byte-reference writeback recovery and per-beat read faults.
module tb_cache_block_axi #(
    parameter int LINE_BYTES = 64,
    parameter bit INSTRUCTION = 1'b0
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import cache_pkg::*;
    localparam int BYTES=4096, BEATS=LINE_BYTES/DDR_BEAT_BYTES, CLIENT=INSTRUCTION?0:1;
    localparam xlen_t BASE=xlen_t'(soc_addr_pkg::DDR_BASE);
    logic clk=0, rst=1, invalidate=0;
    always #5 clk=~clk;
    logic req_valid=0, req_ready, rsp_valid, rsp_ready=0;
    bus_req_t request='0, mem_request;
    bus_rsp_t response, mem_response;
    logic mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_r_t cache_rd_data [2];
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready;
    logic [1:0] cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_w_t cache_wr_data [2];
    block_b_t cache_wr_rsp [2];
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic maint_req_valid=0, maint_req_ready, maint_rsp_valid, maint_rsp_ready=0;
    cache_maint_op_e maint_op=CACHE_NONE;
    cache_maint_error_e maint_error, fault_code;
    xlen_t maint_fault_addr, fault_addr;
    logic fault_valid;
    logic dma_req_valid=0, dma_req_ready, dma_rsp_valid, dma_rsp_ready=0;
    ddr_req_t dma_request='0;
    ddr_rsp_t dma_response;
    logic awvalid,awready,awid,awlock,wvalid,wready,wlast,bvalid,bready,bid;
    logic arvalid,arready,arid,arlock,rvalid,rready,rid,rlast;
    logic [31:0] awaddr,araddr;
    logic [7:0] awlen,arlen;
    logic [2:0] awsize,arsize,awprot,arprot;
    logic [1:0] awburst,arburst,bresp,rresp;
    logic [3:0] awcache,awqos,awregion,arcache,arqos,arregion;
    logic [255:0] wdata,rdata;
    logic [31:0] wstrb;
    logic [31:0] fault_read_addr='1,fault_write_addr='1;
    byte unsigned golden [BYTES];
    int checks=0, full_ar=0, full_aw=0, narrow_ar=0, read_beats=0, write_beats=0;
    int r_errors=0, b_errors=0, remaining_r=0, write_index=0;
    block_cmd_t expected_write;

    // 每配置使用真实I$/D$ client槽，另一槽空闲；标量fallback也经过同一fabric/AXI后端。
    assign cache_rd_cmd_valid[1-CLIENT]=0;
    assign cache_rd_cmd[1-CLIENT]='0;
    assign cache_rd_ready[1-CLIENT]=0;
    assign cache_wr_cmd_valid[1-CLIENT]=0;
    assign cache_wr_cmd[1-CLIENT]='0;
    assign cache_wr_valid[1-CLIENT]=0;
    assign cache_wr_data[1-CLIENT]='0;
    assign cache_wr_rsp_ready[1-CLIENT]=0;
    if (INSTRUCTION) begin
        icache #(.CACHE_BYTES(4*LINE_BYTES),.LINE_BYTES(LINE_BYTES),.DDR_BYTES(BYTES),.BLOCK_ENABLE(1)) dut (
            .clk,.rst,.invalidate,.req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response,
            .mem_req_valid,.mem_req_ready,.mem_request,.mem_rsp_valid,.mem_rsp_ready,.mem_response,
            .rd_cmd_valid(cache_rd_cmd_valid[CLIENT]),.rd_cmd_ready(cache_rd_cmd_ready[CLIENT]),
            .rd_cmd(cache_rd_cmd[CLIENT]),.rd_valid(cache_rd_valid[CLIENT]),
            .rd_ready(cache_rd_ready[CLIENT]),.rd_data(cache_rd_data[CLIENT])
        );
        assign cache_wr_cmd_valid[CLIENT]=0;
        assign cache_wr_cmd[CLIENT]='0;
        assign cache_wr_valid[CLIENT]=0;
        assign cache_wr_data[CLIENT]='0;
        assign cache_wr_rsp_ready[CLIENT]=0;
        assign maint_req_ready=0;
        assign maint_rsp_valid=0;
        assign maint_error=CACHE_OK;
        assign maint_fault_addr='0;
        assign fault_valid=0;
        assign fault_code=CACHE_OK;
        assign fault_addr='0;
    end else begin
        dcache #(.CACHE_BYTES(4*LINE_BYTES),.LINE_BYTES(LINE_BYTES),.DDR_BYTES(BYTES),.BLOCK_ENABLE(1)) dut (
            .clk,.rst,.req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response,
            .mem_req_valid,.mem_req_ready,.mem_request,.mem_rsp_valid,.mem_rsp_ready,.mem_response,
            .maint_req_valid,.maint_req_ready,.maint_op,.maint_rsp_valid,.maint_rsp_ready,
            .maint_error,.maint_fault_addr,.fault_valid,.fault_code,.fault_addr,
            .rd_cmd_valid(cache_rd_cmd_valid[CLIENT]),.rd_cmd_ready(cache_rd_cmd_ready[CLIENT]),
            .rd_cmd(cache_rd_cmd[CLIENT]),.rd_valid(cache_rd_valid[CLIENT]),
            .rd_ready(cache_rd_ready[CLIENT]),.rd_data(cache_rd_data[CLIENT]),
            .wr_cmd_valid(cache_wr_cmd_valid[CLIENT]),.wr_cmd_ready(cache_wr_cmd_ready[CLIENT]),
            .wr_cmd(cache_wr_cmd[CLIENT]),.wr_valid(cache_wr_valid[CLIENT]),.wr_ready(cache_wr_ready[CLIENT]),
            .wr_data(cache_wr_data[CLIENT]),.wr_rsp_valid(cache_wr_rsp_valid[CLIENT]),
            .wr_rsp_ready(cache_wr_rsp_ready[CLIENT]),.wr_rsp(cache_wr_rsp[CLIENT])
        );
    end
    ddr_block_fabric #(.DDR_BYTES(BYTES)) fabric (
        .clk,.rst,.cpu_req_valid(mem_req_valid),.cpu_req_ready(mem_req_ready),.cpu_request(mem_request),
        .cpu_rsp_valid(mem_rsp_valid),.cpu_rsp_ready(mem_rsp_ready),.cpu_response(mem_response),
        .dma_req_valid,.dma_req_ready,.dma_request,.dma_rsp_valid,.dma_rsp_ready,.dma_response,
        .cache_rd_cmd_valid,.cache_rd_cmd_ready,.cache_rd_cmd,.cache_rd_valid,.cache_rd_ready,.cache_rd_data,
        .cache_wr_cmd_valid,.cache_wr_cmd_ready,.cache_wr_cmd,.cache_wr_valid,.cache_wr_ready,.cache_wr_data,
        .cache_wr_rsp_valid,.cache_wr_rsp_ready,.cache_wr_rsp,
        .dma_block_rd_cmd_valid(1'b0),.dma_block_rd_cmd_ready(),.dma_block_rd_cmd('0),
        .dma_block_rd_valid(),.dma_block_rd_ready(1'b0),.dma_block_rd_data(),
        .dma_block_wr_cmd_valid(1'b0),.dma_block_wr_cmd_ready(),.dma_block_wr_cmd('0),
        .dma_block_wr_valid(1'b0),.dma_block_wr_ready(),.dma_block_wr_data('0),
        .dma_block_wr_rsp_valid(),.dma_block_wr_rsp_ready(1'b0),.dma_block_wr_rsp(),
        .rd_cmd_valid,.rd_cmd_ready,.rd_cmd,.rd_valid,.rd_ready,.rd_data,
        .wr_cmd_valid,.wr_cmd_ready,.wr_cmd,.wr_valid,.wr_ready,.wr_data,
        .wr_rsp_valid,.wr_rsp_ready,.wr_rsp
    );
    block_to_axi #(.DDR_BYTES(BYTES)) bridge (.*);
    axi_block_memory_model #(.BYTES(BYTES)) memory (
        .clk,.rst,.fault_read_addr,.fault_write_addr,.awvalid,.awready,.awid,.awaddr,.awlen,.awsize,
        .wvalid,.wready,.wdata,.wstrb,.wlast,.bvalid,.bready,.bid,.bresp,
        .arvalid,.arready,.arid,.araddr,.arlen,.arsize,.rvalid,.rready,.rid,.rdata,.rresp,.rlast
    );

    // 只以真实AXI握手计数；LEN=1必须来自64-byte行，不能用内部block计数冒充突发证据。
    always @(posedge clk) if (!rst) begin
        if (arvalid && arready) begin
            assert(remaining_r==0 && arburst==1 && arid==0) else $fatal(1,"Read ownership/framing");
            remaining_r=int'(arlen)+1;
            if(arsize==5) begin
                assert(int'(arlen)==BEATS-1 && araddr%LINE_BYTES==0 && arprot[2]==INSTRUCTION)
                    else $fatal(1,"Line AR did not form real burst");
                full_ar++;
            end else begin
                assert(arsize==2 && arlen==0) else $fatal(1,"Fallback width changed");
                narrow_ar++;
            end
        end
        if(rvalid && rready) begin
            assert(remaining_r>0 && rlast==(remaining_r==1)) else $fatal(1,"R LAST mismatch");
            remaining_r--; read_beats++;
            if(rresp!=0) r_errors++;
        end
        if(wr_cmd_valid && wr_cmd_ready) begin expected_write=wr_cmd; write_index=0; end
        if(awvalid && awready) begin
            assert(awburst==1 && awid==0 && awlen==expected_write.len && awsize==expected_write.size)
                else $fatal(1,"AW ownership/length mismatch");
            if(awsize==5) begin
                assert(int'(awlen)==BEATS-1 && awaddr%LINE_BYTES==0) else $fatal(1,"Line AW not a burst");
                full_aw++;
            end
        end
        if(wvalid && wready) begin
            assert(wlast==(write_index==int'(expected_write.len))) else $fatal(1,"W LAST mismatch");
            if(expected_write.size==5) begin
                assert(wstrb=='1) else $fatal(1,"Dirty line omitted bytes");
                for(int b=0;b<DDR_BEAT_BYTES;b++)
                    assert(wdata[8*b+:8]==golden[int'(expected_write.addr-BASE)+write_index*DDR_BEAT_BYTES+b])
                        else $fatal(1,"AXI W differs from independent architectural bytes");
            end
            write_index++; write_beats++;
        end
        if(bvalid && bready && bresp!=0) b_errors++;
    end
    logic held_ar=0,held_aw=0,held_w=0;
    logic [43:0] saved_ar,saved_aw;
    logic [288:0] saved_w;
    always_ff @(posedge clk) begin
        if(rst) begin held_ar<=0;held_aw<=0;held_w<=0;end
        else begin
            if(held_ar) assert(arvalid && {araddr,arlen,arsize,arid}==saved_ar) else $fatal(1,"AR unstable");
            if(held_aw) assert(awvalid && {awaddr,awlen,awsize,awid}==saved_aw) else $fatal(1,"AW unstable");
            if(held_w) assert(wvalid && {wdata,wstrb,wlast}==saved_w) else $fatal(1,"W unstable");
            held_ar<=arvalid&&!arready; saved_ar<={araddr,arlen,arsize,arid};
            held_aw<=awvalid&&!awready; saved_aw<={awaddr,awlen,awsize,awid};
            held_w<=wvalid&&!wready; saved_w<={wdata,wstrb,wlast};
        end
    end
    function automatic xlen_t reference_word(input int offset);
        xlen_t result;
        for(int b=0;b<DBUS_BYTES;b++) result[8*b+:8]=golden[(offset&~(DBUS_BYTES-1))+b];
        return result;
    endfunction
    task automatic access_line(input int offset,input bit store=0,input xlen_t data='0,
        input logic [DBUS_BYTES-1:0] mask='0,input bus_error_e error=BUS_OK,input bit kill_fill=0);
        bus_rsp_t saved;
        int lane,timeout;
        bit invalidated;
        @(negedge clk);
        request='{write:store,execute:INSTRUCTION,size:MEM_WORD,addr:BASE+xlen_t'(offset),wdata:data,wstrb:mask};
        req_valid=1;timeout=0;invalidated=0;
        do begin @(posedge clk);timeout++;assert(timeout<3000) else $fatal(1,"request timeout");end while(!req_ready);
        @(negedge clk);req_valid=0;
        while(!rsp_valid) begin
            if(kill_fill&&!invalidated&&rvalid) begin invalidate=1;invalidated=1;end else invalidate=0;
            @(negedge clk);timeout++;assert(timeout<3000) else $fatal(1,"response timeout");
        end
        invalidate=0;
        assert(response.error==error) else $fatal(1,"Unexpected response error got=%0d want=%0d",response.error,error);
        if(kill_fill) assert(invalidated) else $fatal(1,"Missing inflight invalidate");
        if(store&&error==BUS_OK)
            for(int b=0;b<DBUS_BYTES;b++) if(mask[b]) golden[(offset&~(DBUS_BYTES-1))+b]=data[8*b+:8];
        if(!store&&error==BUS_OK) begin
            lane=8*(offset%DBUS_BYTES);
            if(INSTRUCTION) assert(32'(response.rdata>>lane)==32'(reference_word(offset)>>lane)) else $fatal(1,"I word mismatch");
            else assert(response.rdata==reference_word(offset)) else $fatal(1,"D word mismatch");
        end
        saved=response;
        repeat(3) begin @(negedge clk);assert(rsp_valid&&response==saved) else $fatal(1,"CPU response unstable");end
        rsp_ready=1;@(negedge clk);rsp_ready=0;checks++;
    endtask
    task automatic maintain(input cache_maint_op_e op,input cache_maint_error_e error);
        @(negedge clk);maint_req_valid=1;maint_op=op;
        do @(posedge clk);while(!maint_req_ready);
        @(negedge clk);maint_req_valid=0;
        while(!maint_rsp_valid) @(negedge clk);
        assert(maint_error==error) else $fatal(1,"Unexpected maintenance error");
        repeat(2) @(negedge clk);
        maint_rsp_ready=1;@(negedge clk);maint_rsp_ready=0;checks++;
    endtask
    task automatic patch_instruction(input logic [31:0] instruction);
        // 模拟外部DMA发布代码，经真实legacy adapter/fabric/AXI写同一DDR；此处尚不改I$参考。
        @(negedge clk);
        dma_request='{addr:BASE+xlen_t'(4),write:1'b1,execute:1'b0,size:3'd2,
            wdata:256'(instruction)<<32,wstrb:32'hf0};
        dma_req_valid=1;
        do @(posedge clk);while(!dma_req_ready);
        @(negedge clk);dma_req_valid=0;
        while(!dma_rsp_valid) @(negedge clk);
        assert(dma_response.error==BUS_OK) else $fatal(1,"DMA code publish failed");
        dma_rsp_ready=1;@(negedge clk);dma_rsp_ready=0;
        for(int b=0;b<4;b++) assert(memory.mem[(4+b)/DBUS_BYTES][((4+b)%DBUS_BYTES)*8+:8]==instruction[b*8+:8])
            else $fatal(1,"Published code absent from real AXI memory");
    endtask
    int old_full,old_narrow,old_read;
    initial begin
        repeat(2) @(negedge clk);
        for(int i=0;i<BYTES;i++) begin
            golden[i]=8'((i*7)^'h9c);
            memory.mem[i/DBUS_BYTES][(i%DBUS_BYTES)*8+:8]=golden[i];
        end
        @(negedge clk);rst=0;
        access_line(4);
        old_full=full_ar;access_line(LINE_BYTES-4);
        assert(full_ar==old_full) else $fatal(1,"Cache hit reached AXI");
        for(int bad=0;bad<BEATS;bad++) begin
            fault_read_addr=32'(BASE)+3*LINE_BYTES+bad*DDR_BEAT_BYTES;
            old_full=full_ar;old_narrow=narrow_ar;old_read=read_beats;
            access_line(3*LINE_BYTES+4);
            assert(full_ar==old_full+1&&narrow_ar==old_narrow+1&&read_beats==old_read+BEATS+1)
                else $fatal(1,"Actual AXI fault drain/fallback missing");
        end
        fault_read_addr='1;
        old_full=full_ar;access_line(3*LINE_BYTES+4);
        assert(full_ar==old_full+1) else $fatal(1,"Errored AXI line installed");
        if(INSTRUCTION) begin
            // 验证FENCE.I的Cache失效输入契约；不是伪称此TB执行了Core退休FENCE.I指令。
            access_line(4);
            patch_instruction(32'hc0011073);
            old_full=full_ar;access_line(4);
            assert(full_ar==old_full) else $fatal(1,"I-cache unexpectedly coherent with DMA");
            for(int b=0;b<4;b++) golden[4+b]=8'(32'hc0011073>>(8*b));
            @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;
            old_full=full_ar;access_line(4);
            assert(full_ar==old_full+1) else $fatal(1,"FENCE.I invalidation did not refetch");
            old_full=full_ar;access_line(6*LINE_BYTES+4,0,'0,'0,BUS_OK,1);
            access_line(6*LINE_BYTES+4);
            assert(full_ar==old_full+2) else $fatal(1,"Invalidated inflight fill installed");
        end else begin
            maintain(CACHE_FLUSH,CACHE_OK);
            access_line(4,1,xlen_t'('h55aa3311)<<(8*(4%DBUS_BYTES)),DBUS_BYTES'(4'b0101)<<(4%DBUS_BYTES));
            access_line(2*LINE_BYTES+4);
            fault_write_addr=32'(BASE)+(BEATS-1)*DDR_BEAT_BYTES;
            access_line(4*LINE_BYTES+4,0,'0,'0,BUS_SLVERR);
            old_full=full_ar;access_line(4);
            assert(full_ar==old_full) else $fatal(1,"B failure discarded dirty victim");
            fault_write_addr='1;
            maintain(CACHE_CLEAN,CACHE_OK);
            for(int b=0;b<LINE_BYTES;b++)
                assert(memory.mem[b/DBUS_BYTES][(b%DBUS_BYTES)*8+:8]==golden[b])
                    else $fatal(1,"Retry did not publish full dirty line");
            maintain(CACHE_FLUSH,CACHE_OK);
            old_full=full_ar;access_line(4);
            assert(full_ar==old_full+1) else $fatal(1,"Flush did not invalidate after B success");
            assert(full_aw==2&&b_errors==1) else $fatal(1,"Missing real AXI write failure/retry");
        end
        assert(full_ar>0&&r_errors==BEATS&&remaining_r==0) else $fatal(1,"Missing AXI line/fault coverage");
        $display("PASS tb_cache_block_axi RV%0d instruction=%0d line=%0d AXI_LEN=%0d checks=%0d line_AR/AW=%0d/%0d narrow_AR=%0d R/W=%0d/%0d RERR/BERR=%0d/%0d",
            XLEN,INSTRUCTION,LINE_BYTES,BEATS-1,checks,full_ar,full_aw,narrow_ar,read_beats,write_beats,r_errors,b_errors);
        $finish;
    end
    initial begin #500000; $fatal(1,"Global AXI cache watchdog"); end
endmodule
