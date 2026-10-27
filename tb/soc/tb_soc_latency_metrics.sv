// Module: tb_soc_latency_metrics
// Description: Independent hand-calculated transaction schedule checks IDs, ROI ownership and backpressure accounting.
`include "tb/common/soc_latency_metrics.sv"
module tb_soc_latency_metrics;
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    logic clk=0, rst=1, roi=0;
    axi_req_t req;
    axi_rsp_t rsp;
    logic cache_hit=0, cache_miss=0, cache_install=0, fill_start=0, fill_done=0, fill_last=0, fill_write=0;
    logic dma_start=0, dma_done=0;
    logic [31:0] dma_requested=0, dma_finished=0;
    axi_req_t wreq;
    axi_rsp_t wrsp;
    logic wroi=0;
    soc_axi_write_metrics #(.NAME("directed.w")) w_metrics(.clk,.rst,.enable(1'b1),.roi(wroi),.req(wreq),.rsp(wrsp));
    always #5ns clk=~clk;
    soc_axi_latency_metrics #(.NAME("directed")) dut(.clk,.rst,.enable(1'b1),.roi,.req,.rsp);
    soc_cache_latency_metrics #(.NAME("directed.cache")) cache_metrics (
        .clk,.rst,.enable(1'b1),.roi,.hit(cache_hit),.miss(cache_miss),.install(cache_install),
        .refill_start(fill_start),.refill_done(fill_done),.refill_last_beat(fill_last),
        .refill_request_stall(1'b0),.refill_response_stall(1'b0),.install_write(fill_write));
    soc_latency_metrics #(.NAME("directed.dma"),.RESPONSE_UNITS(1)) dma_metrics (
        .clk,.rst,.enable(1'b1),.roi,.start_fire(dma_start),.start_id(1'b0),.start_units(dma_requested),
        .response_fire(dma_done),.response_last(1'b1),.response_id(1'b0),.response_units(dma_finished),
        .request_stall(1'b0),.response_stall(1'b0));
    task automatic ar(input int id,input int length,input bit ready=1);
        req.ar_valid=1; req.ar.id=axi_id_t'(id); req.ar.addr=32'h80000000+32'(id*32);
        req.ar.len=8'(length); req.ar.size=5; req.ar.burst=1; rsp.ar_ready=ready;
    endtask
    task automatic read_beat(input int id,input bit last,input bit ready=1);
        rsp.r_valid=1; rsp.r.id=axi_id_t'(id); rsp.r.last=last; rsp.r.data=256'(id);
        req.r_ready=ready;
    endtask
    task automatic aw(input int id);
        req.aw_valid=1; req.aw.id=axi_id_t'(id); req.aw.addr=32'h80001000+32'(id*32);
        req.aw.size=5; req.aw.burst=1; rsp.aw_ready=1;
    endtask
    task automatic b(input int id);
        rsp.b_valid=1; rsp.b.id=axi_id_t'(id); req.b_ready=1;
    endtask
    initial begin
        assert(soc_metrics_pkg::clock_period_ps(5ns)==10000&&
            soc_metrics_pkg::clock_period_ps(20ns)==40000&&
            soc_metrics_pkg::clock_period_ps(12.5ns)==25000&&
            soc_metrics_pkg::clock_period_ps(13.514ns)==27028&&
            soc_metrics_pkg::clock_period_ps(5.882ns)==11764&&
            soc_metrics_pkg::clock_period_ps(4.274ns)==8548&&
            soc_metrics_pkg::clock_period_ps(5.376ns)==10752)
            else $fatal(1,"clock period must round to the simulated integer picosecond period");
        req='0; rsp='0; wreq='0; wrsp='0;
        repeat(2) @(negedge clk);
        rst=0;
        if($test$plusargs("NEG_W_LENGTH")) begin
            wreq.aw_valid=1; wrsp.aw_ready=1; wreq.aw.len=1;
            wreq.w_valid=1; wrsp.w_ready=1; wreq.w.last=1;
            @(negedge clk); $fatal(1,"negative W length not detected");
        end
        if($test$plusargs("NEG_W_AW_OVERFLOW")||$test$plusargs("NEG_W_DATA_OVERFLOW")) begin
            for(int i=0;i<17;i++) begin
                if($test$plusargs("NEG_W_AW_OVERFLOW")) begin wreq.aw_valid=1; wrsp.aw_ready=1; end
                else begin wreq.w_valid=1; wrsp.w_ready=1; wreq.w.last=1; end
                @(negedge clk);
            end
            $fatal(1,"negative W bounded queue overflow not detected");
        end
        if($test$plusargs("NEG_UNMATCHED")) begin
            read_beat(7,1); @(negedge clk); $fatal(1,"negative unmatched response not detected");
        end
        if($test$plusargs("NEG_UNSTABLE")) begin
            ar(1,0,0); @(negedge clk); ar(2,0,1); @(negedge clk);
            $fatal(1,"negative unstable payload not detected");
        end
        if($test$plusargs("NEG_OVERFLOW")) begin
            for(int i=0;i<17;i++) begin ar(1,0); @(negedge clk); end
            $fatal(1,"negative outstanding overflow not detected");
        end
        // 六条读事务的 (接受拍,首拍,末拍)：
        // ID1:(0,3,4),(2,5,5),(4,7,7); ID2:(1,2,2); ID3:(6,6,6); ID4:(9,12,12)。
        // ROI 为拍 1..4；同 ID 队列、不同 ID 乱序、边界同拍 fire 和零拍均有覆盖。
        for(int tick=0;tick<=12;tick++) begin
            req='0; rsp='0; roi=tick>=1&&tick<=4;
            wreq='0; wrsp='0; wroi=tick>=2&&tick<=6;
            // AW 后两个缺供拍、两个反压拍、一次连续传输与一个两拍间隙。
            // 后两事务分别覆盖 WLAST 先于 AW，以及 AW/WLAST 同拍接受。
            if(tick==0) begin wreq.aw_valid=1; wrsp.aw_ready=1; wreq.aw.len=2; end
            if(tick inside {2,3,4,6,7,8,10}) begin
                wreq.w_valid=1; wrsp.w_ready=!(tick inside {2,6});
                wreq.w.last=tick inside {6,7,8,10};
            end
            if(tick==9||tick==10) begin wreq.aw_valid=1; wrsp.aw_ready=1; end
            cache_hit=tick==7; cache_miss=tick==0||tick==6;
            cache_install=tick==4; fill_start=cache_miss; fill_done=tick==4||tick==8;
            fill_last=tick==2; fill_write=tick==3||tick==4;
            dma_start=tick==0||tick==6; dma_done=tick==5||tick==6;
            dma_requested=tick==0 ? 64 : 16; dma_finished=tick==5 ? 32 : 16;
            case(tick)
                0: ar(1,1);
                1: begin ar(2,0); aw(5); req.w_valid=1; rsp.w_ready=1; req.w.last=1; req.w.strb=3; end
                2: begin ar(1,0); read_beat(2,1); aw(5); req.w_valid=1; rsp.w_ready=1; req.w.last=1; req.w.strb='1; end
                3: begin ar(1,0,0); read_beat(1,0); aw(6); b(5); req.w_valid=1; rsp.w_ready=1; req.w.last=1; req.w.strb=15; end
                4: begin ar(1,0); read_beat(1,1); b(6); end
                5: begin read_beat(1,1); b(5); end
                6: begin ar(3,0); read_beat(3,1); end
                7: read_beat(1,1);
                8: ar(4,0,0);
                9: ar(4,0);
                10,11: read_beat(4,1,0);
                12: read_beat(4,1);
                default: ;
            endcase
            @(negedge clk);
        end
        req='0; rsp='0;
        assert(dut.u_read.started==6&&dut.u_read.completed==6&&dut.u_read.active==0&&dut.u_read.peak_active==2)
            else $fatal(1,"read ownership/counts");
        assert(dut.u_read.first_latency_sum==13&&dut.u_read.latency_sum==14&&dut.u_read.latency_max==4&&dut.u_read.busy_cycles==10)
            else $fatal(1,"read elapsed/busy first=%0d last=%0d busy=%0d",dut.u_read.first_latency_sum,dut.u_read.latency_sum,dut.u_read.busy_cycles);
        assert(dut.u_read.roi_started==3&&dut.u_read.roi_completed==2&&dut.u_read.roi_carry_in==1&&dut.u_read.roi_carry_out==2&&
            dut.u_read.roi_completed_from_before==1&&dut.u_read.roi_started_completed==3&&dut.u_read.roi_started_completed_after==2)
            else $fatal(1,"read ROI cohorts");
        assert(dut.u_read.roi_latency_sum==5&&dut.u_read.roi_first_latency_sum==4&&dut.u_read.cohort_latency_sum==7&&dut.u_read.roi_busy_cycles==4)
            else $fatal(1,"read ROI latency/busy");
        assert(dut.u_read.request_stall_cycles==2&&dut.u_read.response_stall_cycles==2&&dut.u_read.accepted_units==224&&dut.u_read.completed_units==224)
            else $fatal(1,"read stalled fires/bytes");
        assert(dut.u_write.started==3&&dut.u_write.completed==3&&dut.u_write.latency_sum==6&&dut.u_write.roi_carry_out==1&&
            dut.u_write.roi_started_completed_after==1&&dut.u_write.busy_cycles==4&&dut.wbytes==38&&dut.roi_wbytes==38)
            else $fatal(1,"write IDs/ROI/strobes");
        assert(cache_metrics.hits==1&&cache_metrics.misses==2&&cache_metrics.installs==1&&cache_metrics.writes==2&&
            cache_metrics.u_refill.completed==2&&cache_metrics.u_refill.latency_sum==6&&
            cache_metrics.u_tail.completed==1&&cache_metrics.u_tail.latency_sum==2)
            else $fatal(1,"cache refill/install/scalar-without-tail accounting");
        assert(dma_metrics.started==2&&dma_metrics.completed==2&&dma_metrics.accepted_units==80&&
            dma_metrics.completed_units==48&&dma_metrics.latency_sum==5&&dma_metrics.roi_carry_in==1&&dma_metrics.roi_carry_out==1)
            else $fatal(1,"DMA actual completion bytes and boundary ownership");
        assert(w_metrics.accepted==3&&w_metrics.completed==3&&w_metrics.wbursts==3&&
            w_metrics.active_cycles==9&&w_metrics.source_gap_cycles==3&&w_metrics.downstream_stall_cycles==2&&
            w_metrics.transfer_cycles==4&&w_metrics.first_sum==3&&w_metrics.first_max==3&&w_metrics.before_aw==1&&
            w_metrics.gap_count==2&&w_metrics.gap_sum==2&&w_metrics.gap_max==2&&
            w_metrics.roi_active_cycles==5&&w_metrics.roi_source_gap_cycles==1&&
            w_metrics.roi_downstream_stall_cycles==2&&w_metrics.roi_transfer_cycles==2&&w_metrics.roi_completed==0&&
            w_metrics.roi_gap_count==1&&w_metrics.roi_gap_sum==0)
            else $fatal(1,"W source gaps/backpressure/early data/ROI accounting");
        $display("PASS soc-latency-metrics RV%0d read_transactions=6 write_transactions=3 same_id_fifo=1 concurrent_ids=1 same_cycle=1 roi_boundaries=1 backpressure=1 clock_period_rounding=1",
            core_config_pkg::XLEN);
        $finish;
    end
endmodule
