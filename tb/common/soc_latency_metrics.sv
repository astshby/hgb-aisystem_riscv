// Module: soc_latency_metrics, soc_axi_latency_metrics, soc_cache_latency_metrics
// Description: Simulation-only fire-associated latency accounting with per-ID FIFO ownership and ROI cohorts.
`ifndef SOC_LATENCY_METRICS_SV
`define SOC_LATENCY_METRICS_SV
// Package: soc_metrics_pkg
// Description: Simulation-clock conversion shared by platform injection and directed tests.
package soc_metrics_pkg;
    timeunit 1ns;
    timeprecision 1ps;
    function automatic int unsigned clock_period_ps(input realtime half_period);
        // 十进制 ns 不能总被二进制浮点精确表示；量化到实际仿真使用的最近整数 ps。
        return int'($rtoi(2.0*half_period/1ps+0.5));
    endfunction
endpackage
module soc_latency_metrics #(
    parameter string NAME = "transaction",
    parameter string DOMAIN = "core",
    parameter int ID_W = 1,
    parameter int DEPTH = 4,
    parameter bit RESPONSE_UNITS = 0
) (
    input logic clk, rst, enable, roi,
    input logic start_fire,
    input logic [ID_W-1:0] start_id,
    input logic [31:0] start_units,
    input logic response_fire, response_last,
    input logic [ID_W-1:0] response_id,
    input logic [31:0] response_units,
    input logic request_stall, response_stall
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int IDS = 1 << ID_W;
    // 同 ID 按接受顺序排队，不同 ID 可交错返回；反压期间不改变归属。
    longint unsigned issued_at[IDS][DEPTH];
    logic origin_roi[IDS][DEPTH], first_seen[IDS][DEPTH];
    logic [31:0] units[IDS][DEPTH];
    int head[IDS], tail[IDS], count[IDS];
    longint unsigned tick=0, active=0, peak_active=0;
    longint unsigned started=0, completed=0, first_responses=0;
    longint unsigned roi_started=0, roi_completed=0, roi_first_responses=0;
    longint unsigned roi_carry_in=0, roi_carry_out=0, roi_completed_from_before=0;
    longint unsigned roi_started_completed=0, roi_started_completed_after=0;
    longint unsigned latency_sum=0, first_latency_sum=0, latency_max=0, first_latency_max=0;
    longint unsigned roi_latency_sum=0, roi_first_latency_sum=0, roi_latency_max=0;
    longint unsigned cohort_latency_sum=0;
    longint unsigned busy_cycles=0, roi_busy_cycles=0, roi_cycles=0;
    longint unsigned request_stall_cycles=0, response_stall_cycles=0;
    longint unsigned roi_request_stall_cycles=0, roi_response_stall_cycles=0;
    longint unsigned accepted_units=0, completed_units=0, roi_accepted_units=0, roi_completed_units=0;
    logic roi_q=0;

    task automatic consume_response;
        int id, slot;
        longint unsigned elapsed, finished_units;
        id=int'(response_id);
        assert(count[id]>0) else $fatal(1,"LATENCY %s unmatched response id=%0d",NAME,id);
        slot=head[id]; elapsed=tick-issued_at[id][slot];
        if (!first_seen[id][slot]) begin
            first_seen[id][slot]=1;
            first_responses++; first_latency_sum+=elapsed;
            if (elapsed>first_latency_max) first_latency_max=elapsed;
            if (roi) begin roi_first_responses++; roi_first_latency_sum+=elapsed; end
        end
        if (response_last) begin
            completed++; latency_sum+=elapsed;
            if (elapsed>latency_max) latency_max=elapsed;
            finished_units=RESPONSE_UNITS ? 64'(response_units) : 64'(units[id][slot]);
            completed_units+=finished_units;
            if (roi) begin
                roi_completed++; roi_latency_sum+=elapsed; roi_completed_units+=finished_units;
                if (elapsed>roi_latency_max) roi_latency_max=elapsed;
                if (!origin_roi[id][slot]) roi_completed_from_before++;
            end
            if (origin_roi[id][slot]) begin
                roi_started_completed++; cohort_latency_sum+=elapsed;
                if (!roi) roi_started_completed_after++;
            end
            head[id]=(head[id]+1)%DEPTH; count[id]--; active--;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            tick=0; active=0; peak_active=0; roi_q=0;
            started=0; completed=0; first_responses=0;
            roi_started=0; roi_completed=0; roi_first_responses=0;
            roi_carry_in=0; roi_carry_out=0; roi_completed_from_before=0;
            roi_started_completed=0; roi_started_completed_after=0;
            latency_sum=0; first_latency_sum=0; latency_max=0; first_latency_max=0;
            roi_latency_sum=0; roi_first_latency_sum=0; roi_latency_max=0; cohort_latency_sum=0;
            busy_cycles=0; roi_busy_cycles=0; roi_cycles=0;
            request_stall_cycles=0; response_stall_cycles=0;
            roi_request_stall_cycles=0; roi_response_stall_cycles=0;
            accepted_units=0; completed_units=0; roi_accepted_units=0; roi_completed_units=0;
            for (int id=0;id<IDS;id++) begin head[id]=0; tail[id]=0; count[id]=0; end
        end else if (enable) begin
            // 边界取本沿事件之前的未完成集合；本沿 fire 按本沿 roi 归属。
            if (roi && !roi_q) roi_carry_in+=active;
            if (!roi && roi_q) roi_carry_out+=active;
            roi_q=roi;
            if (active!=0) busy_cycles++;
            if (request_stall) request_stall_cycles++;
            if (response_stall) response_stall_cycles++;
            if (roi) begin
                roi_cycles++;
                if (active!=0) roi_busy_cycles++;
                if (request_stall) roi_request_stall_cycles++;
                if (response_stall) roi_response_stall_cycles++;
            end
            // 先关闭旧响应，再接纳同 ID 新请求；零拍请求/响应也允许。
            if (response_fire && count[int'(response_id)]>0) begin
                consume_response();
                if (start_fire) begin
                    assert(count[int'(start_id)]<DEPTH) else $fatal(1,"LATENCY %s ID FIFO overflow",NAME);
                    issued_at[int'(start_id)][tail[int'(start_id)]]=tick;
                    origin_roi[int'(start_id)][tail[int'(start_id)]]=roi;
                    first_seen[int'(start_id)][tail[int'(start_id)]]=0;
                    units[int'(start_id)][tail[int'(start_id)]]=start_units;
                    tail[int'(start_id)]=(tail[int'(start_id)]+1)%DEPTH;
                    count[int'(start_id)]++; active++; started++; accepted_units+=64'(start_units);
                    if (roi) begin roi_started++; roi_accepted_units+=64'(start_units); end
                end
            end else begin
                if (start_fire) begin
                    assert(count[int'(start_id)]<DEPTH) else $fatal(1,"LATENCY %s ID FIFO overflow",NAME);
                    issued_at[int'(start_id)][tail[int'(start_id)]]=tick;
                    origin_roi[int'(start_id)][tail[int'(start_id)]]=roi;
                    first_seen[int'(start_id)][tail[int'(start_id)]]=0;
                    units[int'(start_id)][tail[int'(start_id)]]=start_units;
                    tail[int'(start_id)]=(tail[int'(start_id)]+1)%DEPTH;
                    count[int'(start_id)]++; active++; started++; accepted_units+=64'(start_units);
                    if (roi) begin roi_started++; roi_accepted_units+=64'(start_units); end
                end
                if (response_fire) consume_response();
            end
            if (active>peak_active) peak_active=active;
            tick++;
        end
    end
    final if (enable) begin
        $display("P2_LATENCY name=%s domain=%s started=%0d completed=%0d pending=%0d peak_pending=%0d first_count=%0d first_sum=%0d first_max=%0d last_sum=%0d last_max=%0d busy_cycles=%0d request_stall=%0d response_stall=%0d roi_cycles=%0d roi_started=%0d roi_completed=%0d roi_first_count=%0d roi_first_sum=%0d roi_last_sum=%0d roi_last_max=%0d roi_busy_cycles=%0d roi_request_stall=%0d roi_response_stall=%0d roi_carry_in=%0d roi_carry_out=%0d roi_completed_from_before=%0d roi_started_completed=%0d roi_started_completed_after=%0d cohort_last_sum=%0d accepted_units=%0d completed_units=%0d roi_accepted_units=%0d roi_completed_units=%0d",
            NAME,DOMAIN,started,completed,active,peak_active,first_responses,first_latency_sum,first_latency_max,
            latency_sum,latency_max,busy_cycles,request_stall_cycles,response_stall_cycles,roi_cycles,
            roi_started,roi_completed,roi_first_responses,roi_first_latency_sum,roi_latency_sum,roi_latency_max,
            roi_busy_cycles,roi_request_stall_cycles,roi_response_stall_cycles,roi_carry_in,roi_carry_out,
            roi_completed_from_before,roi_started_completed,roi_started_completed_after,cohort_latency_sum,
            accepted_units,completed_units,roi_accepted_units,roi_completed_units);
    end
endmodule

// Module: soc_axi_write_metrics
// Description: Bounded ordered AW/W join distinguishes write-source gaps from downstream backpressure.
module soc_axi_write_metrics #(
    parameter string NAME="axi",
    parameter string DOMAIN="sys",
    parameter int DEPTH=16
) (
    input logic clk, rst, enable, roi,
    input axi_types_pkg::axi_req_t req,
    input axi_types_pkg::axi_rsp_t rsp
);
    timeunit 1ns;
    timeprecision 1ps;
    // AXI4 的 W 没有 ID，按 AW 次序归属；允许 W 先于 AW 到达，不能把它误报成无主数据。
    bit aw_seen[DEPTH], w_seen[DEPTH], w_done[DEPTH];
    longint unsigned aw_at[DEPTH], first_at[DEPTH], last_at[DEPTH];
    int unsigned expected_beats[DEPTH], seen_beats[DEPTH];
    longint unsigned cycle=0, accepted=0, completed=0, wbursts=0, peak_pending=0;
    longint unsigned active_cycles=0, source_gap_cycles=0, downstream_stall_cycles=0, transfer_cycles=0;
    longint unsigned first_sum=0, first_max=0, gap_count=0, gap_sum=0, gap_max=0, before_aw=0;
    longint unsigned roi_accepted=0, roi_completed=0, roi_active_cycles=0, roi_source_gap_cycles=0;
    longint unsigned roi_downstream_stall_cycles=0, roi_transfer_cycles=0;
    longint unsigned roi_first_sum=0, roi_first_max=0, roi_gap_count=0, roi_gap_sum=0, roi_gap_max=0, roi_before_aw=0;
    longint unsigned interval_gap, first_delay;
    int aw_slot, w_slot, join_slot;
    bit active;
    always @(posedge clk) begin
        if (rst) begin
            cycle=0; accepted=0; completed=0; wbursts=0; peak_pending=0;
            active_cycles=0; source_gap_cycles=0; downstream_stall_cycles=0; transfer_cycles=0;
            first_sum=0; first_max=0; gap_count=0; gap_sum=0; gap_max=0; before_aw=0;
            roi_accepted=0; roi_completed=0; roi_active_cycles=0; roi_source_gap_cycles=0;
            roi_downstream_stall_cycles=0; roi_transfer_cycles=0;
            roi_first_sum=0; roi_first_max=0; roi_gap_count=0; roi_gap_sum=0; roi_gap_max=0; roi_before_aw=0;
            for (int slot=0;slot<DEPTH;slot++) begin
                aw_seen[slot]=0; w_seen[slot]=0; w_done[slot]=0; seen_beats[slot]=0;
                expected_beats[slot]=0; aw_at[slot]=0; first_at[slot]=0; last_at[slot]=0;
            end
        end else if (enable) begin
            aw_slot=int'(accepted%64'(DEPTH)); w_slot=int'(wbursts%64'(DEPTH));
            if (req.aw_valid&&rsp.aw_ready) begin
                assert(accepted-completed<64'(DEPTH)&&!aw_seen[aw_slot])
                    else $fatal(1,"%s AW/W join overflow on AW",NAME);
                aw_seen[aw_slot]=1; aw_at[aw_slot]=cycle;
                expected_beats[aw_slot]=int'(req.aw.len)+1;
                accepted++; if(roi) roi_accepted++;
            end
            // 活跃窗口从 AW 接受到对应 WLAST；已有提前 WLAST 的事务不产生缺供拍。
            active=aw_seen[w_slot]&&!w_done[w_slot];
            if(active) begin
                active_cycles++; if(roi) roi_active_cycles++;
                if(!req.w_valid) begin source_gap_cycles++; if(roi) roi_source_gap_cycles++; end
                else if(!rsp.w_ready) begin downstream_stall_cycles++; if(roi) roi_downstream_stall_cycles++; end
                else begin transfer_cycles++; if(roi) roi_transfer_cycles++; end
            end
            if(req.w_valid&&rsp.w_ready) begin
                assert(wbursts-completed<64'(DEPTH)&&!w_done[w_slot])
                    else $fatal(1,"%s AW/W join overflow on W",NAME);
                if(!w_seen[w_slot]) begin w_seen[w_slot]=1; first_at[w_slot]=cycle; end
                else begin
                    interval_gap=cycle-last_at[w_slot]-1;
                    gap_count++; gap_sum+=interval_gap; if(interval_gap>gap_max) gap_max=interval_gap;
                    if(roi) begin roi_gap_count++; roi_gap_sum+=interval_gap; if(interval_gap>roi_gap_max) roi_gap_max=interval_gap; end
                end
                last_at[w_slot]=cycle; seen_beats[w_slot]++;
                if(req.w.last) begin w_done[w_slot]=1; wbursts++; end
            end
            // first 延迟按 AW/WLAST 配对完成窗统计；拍间 gap 按后一拍接受时的 ROI 统计。
            // 只保存 DEPTH 个事务，不随仿真运行时间增长；该观测器没有输出驱动 DUT。
            join_slot=int'(completed%64'(DEPTH));
            if(aw_seen[join_slot]&&w_done[join_slot]) begin
                assert(seen_beats[join_slot]==expected_beats[join_slot])
                    else $fatal(1,"%s WLAST/length mismatch expected=%0d observed=%0d",NAME,expected_beats[join_slot],seen_beats[join_slot]);
                first_delay=first_at[join_slot]>=aw_at[join_slot] ? first_at[join_slot]-aw_at[join_slot] : 0;
                first_sum+=first_delay; if(first_delay>first_max) first_max=first_delay;
                if(first_at[join_slot]<aw_at[join_slot]) before_aw++;
                completed++;
                if(roi) begin
                    roi_completed++; roi_first_sum+=first_delay;
                    if(first_delay>roi_first_max) roi_first_max=first_delay;
                    if(first_at[join_slot]<aw_at[join_slot]) roi_before_aw++;
                end
                aw_seen[join_slot]=0; w_seen[join_slot]=0; w_done[join_slot]=0; seen_beats[join_slot]=0;
            end
            if(accepted-completed>peak_pending) peak_pending=accepted-completed;
            cycle++;
        end
    end
    final if(enable) $display("P2_AXI_W name=%s domain=%s accepted=%0d completed=%0d pending=%0d wbursts=%0d peak_pending=%0d active_cycles=%0d source_gap_cycles=%0d downstream_stall_cycles=%0d transfer_cycles=%0d first_sum=%0d first_max=%0d gap_count=%0d gap_sum=%0d gap_max=%0d before_aw=%0d roi_accepted=%0d roi_completed=%0d roi_active_cycles=%0d roi_source_gap_cycles=%0d roi_downstream_stall_cycles=%0d roi_transfer_cycles=%0d roi_first_sum=%0d roi_first_max=%0d roi_gap_count=%0d roi_gap_sum=%0d roi_gap_max=%0d roi_before_aw=%0d",
        NAME,DOMAIN,accepted,completed,accepted-completed,wbursts,peak_pending,active_cycles,source_gap_cycles,downstream_stall_cycles,transfer_cycles,
        first_sum,first_max,gap_count,gap_sum,gap_max,before_aw,roi_accepted,roi_completed,roi_active_cycles,roi_source_gap_cycles,
        roi_downstream_stall_cycles,roi_transfer_cycles,roi_first_sum,roi_first_max,roi_gap_count,roi_gap_sum,roi_gap_max,roi_before_aw);
endmodule

// Module: soc_axi_latency_metrics
// Description: Measures AR-to-first/last-R and AW-to-B at one AXI boundary, in that boundary's clock cycles.
module soc_axi_latency_metrics #(
    parameter string NAME="axi",
    parameter string DOMAIN="sys"
) (
    input logic clk, rst, enable, roi,
    input axi_types_pkg::axi_req_t req,
    input axi_types_pkg::axi_rsp_t rsp
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    longint unsigned rbeats=0, wbeats=0, wbytes=0, roi_rbeats=0, roi_wbeats=0, roi_wbytes=0;
    soc_axi_write_metrics #(.NAME(NAME),.DOMAIN(DOMAIN)) u_w_channel(.clk,.rst,.enable,.roi,.req,.rsp);
    // 等待期间必须保持有效位和载荷；统计不把 valid 当作重复接受。
    assert property (@(posedge clk) disable iff(rst||!enable)
        req.ar_valid&&!rsp.ar_ready |=> req.ar_valid&&$stable(req.ar));
    assert property (@(posedge clk) disable iff(rst||!enable)
        req.aw_valid&&!rsp.aw_ready |=> req.aw_valid&&$stable(req.aw));
    assert property (@(posedge clk) disable iff(rst||!enable)
        req.w_valid&&!rsp.w_ready |=> req.w_valid&&$stable(req.w));
    assert property (@(posedge clk) disable iff(rst||!enable)
        rsp.r_valid&&!req.r_ready |=> rsp.r_valid&&$stable(rsp.r));
    assert property (@(posedge clk) disable iff(rst||!enable)
        rsp.b_valid&&!req.b_ready |=> rsp.b_valid&&$stable(rsp.b));
    soc_latency_metrics #(.NAME({NAME,".read"}),.DOMAIN(DOMAIN),.ID_W(AXI_ID_W),.DEPTH(16)) u_read (
        .clk,.rst,.enable,.roi,.start_fire(req.ar_valid&&rsp.ar_ready),.start_id(req.ar.id),
        .start_units((32'(req.ar.len)+1)<<req.ar.size),
        .response_fire(rsp.r_valid&&req.r_ready),.response_last(rsp.r.last),.response_id(rsp.r.id),.response_units(32'b0),
        .request_stall(req.ar_valid&&!rsp.ar_ready),.response_stall(rsp.r_valid&&!req.r_ready));
    soc_latency_metrics #(.NAME({NAME,".write"}),.DOMAIN(DOMAIN),.ID_W(AXI_ID_W),.DEPTH(16)) u_write (
        .clk,.rst,.enable,.roi,.start_fire(req.aw_valid&&rsp.aw_ready),.start_id(req.aw.id),
        .start_units((32'(req.aw.len)+1)<<req.aw.size),
        .response_fire(rsp.b_valid&&req.b_ready),.response_last(1'b1),.response_id(rsp.b.id),.response_units(32'b0),
        .request_stall(req.aw_valid&&!rsp.aw_ready),.response_stall(rsp.b_valid&&!req.b_ready));
    always @(posedge clk) begin
        if (rst) begin rbeats=0; wbeats=0; wbytes=0; roi_rbeats=0; roi_wbeats=0; roi_wbytes=0; end
        else if (enable) begin
            if (rsp.r_valid&&req.r_ready) begin rbeats++; if (roi) roi_rbeats++; end
            if (req.w_valid&&rsp.w_ready) begin
                wbeats++; wbytes+=64'($countones(req.w.strb));
                if (roi) begin roi_wbeats++; roi_wbytes+=64'($countones(req.w.strb)); end
            end
        end
    end
    final if (enable) $display("P2_AXI name=%s domain=%s rbeats=%0d wbeats=%0d wbytes=%0d roi_rbeats=%0d roi_wbeats=%0d roi_wbytes=%0d",
        NAME,DOMAIN,rbeats,wbeats,wbytes,roi_rbeats,roi_wbeats,roi_wbytes);
endmodule

// Module: soc_cache_latency_metrics
// Description: Counts lookup decisions and separates refill service from accepted-last-beat to install completion.
module soc_cache_latency_metrics #(
    parameter string NAME="cache"
) (
    input logic clk, rst, enable, roi,
    input logic hit, miss, install,
    input logic refill_start, refill_done, refill_last_beat,
    input logic refill_request_stall, refill_response_stall,
    input logic install_write
);
    timeunit 1ns;
    timeprecision 1ps;
    longint unsigned hits=0, misses=0, installs=0, writes=0;
    longint unsigned roi_hits=0, roi_misses=0, roi_installs=0, roi_writes=0;
    logic tail_active=0;
    soc_latency_metrics #(.NAME({NAME,".refill"})) u_refill (
        .clk,.rst,.enable,.roi,.start_fire(refill_start),.start_id(1'b0),.start_units(32'b0),
        .response_fire(refill_done),.response_last(1'b1),.response_id(1'b0),.response_units(32'b0),
        .request_stall(refill_request_stall),.response_stall(refill_response_stall));
    soc_latency_metrics #(.NAME({NAME,".install_tail"})) u_tail (
        .clk,.rst,.enable,.roi,.start_fire(refill_last_beat),.start_id(1'b0),.start_units(32'b0),
        .response_fire(refill_done&&(tail_active||refill_last_beat)),.response_last(1'b1),.response_id(1'b0),.response_units(32'b0),
        .request_stall(1'b0),.response_stall(1'b0));
    always @(posedge clk) begin
        if (rst) begin
            hits=0; misses=0; installs=0; writes=0; roi_hits=0; roi_misses=0; roi_installs=0; roi_writes=0;
            tail_active<=0;
        end else if (enable) begin
            if (refill_last_beat) tail_active<=1;
            if (refill_done) tail_active<=0;
            if (hit) begin hits++; if(roi) roi_hits++; end
            if (miss) begin misses++; if(roi) roi_misses++; end
            if (install) begin installs++; if(roi) roi_installs++; end
            if (install_write) begin writes++; if(roi) roi_writes++; end
        end
    end
    final if(enable) $display("P2_CACHE name=%s hits=%0d misses=%0d installs=%0d install_writes=%0d roi_hits=%0d roi_misses=%0d roi_installs=%0d roi_install_writes=%0d",
        NAME,hits,misses,installs,writes,roi_hits,roi_misses,roi_installs,roi_writes);
endmodule
`endif
