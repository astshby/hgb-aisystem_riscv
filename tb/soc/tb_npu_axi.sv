// Module: tb_npu_axi
// Description: Public AXI burst/byte-lane, backpressure, error and coordinated-reset checks across NPU clocks.
module tb_npu_axi #(
    parameter int NPU_HALF_PS = 5000
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk_sys=0, clk_npu=0, rst_sys=1, rst_npu=1;
    axi_req_t axi_req='0;
    axi_rsp_t axi_rsp;
    int checks=0;
    always #6250ps clk_sys=~clk_sys;
    always #(NPU_HALF_PS*1ps) clk_npu=~clk_npu;
    npu_axi_target dut (.*);

    function automatic logic [255:0] pattern(input int beat);
        for (int lane=0;lane<8;lane++) pattern[lane*32+:32]=32'h91b38a20 ^ 32'(beat*8+lane)*32'h01010203;
    endfunction

    task automatic write_case(input logic[31:0] address, input int size, beats,
        input logic[31:0] strobes, input bit first_data, input axi_resp_e expected);
        axi_b_t held;
        fork
            begin
                repeat(first_data ? 5 : 1) @(negedge clk_sys);
                axi_req.aw='{id:5,addr:address,len:8'(beats-1),size:3'(size),burst:1,default:'0};
                axi_req.aw_valid=1;
                do @(posedge clk_sys); while (!axi_rsp.aw_ready);
                @(negedge clk_sys); axi_req.aw_valid=0;
            end
            begin
                @(negedge clk_sys);
                for (int beat=0;beat<beats;beat++) begin
                    axi_req.w='{data:pattern(beat),strb:strobes,last:beat==beats-1};
                    axi_req.w_valid=1;
                    do @(posedge clk_sys); while (!axi_rsp.w_ready);
                    @(negedge clk_sys); axi_req.w_valid=0;
                    repeat(beat%3) @(negedge clk_sys);
                end
            end
        join
        while (!axi_rsp.b_valid) @(negedge clk_sys);
        held=axi_rsp.b;
        repeat(7) begin
            @(negedge clk_sys);
            assert(axi_rsp.b_valid && axi_rsp.b==held) else $fatal(1,"NPU B changed under backpressure");
        end
        assert(held.id==5 && held.resp==expected) else $fatal(1,"NPU write response address=%h got=%h expected=%h",address,held.resp,expected);
        axi_req.b_ready=1;
        @(posedge clk_sys); @(negedge clk_sys); axi_req.b_ready=0;
        checks++;
    endtask

    task automatic read_case(input logic[31:0] address, input int size, beats,
        input axi_resp_e expected, input bit check_pattern, input logic[31:0] single_word);
        axi_r_t held;
        @(negedge clk_sys);
        axi_req.ar='{id:9,addr:address,len:8'(beats-1),size:3'(size),burst:1,default:'0};
        axi_req.ar_valid=1;
        do @(posedge clk_sys); while (!axi_rsp.ar_ready);
        @(negedge clk_sys); axi_req.ar_valid=0;
        for (int beat=0;beat<beats;beat++) begin
            while (!axi_rsp.r_valid) @(negedge clk_sys);
            held=axi_rsp.r;
            repeat(3+beat) begin
                @(negedge clk_sys);
                assert(axi_rsp.r_valid && axi_rsp.r==held) else $fatal(1,"NPU R changed under backpressure");
            end
            assert(held.id==9 && held.last==(beat==beats-1) && held.resp==expected)
                else $fatal(1,"NPU read response address=%h beat=%0d resp=%h",address,beat,held.resp);
            if (check_pattern) assert(held.data==pattern(beat))
                else $fatal(1,"NPU burst lane mismatch beat=%0d data=%h",beat,held.data);
            else if (expected==AXI_OKAY) assert(held.data[8*int'(address[4:0])+:32]==single_word)
                else $fatal(1,"NPU scalar lane mismatch address=%h data=%h",address,held.data);
            axi_req.r_ready=1;
            @(posedge clk_sys); @(negedge clk_sys); axi_req.r_ready=0;
            checks++;
        end
    endtask

    initial begin
        repeat(12) @(negedge clk_sys);
        rst_sys=0; rst_npu=0;
        read_case(32'h20000000,2,1,AXI_OKAY,0,32'h4e505531);
        read_case(32'h20000004,2,1,AXI_OKAY,0,32'h00010000);
        write_case(32'h20000100,5,4,'1,1,AXI_OKAY);
        read_case(32'h20000100,5,4,AXI_OKAY,1,0);
        // 上半 RV64 word 及 byte strobes；未选字节必须保留。
        write_case(32'h20000064,2,1,32'h00000030,0,AXI_OKAY);
        read_case(32'h20000064,2,1,AXI_OKAY,0,32'h00008823);
        read_case(32'h20010000,2,1,AXI_DECERR,0,0);
        write_case(32'h20000061,0,1,32'h00000002,0,AXI_DECERR);
        read_case(32'h20000060,2,1,AXI_OKAY,0,0);
        read_case(32'h20000300,2,1,AXI_SLVERR,0,0);
        // 响应已返回且被阻塞时协调复位，两端旧响应必须清除。
        @(negedge clk_sys);
        axi_req.ar='{id:2,addr:32'h20000000,len:0,size:2,burst:1,default:'0};
        axi_req.ar_valid=1;
        do @(posedge clk_sys); while(!axi_rsp.ar_ready);
        @(negedge clk_sys); axi_req.ar_valid=0;
        while(!axi_rsp.r_valid) @(negedge clk_sys);
        rst_sys=1; rst_npu=1;
        repeat(12) @(negedge clk_sys);
        assert(!axi_rsp.r_valid && !axi_rsp.b_valid) else $fatal(1,"NPU stale response after reset");
        rst_sys=0; rst_npu=0;
        read_case(32'h20000000,2,1,AXI_OKAY,0,32'h4e505531);
        $display("PASS npu-axi RV%0d npu_half_ps=%0d checks=%0d",core_config_pkg::XLEN,NPU_HALF_PS,checks);
        $finish;
    end
    initial begin
        #20ms;
        $fatal(1,"NPU AXI timeout");
    end
endmodule
