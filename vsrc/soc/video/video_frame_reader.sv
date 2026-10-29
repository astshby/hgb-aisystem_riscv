// Module: video_frame_reader
// Description: Four-ID read-only AXI DMA; four-beat reorder slots feed ordered 64-bit pixel pairs.
module video_frame_reader #(
    parameter int FRAME_BYTES = 1920*1080*4
) (
    input logic clk, rst,
    input logic frame_valid,
    output logic frame_ready,
    input logic [31:0] frame_base,
    input logic [7:0] frame_epoch,
    output axi_types_pkg::axi_req_t memory_req,
    input axi_types_pkg::axi_rsp_t memory_rsp,
    output logic pair_valid,
    input logic pair_ready,
    output logic [72:0] pair_data,
    output logic running,
    output logic [31:0] bus_errors
);
    import axi_types_pkg::*;
    logic [255:0] payload [4][4];
    logic [3:0] busy_q, done_q;
    logic [3:0] valid_q [4];
    logic [2:0] received_q [4];
    logic active_q, abort_q, pending_q, ar_valid_q;
    logic [31:0] base_q, pending_base_q, issued_q, pairs_q, ar_addr_q;
    logic [7:0] epoch_q, pending_epoch_q;
    logic [1:0] allocate_q, drain_q, beat_q, chunk_q, ar_id_q;
    logic frame_fire, ar_fire, r_fire, pair_fire, dropping, receive_legal;
    logic [1:0] response_id;
    assign frame_ready=!rst;
    assign frame_fire=frame_valid && frame_ready;
    assign dropping=abort_q || frame_fire;
    assign response_id=memory_rsp.r.id[1:0];
    assign receive_legal=busy_q[response_id] && !done_q[response_id] && received_q[response_id]<4 && memory_rsp.r.id[3:2]==0;
    assign ar_fire=memory_req.ar_valid && memory_rsp.ar_ready;
    assign r_fire=memory_rsp.r_valid && memory_req.r_ready;
    assign pair_valid=active_q && !dropping && busy_q[drain_q] && valid_q[drain_q][beat_q];
    assign pair_data={epoch_q,pairs_q==0,64'(payload[drain_q][beat_q]>>(64*int'(chunk_q)))};
    assign pair_fire=pair_valid && pair_ready;
    assign running=active_q || |busy_q || ar_valid_q;
    always_comb begin
        memory_req='0;
        memory_req.ar_valid=ar_valid_q;
        memory_req.ar='{id:axi_id_t'(ar_id_q),addr:ar_addr_q,len:8'd3,size:3'd5,
            burst:2'b01,lock:1'b0,cache:4'b0,prot:3'b0,qos:4'd8};
        // 每个ID独立保留整个4拍响应，读回顺序由drain_q确定；不把目标响应顺序当成AXI保证。
        memory_req.r_ready=!rst;
        memory_req.b_ready=!rst;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q<='0; done_q<='0; active_q<=0; abort_q<=0; pending_q<=0; ar_valid_q<=0;
            base_q<=0; pending_base_q<=0; issued_q<=0; pairs_q<=0; ar_addr_q<=0; epoch_q<=0; pending_epoch_q<=0;
            allocate_q<=0; drain_q<=0; beat_q<=0; chunk_q<=0; ar_id_q<=0; bus_errors<=0;
            for (int slot=0;slot<4;slot++) begin valid_q[slot]<='0; received_q[slot]<=0; end
        end else begin
            if (frame_fire) begin
                pending_base_q<=frame_base; pending_epoch_q<=frame_epoch;
                pending_q<=1; abort_q<=1; active_q<=0;
            end
            // 新帧不能撤回已经置valid的AR；旧请求接受后仍须收完响应，再开始新帧。
            if (!ar_valid_q && active_q && !dropping && !busy_q[allocate_q] && issued_q<FRAME_BYTES) begin
                ar_valid_q<=1; ar_addr_q<=base_q+issued_q; ar_id_q<=allocate_q;
            end
            if (ar_fire) begin
                ar_valid_q<=0; busy_q[ar_id_q]<=1; done_q[ar_id_q]<=0;
                valid_q[ar_id_q]<='0; received_q[ar_id_q]<=0;
                issued_q<=issued_q+128; allocate_q<=allocate_q+1'b1;
            end
            if ((r_fire && (!receive_legal || memory_rsp.r.resp!=AXI_OKAY ||
                 memory_rsp.r.last!=(received_q[response_id]==3))) || memory_rsp.b_valid)
                bus_errors<=bus_errors+1'b1;
            if (r_fire && receive_legal) begin
                received_q[response_id]<=received_q[response_id]+1'b1;
                if (!dropping) begin
                    payload[response_id][received_q[response_id][1:0]]<=memory_rsp.r.resp==AXI_OKAY ? memory_rsp.r.data : '0;
                    valid_q[response_id][received_q[response_id][1:0]]<=1;
                end
                if (memory_rsp.r.last || received_q[response_id]==3) begin
                    done_q[response_id]<=1;
                    if (dropping) busy_q[response_id]<=0;
                end
            end
            if (dropping) begin
                for (int slot=0;slot<4;slot++) begin
                    valid_q[slot]<='0;
                    if (done_q[slot]) busy_q[slot]<=0;
                end
            end else if (pair_fire) begin
                pairs_q<=pairs_q+1'b1;
                if (chunk_q==3) begin
                    chunk_q<=0; valid_q[drain_q][beat_q]<=0;
                    if (beat_q==3) begin
                        beat_q<=0; busy_q[drain_q]<=0; done_q[drain_q]<=0; drain_q<=drain_q+1'b1;
                    end else beat_q<=beat_q+1'b1;
                end else chunk_q<=chunk_q+1'b1;
                if (pairs_q==FRAME_BYTES/8-1) active_q<=0;
            end
            if (pending_q && !frame_fire && busy_q==0 && !ar_valid_q) begin
                base_q<=pending_base_q; epoch_q<=pending_epoch_q; pending_q<=0;
                active_q<=1; abort_q<=0; issued_q<=0; pairs_q<=0;
                allocate_q<=0; drain_q<=0; beat_q<=0; chunk_q<=0;
                done_q<=0;
                for (int slot=0;slot<4;slot++) begin valid_q[slot]<=0;received_q[slot]<=0;end
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (FRAME_BYTES%128==0) else $fatal(1,"video frame must contain complete 128B bursts");
    assert property (@(posedge clk) disable iff(rst) memory_req.ar_valid && !memory_rsp.ar_ready |=>
        rst || (memory_req.ar_valid && $stable(memory_req.ar)));
    assert property (@(posedge clk) disable iff(rst) memory_req.ar_valid |->
        memory_req.ar.addr[6:0]==0 && memory_req.ar.addr[11:0]<=12'hf80 && memory_req.ar.len==3);
`endif
endmodule
