// Module: tb_ddr_axi_target
// Description: Calibration rejection, independent AW/W, full native return capture, IDs, errors and reuse.
module tb_ddr_axi_target;
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk=0,rst=1,memory_ready=0, native_clock_enable=1;
    wire native_clk=clk && native_clock_enable;
    always #5 clk=!clk;
    axi_req_t req='0;
    axi_rsp_t rsp, native_rsp;
    axi_req_t native_req;
    axi_availability_gate u_gate(.clk,.rst,.available(memory_ready),.s_req(req),.s_rsp(rsp),.m_req(native_req),.m_rsp(native_rsp));
    int checks=0;
    axi_native_memory_model #(.BYTES(8192)) dut(.clk(native_clk),.rst,.memory_ready,.stall(1'b0),.req(native_req),.rsp(native_rsp));
    function automatic logic [255:0] pattern(input int beat);
        logic [255:0] data;
        for(int b=0;b<32;b++) data[b*8+:8]=8'(beat*41+b);
        return data;
    endfunction
    task automatic read_case(input int id,input int beats,input axi_resp_e expected);
        @(negedge clk);req.ar_valid=1;
        req.ar='{id:axi_id_t'(id),addr:32'h80000000,len:8'(beats-1),size:5,burst:1,default:'0};
        do @(posedge clk);while(!rsp.ar_ready);
        @(negedge clk);req.ar_valid=0;
        for(int b=0;b<beats;b++) begin
            while(!rsp.r_valid) @(negedge clk);
            repeat(9) @(negedge clk);
            assert(rsp.r.id==axi_id_t'(id) && rsp.r.last==(b==beats-1) && rsp.r.resp==expected)
                else $fatal(1,"DDR R owner/frame/error id=%0d beat=%0d resp=%0d",rsp.r.id,b,rsp.r.resp);
            if(expected==AXI_OKAY) assert(rsp.r.data==pattern(b)) else $fatal(1,"native capture lost a beat");
            req.r_ready=1;@(posedge clk);@(negedge clk);req.r_ready=0;
        end
        checks++;
    endtask
    task automatic write_case(input int id,input int beats,input axi_resp_e expected);
        // 先给 W，然后给 AW，目标不能要求地址先握手才能缓存数据。
        @(negedge clk);req.w_valid=1;req.w='{data:pattern(0),strb:'1,last:beats==1};
        do @(posedge clk);while(!rsp.w_ready);
        @(negedge clk);req.w_valid=0;
        req.aw_valid=1;req.aw='{id:axi_id_t'(id),addr:32'h80000000,len:8'(beats-1),size:5,burst:1,default:'0};
        do @(posedge clk);while(!rsp.aw_ready);
        @(negedge clk);req.aw_valid=0;
        for(int b=1;b<beats;b++) begin
            req.w_valid=1;req.w='{data:pattern(b),strb:'1,last:b==beats-1};
            do @(posedge clk);while(!rsp.w_ready);
            @(negedge clk);req.w_valid=0;
        end
        while(!rsp.b_valid) @(negedge clk);
        repeat(11) @(negedge clk);
        assert(rsp.b.id==axi_id_t'(id) && rsp.b.resp==expected) else $fatal(1,"DDR B owner/error");
        req.b_ready=1;@(posedge clk);@(negedge clk);req.b_ready=0;
        checks++;
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;native_clock_enable=0;
        read_case(7,4,AXI_DECERR);
        write_case(11,2,AXI_DECERR);
        assert(dut.ar_count==0 && dut.aw_count==0) else $fatal(1,"uncalibrated request escaped to native pins");
        native_clock_enable=1;memory_ready=1;
        read_case(9,5,AXI_SLVERR);
        write_case(4,5,AXI_SLVERR);
        write_case(15,4,AXI_OKAY);
        read_case(13,4,AXI_OKAY);
        dut.malformed=1;
        read_case(6,4,AXI_SLVERR);
        dut.malformed=2;
        read_case(5,4,AXI_SLVERR);
        dut.malformed=0;
        read_case(0,4,AXI_OKAY);
        memory_ready=0;native_clock_enable=0;
        read_case(2,1,AXI_DECERR);
        native_clock_enable=1;memory_ready=1;
        read_case(1,4,AXI_OKAY);
        assert(dut.immediate_reads>0 && dut.immediate_writes>0) else $fatal(1,"missing immediate native transfer");
        $display("PASS tb_ddr_axi_target checks=%0d immediate_reads=%0d immediate_writes=%0d",checks,dut.immediate_reads,dut.immediate_writes);
        $finish;
    end
    initial begin #1ms;$fatal(1,"DDR target timeout");end
endmodule
