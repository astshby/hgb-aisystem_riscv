// Module: tb_axi_bus_target
// Description: Cycle comparison of AXI scalar addressing under burst, overlap, errors and backpressure.
module tb_axi_bus_target #(
    parameter bit READ_ONLY = 0,
    parameter int LOCAL_BYTES = core_config_pkg::DBUS_BYTES
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    logic clk = 0, rst = 1;
    axi_req_t axi_req = '0;
    axi_rsp_t axi_rsp, reference_rsp;
    bus_req_t request, reference_request;
    bus_rsp_t response;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    logic reference_valid, reference_ready, pending_q;
    int delay_q, cycles = 0, checks = 0;
    int reads = 0, writes = 0, read_beats = 0, read_errors = 0, write_errors = 0;
    int local_reads = 0, local_writes = 0, stalls = 0, overlaps = 0;

    always #5 clk = ~clk;
    axi_bus_target #(.READ_ONLY(READ_ONLY), .LOCAL_BYTES(LOCAL_BYTES)) dut (.*);
    axi_bus_target_reference #(.READ_ONLY(READ_ONLY), .LOCAL_BYTES(LOCAL_BYTES)) reference_target (
        .clk, .rst, .axi_req, .axi_rsp(reference_rsp), .request(reference_request),
        .req_valid(reference_valid), .req_ready, .rsp_valid,
        .rsp_ready(reference_ready), .response
    );
    assign req_ready = !rst && !pending_q && cycles % 5 != 0 && cycles % 7 != 0;
    assign rsp_valid = pending_q && delay_q == 0;
    // 本地应答插入延迟和两种错误；请求只有真正握手后才拥有该应答。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 0;
            delay_q <= 0;
            response <= '0;
        end else begin
            if (delay_q != 0) delay_q <= delay_q-1;
            if (rsp_valid && rsp_ready) pending_q <= 0;
            if (req_valid && req_ready) begin
                pending_q <= 1;
                delay_q <= 1+int'(request.addr[4:3]);
                response <= '{rdata:core_types_pkg::xlen_t'(64'h16e3b74a92d8c05f ^ 64'(request.addr)),
                              error:request.addr[9:8] == 2'b01 ? BUS_SLVERR :
                                    request.addr[9:8] == 2'b10 ? BUS_DECERR : BUS_OK};
            end
        end
    end
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (!rst) begin
            assert (axi_rsp == reference_rsp && req_valid == reference_valid && rsp_ready == reference_ready)
                else $fatal(1, "AXI cycle mismatch RV%0d RO%0d cycle=%0d",XLEN,READ_ONLY,cycles);
            if (req_valid) begin
                assert (request.addr == reference_request.addr && request.size == reference_request.size &&
                        request.write == reference_request.write && request.execute == reference_request.execute)
                    else $fatal(1, "AXI address mismatch cycle=%0d candidate=%h baseline=%h",cycles,request.addr,reference_request.addr);
                if (request.write) begin
                    assert (request.wdata == reference_request.wdata && request.wstrb == reference_request.wstrb)
                        else $fatal(1, "AXI write lanes mismatch cycle=%0d address=%h",cycles,request.addr);
                end
                if (!req_ready) stalls++;
                else if (request.write) local_writes++;
                else local_reads++;
            end
            if (dut.read_active_q && dut.write_active_q) overlaps++;
            checks++;
        end
    end
    task automatic read_case(input logic [31:0] address, input int size, beats, input bit execute);
        axi_r_t held;
        axi_id_t id;
        id = axi_id_t'(reads+3);
        @(negedge clk);
        axi_req.ar_valid = 1;
        axi_req.ar = '{id:id,addr:address,len:8'(beats-1),size:3'(size),burst:1,
                       prot:execute ? 3'b100 : 3'b000,default:'0};
        do @(posedge clk); while (!axi_rsp.ar_ready);
        @(negedge clk); axi_req.ar_valid = 0;
        for (int beat = 0; beat < beats; beat++) begin
            while (!axi_rsp.r_valid) @(negedge clk);
            held = axi_rsp.r;
            repeat (3+beat%4) begin
                @(negedge clk);
                assert (axi_rsp.r_valid && axi_rsp.r == held) else $fatal(1, "AXI R changed while stalled");
            end
            assert (axi_rsp.r.id == id && axi_rsp.r.last == (beat == beats-1))
                else $fatal(1, "AXI R ID/last mismatch");
            if (axi_rsp.r.resp != AXI_OKAY) read_errors++;
            read_beats++;
            axi_req.r_ready = 1;
            @(posedge clk); @(negedge clk); axi_req.r_ready = 0;
        end
        reads++;
    endtask
    task automatic write_case(input logic [31:0] address, input int size, beats,
                              input bit data_first, input int strobe_mode, input bit bad_last);
        axi_b_t held;
        axi_id_t id;
        logic [31:0] strobe;
        id = axi_id_t'(writes+7);
        @(negedge clk);
        axi_req.aw = '{id:id,addr:address,len:8'(beats-1),size:3'(size),burst:1,default:'0};
        if (!data_first) begin
            axi_req.aw_valid = 1;
            do @(posedge clk); while (!axi_rsp.aw_ready);
            @(negedge clk); axi_req.aw_valid = 0;
        end
        for (int beat = 0; beat < beats; beat++) begin
            strobe = (32'hffffffff >> (32-(1 << size))) << address[4:0];
            unique case (strobe_mode)
                1: strobe &= 32'h55aa0f00 >> (beat%4);
                2: strobe = beat%2 == 0 ? 0 : strobe;
                3: strobe = 32'hffffffff;
                default: begin end
            endcase
            axi_req.w_valid = 1;
            axi_req.w = '{data:{8{32'h91c4e207 ^ 32'(beat)}},strb:strobe,
                          last:(beat == beats-1) ^ bad_last};
            do @(posedge clk); while (!axi_rsp.w_ready);
            @(negedge clk); axi_req.w_valid = 0;
            if (data_first && beat == 0) begin
                repeat (3) @(negedge clk);
                axi_req.aw_valid = 1;
                do @(posedge clk); while (!axi_rsp.aw_ready);
                @(negedge clk); axi_req.aw_valid = 0;
            end
            repeat (beat%3) @(negedge clk);
        end
        while (!axi_rsp.b_valid) @(negedge clk);
        held = axi_rsp.b;
        repeat (5) begin
            @(negedge clk);
            assert (axi_rsp.b_valid && axi_rsp.b == held) else $fatal(1, "AXI B changed while stalled");
        end
        assert (axi_rsp.b.id == id) else $fatal(1, "AXI B ID mismatch");
        if (axi_rsp.b.resp != AXI_OKAY) write_errors++;
        if (READ_ONLY) assert (axi_rsp.b.resp == AXI_SLVERR) else $fatal(1, "Read-only write accepted");
        axi_req.b_ready = 1;
        @(posedge clk); @(negedge clk); axi_req.b_ready = 0;
        writes++;
    endtask
    initial begin
        repeat (4) @(negedge clk); rst = 0;
        // 覆盖窄拍、宽拍拆分、取指 4 字节步长、保留 size 编码及跨 32 位地址边界。
        for (int size = 0; size <= 7; size++) begin
            for (int offset = 0; offset < 4; offset++) begin
                read_case(32'h2000+32'(offset << size),size,1+offset,1'(offset));
                write_case(32'h2000+32'(offset << size),size,1+offset,1'(offset),offset,0);
            end
        end
        for (int err = 0; err < 3; err++) begin
            read_case(32'h4000+32'(err*256),5,3,0);
            write_case(32'h4000+32'(err*256),5,3,1,0,0);
        end
        write_case(32'h6000,5,4,0,0,1);
        read_case(32'hffffffe0,5,4,0);
        write_case(32'hffffffe0,5,4,1,0,0);
        fork
            read_case(32'h8000,5,256,1);
            write_case(32'ha000,5,256,1,1,0);
        join
        assert (local_reads > 0 && stalls > 0 && overlaps > 0 && read_errors > 0 && write_errors > 0 &&
                (READ_ONLY ? local_writes == 0 : local_writes > 0)) else $fatal(1, "AXI coverage missing");
        $display("PASS tb_axi_bus_target RV%0d RO%0d local_bytes=%0d checks=%0d reads=%0d writes=%0d beats=%0d local=%0d/%0d errors=%0d/%0d stalls=%0d overlaps=%0d",
                 XLEN,READ_ONLY,LOCAL_BYTES,checks,reads,writes,read_beats,local_reads,local_writes,read_errors,write_errors,stalls,overlaps);
        $finish;
    end
    initial begin #5ms; $fatal(1, "AXI target timeout"); end
endmodule
