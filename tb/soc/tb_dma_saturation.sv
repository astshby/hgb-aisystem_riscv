// Module: tb_dma_saturation
// Description: Continuously queued real DMA copies through the AXI system fabric and DDR clock bridge.
`include "tb/common/soc_latency_metrics.sv"
module tb_dma_saturation;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    localparam int BYTES=65536;
    logic clk_sys=0, clk_ddr=0, rst=1, start_valid=0;
    realtime sys_half=6.25ns;
    int sys_half_ps=6250;
    logic [31:0] start_src=32'h80000000, start_dst=32'h80008000, start_length=16384;
    logic busy, finish_valid, finish_error;
    logic [2:0] finish_code;
    logic [31:0] finish_bytes, finish_addr;
    logic [31:0] fault_read_addr='1, fault_write_addr='1;
    axi_req_t masters[4], targets[7], dma_req, ddr_req;
    axi_rsp_t responses[4], target_responses[7], dma_rsp, ddr_rsp;
    logic metrics_enable=0, roi=0;
    longint unsigned cycles=0, start_cycle, saturation_cycles, total_bytes=0;
    realtime start_time;
    int copies=0;
    initial begin
        void'($value$plusargs("SYS_HALF_PS=%d",sys_half_ps));
        assert(sys_half_ps inside {5000,6250}) else $fatal(1,"unsupported diagnostic SYS period");
        sys_half=real'(sys_half_ps)*1ps;
        metrics_enable=$test$plusargs("METRICS");
        forever #(sys_half) clk_sys=!clk_sys;
    end
    always #4ns clk_ddr=!clk_ddr;
    always @(posedge clk_sys) if(!rst) cycles<=cycles+1;
    assign masters[0]='0;
    assign masters[1]='0;
    assign masters[2]=dma_req;
    assign masters[3]='0;
    assign dma_rsp=responses[2];
    dma_axi_master #(.DDR_BYTES(BYTES)) dut(.clk(clk_sys),.rst,.start_valid,.start_src,.start_dst,.start_length,
        .busy,.finish_valid,.finish_error,.finish_code,.finish_bytes,.finish_addr,.axi_req(dma_req),.axi_rsp(dma_rsp));
    axi_system_fabric #(.DDR_BYTES(BYTES)) fabric(.clk(clk_sys),.rst,.m_req(masters),.m_rsp(responses),
        .s_req(targets),.s_rsp(target_responses));
    for(genvar target=0;target<7;target++) begin : g_unused_target
        if(target!=3) begin : g_error
            axi_error_target error_target(.clk(clk_sys),.rst,.req(targets[target]),.rsp(target_responses[target]));
        end
    end
    axi_clock_bridge bridge(.s_clk(clk_sys),.s_rst(rst),.m_clk(clk_ddr),.m_rst(rst),
        .s_req(targets[3]),.s_rsp(target_responses[3]),.m_req(ddr_req),.m_rsp(ddr_rsp));
    axi_system_memory_model #(.BYTES(BYTES)) memory(.clk(clk_ddr),.rst,.stall(1'b0),.req(ddr_req),.rsp(ddr_rsp),
        .fault_read_addr,.fault_write_addr);
    soc_axi_latency_metrics #(.NAME("dma.master"),.DOMAIN("sys")) master_metrics(
        .clk(clk_sys),.rst,.enable(metrics_enable),.roi,.req(dma_req),.rsp(dma_rsp));
    soc_axi_latency_metrics #(.NAME("ddr.target"),.DOMAIN("ddr")) ddr_metrics(
        .clk(clk_ddr),.rst,.enable(metrics_enable),.roi,.req(ddr_req),.rsp(ddr_rsp));
    task automatic copy(input int src,input int dst,input int bytes,input bit expect_error=0);
        while(busy) @(negedge clk_sys);
        start_src=32'h80000000+32'(src); start_dst=32'h80000000+32'(dst); start_length=32'(bytes);
        start_valid=1;
        @(negedge clk_sys); start_valid=0;
        for(int timeout=0;!finish_valid;timeout++) begin
            assert(timeout<100000) else $fatal(1,"DMA saturation timeout");
            @(negedge clk_sys);
        end
        assert(finish_error==expect_error) else $fatal(1,"DMA finish error mismatch code=%0d",finish_code);
        if(!expect_error) assert(finish_bytes==32'(bytes)) else $fatal(1,"DMA byte count");
        else assert(finish_bytes<=4096&&finish_bytes%128==0) else $fatal(1,"DMA error confirmed prefix");
        for(int index=0;index<int'(finish_bytes);index++)
            assert(memory.mem[dst+index]==memory.mem[src+index]) else $fatal(1,"DMA data mismatch index=%0d",index);
        if(!expect_error) begin total_bytes+=64'(bytes); copies++; end
    endtask
    initial begin
        for(int i=0;i<BYTES;i++) memory.mem[i]=8'((i*17)^(i>>8)^8'h5a);
        repeat(12) @(negedge clk_sys);
        rst=0;
        @(negedge clk_sys);
        roi=1; start_cycle=cycles; start_time=$realtime;
        // 下一命令在引擎允许的第一个负沿提交；不插入100us软件节拍或中断等待。
        repeat(8) copy(0,32768,16384);
        roi=0; saturation_cycles=cycles-start_cycle;
        $display("DMA_SATURATION RV%0d copies=%0d bytes=%0d sys_cycles=%0d elapsed_ns=%0.3f MB_per_s=%0.6f sys_half_ps=%0d ddr_half_ps=4000 metrics=%0d",
            XLEN,copies,total_bytes,saturation_cycles,$realtime-start_time,
            real'(total_bytes)*1000.0/($realtime-start_time),sys_half_ps,metrics_enable);
        copy(1,32771,67);
        fault_read_addr=32'h80001000;
        copy(0,32768,8192,1);
        fault_read_addr='1;
        while(busy) @(negedge clk_sys);
        repeat(8) @(negedge clk_sys);
        assert(copies==9&&total_bytes==131139) else $fatal(1,"DMA diagnostic case coverage");
        $display("PASS dma-saturation RV%0d copies=%0d bytes=%0d cycles=%0d continuous=8 unaligned_tail=1 read_error_prefix=1",
            XLEN,copies,total_bytes,cycles);
        $finish;
    end
endmodule
