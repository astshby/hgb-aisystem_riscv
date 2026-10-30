// Module: tb_video
// Description: True 1080p frames through randomized/reordered AXI reads, AXI-Lite ownership and the actual MS7210 initialization.
module tb_video #(
    parameter real SYS_PERIOD_NS=10.0,
    parameter real PERIPH_PERIOD_NS=1000.0/60.0,
    parameter int PERIPH_HZ=60000000
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    localparam logic [31:0] A=32'h83000000,B=32'h83800000,V=32'h10070000;
    logic clk_sys=0,clk_periph=0,clk_pixel=0,reset_async=1;
    logic rst_sys,rst_periph,rst_pixel;
    initial begin
        realtime origin=0; longint unsigned edge_count=0;
        forever begin edge_count++; #(origin+real'(edge_count)*SYS_PERIOD_NS/2.0-$realtime);clk_sys=~clk_sys;end
    end
    initial begin
        realtime origin=1.7ns; longint unsigned edge_count=0;
        #1.7ns;
        forever begin edge_count++; #(origin+real'(edge_count)*(PERIPH_PERIOD_NS/2.0)-$realtime);clk_periph=~clk_periph;end
    end
    initial begin
        realtime origin=2.3ns; longint unsigned edge_count=0;
        #2.3ns;
        forever begin edge_count++; #(origin+real'(edge_count)*(1s/297000000.0)-$realtime);clk_pixel=~clk_pixel;end
    end
    for (genvar domain=0;domain<3;domain++) begin : g_reset
        wire domain_clk=domain==0 ? clk_sys : domain==1 ? clk_periph : clk_pixel;
        (* ASYNC_REG="TRUE",PAP_ASYNC_REG=1 *) logic [2:0] reset_q;
        always_ff @(posedge domain_clk or posedge reset_async) begin
            if (reset_async) reset_q<='1;else reset_q<={reset_q[1:0],1'b0};
        end
        if (domain==0) assign rst_sys=reset_q[2];
        else if (domain==1) assign rst_periph=reset_q[2];
        else assign rst_pixel=reset_q[2];
    end
    axil_req_t cpu_req,video_req,periph_req;
    axil_rsp_t cpu_rsp,video_rsp,periph_rsp;
    axi_req_t memory_req;
    axi_rsp_t memory_rsp;
    logic scl,drive_low,sda_in,hdmi_reset_n,hs,vs,de;
    logic [23:0] rgb;
    axil_video_split u_split (.clk(clk_sys),.rst(rst_sys),.s_req(cpu_req),.s_rsp(cpu_rsp),
        .video_req,.video_rsp,.periph_req,.periph_rsp);
    yolo_video #(.PERIPH_HZ(PERIPH_HZ),.I2C_RESET_CYCLES(600),.I2C_SETTLE_CYCLES(600)) dut (
        .clk_sys,.rst_sys,.clk_periph,.rst_periph,.clk_pixel,.rst_pixel,
        .control_req(video_req),.control_rsp(video_rsp),.memory_req,.memory_rsp,
        .hdmi_sda_in(sda_in),.hdmi_scl(scl),.hdmi_sda_drive_low(drive_low),.hdmi_reset_n,
        .video_hs(hs),.video_vs(vs),.video_de(de),.video_rgb(rgb));
    int writes_checked,reads_checked;
    logic i2c_model_error;
    ms7210_i2c_model u_i2c_model (.scl,.master_drive_low(drive_low),.rst(rst_periph),.nack_budget(8'd1),
        .force_bad_read(1'b0),.sda_in,.writes_checked,.reads_checked,.model_error(i2c_model_error),.repeated_starts());

    logic peripheral_aw_q=0,peripheral_w_q=0,peripheral_b_q=0,peripheral_r_q=0;
    logic [63:0] peripheral_data_q;
    always_comb begin
        periph_rsp='0;
        periph_rsp.aw_ready=!peripheral_aw_q && !peripheral_b_q;
        periph_rsp.w_ready=!peripheral_w_q && !peripheral_b_q;
        periph_rsp.b_valid=peripheral_b_q;periph_rsp.b=AXI_OKAY;
        periph_rsp.ar_ready=!peripheral_r_q;periph_rsp.r_valid=peripheral_r_q;
        periph_rsp.r='{data:64'hfedcba9876543210,resp:AXI_OKAY};
    end
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin peripheral_aw_q<=0;peripheral_w_q<=0;peripheral_b_q<=0;peripheral_r_q<=0;end
        else begin
            if (periph_req.aw_valid && periph_rsp.aw_ready) peripheral_aw_q<=1;
            if (periph_req.w_valid && periph_rsp.w_ready) begin peripheral_w_q<=1;peripheral_data_q<=periph_req.w.data;end
            if (peripheral_aw_q && peripheral_w_q) begin peripheral_aw_q<=0;peripheral_w_q<=0;peripheral_b_q<=1;end
            if (periph_rsp.b_valid && periph_req.b_ready) peripheral_b_q<=0;
            if (periph_req.ar_valid && periph_rsp.ar_ready) peripheral_r_q<=1;
            if (periph_rsp.r_valid && periph_req.r_ready) peripheral_r_q<=0;
        end
    end
    logic pause_memory=0,inject_bus_error=0,bus_error_injected=0;
    logic [31:0] random_q=32'hc7042026;
    logic [3:0] requests_q=0;
    logic [31:0] addresses_q [4];
    longint unsigned sequence_q [4];
    logic [1:0] beats_q [4];
    logic r_valid_q=0;
    axi_r_t r_q;
    int selected,oldest;
    longint unsigned burst_count=0,reordered=0,stalled_ar_seen=0,aborted_frames=0,paused_vblanks=0;
    function automatic logic [23:0] pixel(input logic [31:0] base,input int x,input int y);
        if (base==A) return {8'(x+32),8'(y+64),8'(x^y^8'h81)};
        return {8'(x+113),8'(y+27),8'(x+y+19)};
    endfunction
    function automatic logic [255:0] data_beat(input logic [31:0] address);
        logic [255:0] value;logic [31:0] base;int index;
        base=address>=B ? B : A;index=int'((address-base)>>2);
        for (int word=0;word<8;word++) value[word*32+:32]={8'b0,pixel(base,(index+word)%1920,(index+word)/1920)};
        return value;
    endfunction
    always_comb begin
        memory_rsp='0;
        memory_rsp.ar_ready=!rst_sys && !pause_memory && random_q[3:0]!=0 && !requests_q[memory_req.ar.id[1:0]];
        memory_rsp.r_valid=r_valid_q;memory_rsp.r=r_q;
        selected=-1;oldest=-1;
        for (int id=0;id<4;id++)
            if(requests_q[id] && (oldest<0 || sequence_q[id]<sequence_q[oldest])) oldest=id;
        for (int attempt=0;attempt<4;attempt++)
            if (selected<0 && requests_q[(int'(random_q[7:6])+attempt)%4]) selected=(int'(random_q[7:6])+attempt)%4;
    end
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin requests_q<=0;r_valid_q<=0;random_q<=32'hc7042026;burst_count<=0;reordered<=0;bus_error_injected<=0;end
        else begin
            random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if (memory_req.ar_valid && memory_rsp.ar_ready) begin
                assert(memory_req.ar.len==3 && memory_req.ar.size==5 && memory_req.ar.addr[6:0]==0 && memory_req.ar.addr[11:0]<=12'hf80)
                    else $fatal(1,"illegal video burst");
                assert((memory_req.ar.addr>=A && memory_req.ar.addr<A+8294400) || (memory_req.ar.addr>=B && memory_req.ar.addr<B+8294400))
                    else $fatal(1,"frame range");
                requests_q[memory_req.ar.id[1:0]]<=1;addresses_q[memory_req.ar.id[1:0]]<=memory_req.ar.addr;
                sequence_q[memory_req.ar.id[1:0]]<=burst_count;
                beats_q[memory_req.ar.id[1:0]]<=0;burst_count<=burst_count+1;
            end
            if (r_valid_q && memory_req.r_ready) begin
                r_valid_q<=0;
                if (r_q.last) requests_q[r_q.id[1:0]]<=0;
                else beats_q[r_q.id[1:0]]<=beats_q[r_q.id[1:0]]+1'b1;
            end
            if (!r_valid_q && !pause_memory && selected>=0 && random_q[2:0]!=0) begin
                r_valid_q<=1;
                r_q<='{id:axi_id_t'(selected),data:data_beat(addresses_q[selected]+32'(beats_q[selected])*32),
                    resp:inject_bus_error && !bus_error_injected ? AXI_SLVERR : AXI_OKAY,last:beats_q[selected]==3};
                if(inject_bus_error && !bus_error_injected) bus_error_injected<=1;
                if (selected!=oldest) reordered<=reordered+1;
            end
            if (pause_memory && memory_req.ar_valid && !memory_rsp.ar_ready) stalled_ar_seen<=stalled_ar_seen+1;
            if (dut.u_reader.frame_valid && dut.u_reader.frame_ready && (|dut.u_reader.busy_q || dut.u_reader.ar_valid_q))
                aborted_frames<=aborted_frames+1;
            for(int id=0;id<4;id++)
                assert(!requests_q[id] || dut.u_reader.busy_q[id]) else $fatal(1,"accepted read owner released before RLAST id=%0d",id);
        end
    end
    task automatic write_reg(input logic [31:0] address,input logic [31:0] value,input bit w_first,input axi_resp_e expected=AXI_OKAY);
        axil_w_t data;
        data='{data:64'(value)<<(address[2]?32:0),strb:8'h0f<<(address[2]?4:0)};
        @(negedge clk_sys);cpu_req.b_ready=0;
        if (w_first) begin
            cpu_req.w=data;cpu_req.w_valid=1;
            do @(posedge clk_sys);while(!cpu_rsp.w_ready);
            @(negedge clk_sys);cpu_req.w_valid=0;
            repeat(2) @(negedge clk_sys);
            cpu_req.aw='{addr:address,prot:0};cpu_req.aw_valid=1;
            do @(posedge clk_sys);while(!cpu_rsp.aw_ready);
            @(negedge clk_sys);cpu_req.aw_valid=0;
        end else begin
            cpu_req.aw='{addr:address,prot:0};cpu_req.aw_valid=1;
            do @(posedge clk_sys);while(!cpu_rsp.aw_ready);
            @(negedge clk_sys);cpu_req.aw_valid=0;
            repeat(2) @(negedge clk_sys);
            cpu_req.w=data;cpu_req.w_valid=1;
            do @(posedge clk_sys);while(!cpu_rsp.w_ready);
            @(negedge clk_sys);cpu_req.w_valid=0;
        end
        while(!cpu_rsp.b_valid) @(negedge clk_sys);
        repeat(3) begin @(negedge clk_sys);assert(cpu_rsp.b_valid && cpu_rsp.b==expected) else $fatal(1,"B ownership/response");end
        cpu_req.b_ready=1;@(posedge clk_sys);@(negedge clk_sys);cpu_req.b_ready=0;
    endtask
    task automatic read_reg(input logic [31:0] address,output logic [31:0] value);
        logic [63:0] saved;
        @(negedge clk_sys);cpu_req.r_ready=0;cpu_req.ar='{addr:address,prot:0};cpu_req.ar_valid=1;
        do @(posedge clk_sys);while(!cpu_rsp.ar_ready);
        @(negedge clk_sys);cpu_req.ar_valid=0;
        while(!cpu_rsp.r_valid) @(negedge clk_sys);
        saved=cpu_rsp.r.data;
        repeat(3) begin @(negedge clk_sys);assert(cpu_rsp.r_valid && cpu_rsp.r.resp==AXI_OKAY && cpu_rsp.r.data==saved) else $fatal(1,"R backpressure");end
        value=32'(saved>>(address[2]?32:0));cpu_req.r_ready=1;@(posedge clk_sys);@(negedge clk_sys);cpu_req.r_ready=0;
    endtask
    logic [31:0] table_crc [256];
    function automatic logic [31:0] add_rgb(input logic [31:0] old,input logic [23:0] color);
        logic [31:0] next;
        next=old;
        for (int c=2;c>=0;c--) next=table_crc[(next^32'(color[c*8+:8]))&255]^(next>>8);
        return next;
    endfunction
    logic previous_vs=0,tracked=0,fault_phase=0;
    logic [31:0] tracked_base=0,actual_crc=32'hffffffff,expected_crc=32'hffffffff;
    int px=0,py=0,active_pixels=0,healthy_a=0,healthy_b=0,recovered=0,total_frames=0,black_fault_pixels=0;
    always @(negedge clk_pixel) if (!rst_pixel) begin
        if (vs && !previous_vs) begin
            if(pause_memory) paused_vblanks++;
            if (tracked) begin
                assert(active_pixels==1920*1080 && px==0 && py==1080) else $fatal(1,"1080p geometry %0d/%0d/%0d",active_pixels,px,py);
                if (!fault_phase) begin
                    assert(actual_crc==expected_crc) else $fatal(1,"frame CRC base=%h actual=%h expected=%h",tracked_base,actual_crc^32'hffffffff,expected_crc^32'hffffffff);
                    if(tracked_base==A) healthy_a++;else if(tracked_base==B) healthy_b++;
                    if(underflow_observed && tracked_base==B) recovered++;
                    $display("VIDEO_FRAME base=%08h pixels=%0d crc=%08h",tracked_base,active_pixels,actual_crc^32'hffffffff);
                end
                total_frames++;
            end
            tracked=dut.pixel_enable_q && dut.init_pixel2_q;
            tracked_base=dut.pixel_base_q;actual_crc=32'hffffffff;expected_crc=32'hffffffff;px=0;py=0;active_pixels=0;
        end
        previous_vs=vs;
        if (tracked && de) begin
            if (!fault_phase) assert(rgb==pixel(tracked_base,px,py)) else $fatal(1,"pixel %0d,%0d got=%h expected=%h",px,py,rgb,pixel(tracked_base,px,py));
            if (fault_phase && dut.frame_bad_q) begin
                assert(rgb==0) else $fatal(1,"underrun frame must remain black");black_fault_pixels++;
            end
            actual_crc=add_rgb(actual_crc,rgb);expected_crc=add_rgb(expected_crc,pixel(tracked_base,px,py));active_pixels++;
            if (px==1919) begin px=0;py++;end else px++;
        end
    end
    logic underflow_observed=0;
    initial begin
        logic [31:0] value;
        cpu_req='0;
        for (int i=0;i<256;i++) begin
            logic [31:0] c; c=32'(i);
            for(int bit_index=0;bit_index<8;bit_index++) c=(c>>1)^(c[0]?32'hedb88320:0);
            table_crc[i]=c;
        end
        repeat(8) @(negedge clk_sys);reset_async=0;wait(!rst_sys);
        read_reg(V,value);assert(value==32'h56494431) else $fatal(1,"video ID");
        read_reg(32'h10000000,value);assert(value==32'h76543210) else $fatal(1,"peripheral low lane");
        read_reg(32'h10000004,value);assert(value==32'hfedcba98) else $fatal(1,"peripheral high lane");
        write_reg(32'h10000000,32'h12345678,1);assert(peripheral_data_q[31:0]==32'h12345678) else $fatal(1,"peripheral write route");
        write_reg(V+8,32'h83000004,0);write_reg(V+24,1,1,AXI_SLVERR);
        write_reg(V+8,A,1);write_reg(V+12,1919,0);read_reg(V+12,value);assert(value==1919) else $fatal(1,"high word lane");
        write_reg(V+24,1,0,AXI_SLVERR);write_reg(V+12,1920,1);
        do begin read_reg(V+44,value);repeat(1000) @(negedge clk_sys);end while(!value[0]);
        assert(!value[1] && writes_checked>=49 && reads_checked>=1 && !i2c_model_error) else $fatal(1,"MS7210 init");
        write_reg(V+28,1,0);write_reg(V+24,1,1);write_reg(V+24,1,0,AXI_SLVERR);
        read_reg(V+4,value);assert(value[1:0]==2'b11) else $fatal(1,"pending/status high lane");
        do begin read_reg(V+32,value);repeat(1000) @(negedge clk_sys);end while(value!=A);
        wait(healthy_a>=1);
        write_reg(V+8,B,0);write_reg(V+24,1,1);
        do begin read_reg(V+32,value);repeat(1000) @(negedge clk_sys);end while(value!=B);
        wait(healthy_b>=1);
        @(negedge clk_pixel);fault_phase=1;
        wait(de && dut.timing_y==1000);@(negedge clk_pixel);pause_memory=1;
        wait(vs);repeat(10000) @(negedge clk_pixel);pause_memory=0;
        read_reg(V+40,value);assert(value>0) else $fatal(1,"underrun not counted");underflow_observed=1;
        // 故障帧保持黑直到下个vblank；恢复后再从完整帧边界开始校验，不把半帧当成通过。
        wait(vs);wait(!vs);wait(vs);@(negedge clk_pixel);#1ps;fault_phase=0;
        wait(recovered>=1);
        read_reg(V+48,value);assert(value==0) else $fatal(1,"unexpected AXI response error");
        @(negedge clk_pixel);fault_phase=1;inject_bus_error=1;
        wait(bus_error_injected);repeat(20) @(negedge clk_sys);read_reg(V+48,value);
        assert(value>0 && black_fault_pixels>0) else $fatal(1,"AXI error/black-frame coverage");
        write_reg(V+28,3,1);repeat(10) @(negedge clk_sys);read_reg(V+40,value);assert(value==0) else $fatal(1,"clear underrun baseline");
        read_reg(V+48,value);assert(value==0) else $fatal(1,"clear bus error baseline");
        assert(reordered>0 && burst_count>64800*2 && stalled_ar_seen>0 && aborted_frames>0 && paused_vblanks>0)
            else $fatal(1,"AXI reorder/abort/vblank coverage");
        $display("PASS video 1920x1080 AXIL%0d frames=%0d A=%0d B=%0d recovered=%0d bursts=%0d reordered=%0d init_writes=%0d stalled_ar=%0d aborts=%0d paused_vblanks=%0d black_pixels=%0d",core_config_pkg::XLEN,total_frames,healthy_a,healthy_b,recovered,burst_count,reordered,writes_checked,stalled_ar_seen,aborted_frames,paused_vblanks,black_fault_pixels);
        $finish;
    end
    assert property (@(posedge clk_pixel) disable iff(rst_pixel)
        $changed(dut.pixel_base_q) |-> $past(dut.timing_start));
    initial begin #200ms;$fatal(1,"video timeout");end
endmodule
