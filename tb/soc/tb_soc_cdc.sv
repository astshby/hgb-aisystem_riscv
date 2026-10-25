// Module: tb_soc_cdc
// Description: Coordinated reset with stalled channels and a stopped destination clock, followed by clean reuse.
module tb_soc_cdc #(parameter int DEPTH=2);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic s_clk=0, m_clk=0, enable_m=1, reset_async=1, s_rst, m_rst;
    always #5 s_clk=!s_clk;
    always #7 if(enable_m) m_clk=!m_clk;
    soc_reset_controller u_reset (.reset_async,.clk_core(s_clk),.clk_sys(m_clk),.clk_ddr(s_clk),.clk_periph(m_clk),
        .rst_core(s_rst),.rst_sys(m_rst),.rst_ddr(),.rst_periph());
    axi_req_t req='0, target_req;
    axi_rsp_t rsp,target_rsp;
    int reads=0,writes=0;
    axi_clock_bridge #(.DEPTH(DEPTH)) dut (.s_clk,.s_rst,.m_clk,.m_rst,.s_req(req),.s_rsp(rsp),.m_req(target_req),.m_rsp(target_rsp));
    axi_error_target u_target (.clk(m_clk),.rst(m_rst),.req(target_req),.rsp(target_rsp));
    task automatic offer_ar(input int id,input int beats);
        @(negedge s_clk);
        req.ar='{id:axi_id_t'(id),addr:32'hdead0000,len:8'(beats-1),size:5,burst:1,default:'0};
        req.ar_valid=1;
        do @(posedge s_clk); while(!rsp.ar_ready);
        @(negedge s_clk);req.ar_valid=0;
    endtask
    task automatic receive_r(input int id,input int beats);
        for(int i=0;i<beats;i++) begin
            while(!rsp.r_valid) @(negedge s_clk);
            repeat(3) @(negedge s_clk);
            assert(rsp.r.id==axi_id_t'(id) && rsp.r.resp==AXI_DECERR && rsp.r.last==(i==beats-1))
                else $fatal(1,"stale/framed R id=%0d expected=%0d",rsp.r.id,id);
            req.r_ready=1;
            @(posedge s_clk);@(negedge s_clk);req.r_ready=0;reads++;
        end
    endtask
    task automatic reset_while_stopped;
        @(negedge m_clk);enable_m=0;
        @(negedge s_clk);reset_async=1;req='0;
        repeat(5) @(negedge s_clk);
        assert(s_rst && m_rst && !rsp.r_valid && !rsp.b_valid) else $fatal(1,"reset did not isolate channels");
        reset_async=0;
        repeat(5) @(negedge s_clk);
        assert(m_rst) else $fatal(1,"stopped domain released reset");
        enable_m=1;
        wait(!m_rst && !s_rst);
        repeat(8) @(negedge s_clk);
        assert(!rsp.r_valid && !rsp.b_valid) else $fatal(1,"reset retained old response");
    endtask
    initial begin
        repeat(4) @(negedge s_clk);reset_async=0;
        wait(!s_rst && !m_rst);
        offer_ar(1,4);
        wait(rsp.r_valid);
        // 读响应被反压，另有尚未配对的 W；共同复位必须同时丢弃这些 owner。
        @(negedge s_clk);req.w_valid=1;req.w='{data:'1,strb:'1,last:1};
        do @(posedge s_clk);while(!rsp.w_ready);
        @(negedge s_clk);req.w_valid=0;
        reset_while_stopped();
        for(int n=0;n<20;n++) begin offer_ar(n%4,3);receive_r(n%4,3);end
        @(negedge s_clk);req.aw_valid=1;req.aw='{id:3,addr:32'hdead0000,len:1,size:5,burst:1,default:'0};
        do @(posedge s_clk);while(!rsp.aw_ready);
        @(negedge s_clk);req.aw_valid=0;
        for(int n=0;n<2;n++) begin
            req.w_valid=1;req.w='{data:256'(n),strb:'1,last:n==1};
            do @(posedge s_clk);while(!rsp.w_ready);
            @(negedge s_clk);req.w_valid=0;
        end
        while(!rsp.b_valid) @(negedge s_clk);
        repeat(5) @(negedge s_clk);
        assert(rsp.b.id==3 && rsp.b.resp==AXI_DECERR) else $fatal(1,"reset left stale write owner");
        req.b_ready=1;@(posedge s_clk);@(negedge s_clk);req.b_ready=0;writes++;
        reset_while_stopped();
        offer_ar(2,1);receive_r(2,1);
        $display("PASS tb_soc_cdc depth=%0d reads=%0d writes=%0d coordinated_resets=2 stopped_clock=1",DEPTH,reads,writes);
        $finish;
    end
    initial begin #1ms;$fatal(1,"CDC timeout");end
endmodule
