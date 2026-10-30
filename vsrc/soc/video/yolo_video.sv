// Module: yolo_video
// Description: SYS AXI framebuffer scanning, atomic vblank commits and MS7210 output preparation in separate clock domains.
module yolo_video #(
    parameter logic [31:0] BASE=32'h10070000,
    parameter int FIFO_DEPTH=2048,
    parameter int PERIPH_HZ=60000000,
    parameter int I2C_RESET_CYCLES=PERIPH_HZ/1000,
    parameter int I2C_SETTLE_CYCLES=(PERIPH_HZ/100)*32
) (
    input logic clk_sys, rst_sys, clk_periph, rst_periph, clk_pixel, rst_pixel,
    input axi_types_pkg::axil_req_t control_req,
    output axi_types_pkg::axil_rsp_t control_rsp,
    output axi_types_pkg::axi_req_t memory_req,
    input axi_types_pkg::axi_rsp_t memory_rsp,
    input logic hdmi_sda_in,
    output logic hdmi_scl, hdmi_sda_drive_low, hdmi_reset_n,
    output logic video_hs, video_vs, video_de,
    output logic [23:0] video_rgb
);
    import axi_types_pkg::*;
    import bus_types_pkg::*;
    localparam logic [31:0] FRAME_A=32'h83000000, FRAME_B=32'h83800000;
    logic req_valid,req_ready,rsp_valid,rsp_ready,access_fire,access_error;
    bus_req_t request;
    bus_rsp_t response;
    logic [31:0] read_data,write_data,write_mask;
    axil_to_bus u_control_bus (.clk(clk_sys),.rst(rst_sys),.axi_req(control_req),.axi_rsp(control_rsp),
        .req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response);
    mmio_endpoint u_endpoint (.clk(clk_sys),.rst(rst_sys),.req_valid,.req_ready,.request,.rsp_valid,.rsp_ready,.response,
        .read_data,.access_error,.access_fire,.write_data,.write_mask);
    logic [31:0] shadow_base_q,width_q,height_q,stride_q,front_sys_q;
    logic enable_q,pending_q,front_enable_sys_q,commit_fire;
    logic cfg_in_ready,cfg_out_valid,cfg_out_ready;
    logic [32:0] cfg_data;
    logic ack_in_valid,ack_in_ready,ack_out_valid;
    logic [32:0] ack_data,ack_out_data;
    logic [31:0] frame_count_sys,underflow_sys,bus_errors,clear_underflow_q,clear_bus_q;
    logic init_done,init_error,reader_running;
    logic [7:0] init_retries,init_writes;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic init_done_s1_q,init_done_s2_q,init_error_s1_q,init_error_s2_q;
    (* syn_preserve=1, syn_allow_retiming=0 *) logic [7:0] retry_gray_q,write_gray_q;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic [7:0] retry_s1_q,retry_s2_q,write_s1_q,write_s2_q;
    function automatic logic [31:0] gray32(input logic [31:0] value);
        logic [31:0] decoded;
        decoded[31]=value[31];
        for (int i=30;i>=0;i--) decoded[i]=decoded[i+1]^value[i];
        return decoded;
    endfunction
    function automatic logic [7:0] gray8(input logic [7:0] value);
        logic [7:0] decoded;
        decoded[7]=value[7];
        for (int i=6;i>=0;i--) decoded[i]=decoded[i+1]^value[i];
        return decoded;
    endfunction
    always_comb begin
        read_data=0; access_error=request.addr[31:12]!=BASE[31:12] || request.write;
        unique case (request.addr[11:0])
            12'h000: read_data=32'h56494431;
            12'h004: read_data={25'b0,bus_errors!=clear_bus_q,underflow_sys!=clear_underflow_q,
                init_error_s2_q,init_done_s2_q,front_enable_sys_q && init_done_s2_q,pending_q,enable_q};
            12'h008: begin read_data=shadow_base_q; access_error=0; end
            12'h00c: begin read_data=width_q; access_error=0; end
            12'h010: begin read_data=height_q; access_error=0; end
            12'h014: begin read_data=stride_q; access_error=0; end
            12'h018: begin
                access_error=request.write && ((|(write_data & write_mask & ~32'd1)) ||
                    (write_data[0] && write_mask[0] && (pending_q || !cfg_in_ready ||
                     (shadow_base_q!=FRAME_A && shadow_base_q!=FRAME_B) || width_q!=1920 || height_q!=1080 || stride_q!=7680)));
            end
            12'h01c: begin read_data={31'b0,enable_q}; access_error=request.write && |(write_data & write_mask & ~32'd3); end
            12'h020: read_data=front_sys_q;
            12'h024: read_data=frame_count_sys;
            12'h028: read_data=underflow_sys-clear_underflow_q;
            12'h02c: read_data={8'b0,gray8(write_s2_q),gray8(retry_s2_q),6'b0,init_error_s2_q,init_done_s2_q};
            12'h030: read_data=bus_errors-clear_bus_q;
            default: access_error=1;
        endcase
        if (request.addr[31:12]!=BASE[31:12]) access_error=1;
    end
    assign commit_fire=access_fire && request.write && request.addr[11:0]==12'h018 && write_mask[0] && write_data[0];
    async_fifo #(.WIDTH(33),.DEPTH(4)) u_config (
        .s_clk(clk_sys),.s_rst(rst_sys),.m_clk(clk_pixel),.m_rst(rst_pixel),
        .in_valid(commit_fire),.in_ready(cfg_in_ready),.in_data({enable_q,shadow_base_q}),
        .out_valid(cfg_out_valid),.out_ready(cfg_out_ready),.out_data(cfg_data));
    async_fifo #(.WIDTH(33),.DEPTH(4)) u_commit_ack (
        .s_clk(clk_pixel),.s_rst(rst_pixel),.m_clk(clk_sys),.m_rst(rst_sys),
        .in_valid(ack_in_valid),.in_ready(ack_in_ready),.in_data(ack_data),
        .out_valid(ack_out_valid),.out_ready(1'b1),.out_data(ack_out_data));
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            shadow_base_q<=FRAME_A; width_q<=1920; height_q<=1080; stride_q<=7680;
            enable_q<=0; pending_q<=0; front_sys_q<=0; front_enable_sys_q<=0;
            clear_underflow_q<=0; clear_bus_q<=0;
            init_done_s1_q<=0;init_done_s2_q<=0;init_error_s1_q<=0;init_error_s2_q<=0;
            retry_s1_q<=0;retry_s2_q<=0;write_s1_q<=0;write_s2_q<=0;
        end else begin
            init_done_s1_q<=init_done;init_done_s2_q<=init_done_s1_q;
            init_error_s1_q<=init_error;init_error_s2_q<=init_error_s1_q;
            retry_s1_q<=retry_gray_q;retry_s2_q<=retry_s1_q;write_s1_q<=write_gray_q;write_s2_q<=write_s1_q;
            if (access_fire && request.write) begin
                unique case (request.addr[11:0])
                    12'h008: shadow_base_q<=(shadow_base_q&~write_mask)|(write_data&write_mask);
                    12'h00c: width_q<=(width_q&~write_mask)|(write_data&write_mask);
                    12'h010: height_q<=(height_q&~write_mask)|(write_data&write_mask);
                    12'h014: stride_q<=(stride_q&~write_mask)|(write_data&write_mask);
                    12'h01c: begin
                        if (write_mask[0]) enable_q<=write_data[0];
                        // 清除的是SYS已观察的计数基线，不跨域把多位Gray计数器清零。
                        if (write_mask[1] && write_data[1]) begin clear_underflow_q<=underflow_sys;clear_bus_q<=bus_errors; end
                    end
                    default: ;
                endcase
            end
            if (commit_fire) pending_q<=1;
            if (ack_out_valid) begin front_sys_q<=ack_out_data[31:0];front_enable_sys_q<=ack_out_data[32];pending_q<=0;end
        end
    end
    ms7210_init #(.PERIPH_HZ(PERIPH_HZ),.I2C_HZ(400000),.RESET_CYCLES(I2C_RESET_CYCLES),.SETTLE_CYCLES(I2C_SETTLE_CYCLES)) u_hdmi_init (
        .clk(clk_periph),.rst(rst_periph),.sda_in(hdmi_sda_in),.scl(hdmi_scl),.sda_drive_low(hdmi_sda_drive_low),
        .reset_n(hdmi_reset_n),.done(init_done),.error(init_error),.retries(init_retries),.writes_done(init_writes));
    always_ff @(posedge clk_periph) begin
        if (rst_periph) begin retry_gray_q<=0;write_gray_q<=0;end
        else begin retry_gray_q<=(init_retries>>1)^init_retries;write_gray_q<=(init_writes>>1)^init_writes;end
    end

    logic timing_hs,timing_vs,timing_de,timing_start;
    logic [11:0] timing_x;
    logic [10:0] timing_y;
    video_timing u_timing (.clk(clk_pixel),.rst(rst_pixel),.hs(timing_hs),.vs(timing_vs),.de(timing_de),
        .frame_start(timing_start),.x(timing_x),.y(timing_y));
    logic pixel_pending_q,pixel_enable_q;
    logic [32:0] pixel_config_q;
    logic [31:0] pixel_base_q,chosen_base;
    logic chosen_enable,apply_config;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic init_pixel1_q,init_pixel2_q;
    logic frame_in_valid,frame_in_ready,frame_out_valid,frame_out_ready;
    logic [39:0] frame_out_data;
    logic [7:0] epoch_q;
    logic pair_in_valid,pair_in_ready,pair_out_valid,pair_out_ready;
    logic [72:0] pair_in_data,pair_out_data;
    logic frame_bad_q,tag_ok;
    logic [63:0] pixels_q;
    logic [31:0] frame_count_q,underflow_q;
    (* syn_preserve=1,syn_allow_retiming=0 *) logic [31:0] frame_gray_q,underflow_gray_q;
    (* ASYNC_REG="TRUE", PAP_ASYNC_REG=1, syn_allow_retiming=0 *) logic [31:0] frame_s1_q,frame_s2_q,underflow_s1_q,underflow_s2_q;
    assign frame_count_sys=gray32(frame_s2_q);
    assign underflow_sys=gray32(underflow_s2_q);
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin frame_s1_q<=0;frame_s2_q<=0;underflow_s1_q<=0;underflow_s2_q<=0;end
        else begin frame_s1_q<=frame_gray_q;frame_s2_q<=frame_s1_q;underflow_s1_q<=underflow_gray_q;underflow_s2_q<=underflow_s1_q;end
    end
    assign cfg_out_ready=!pixel_pending_q;
    assign apply_config=timing_start && pixel_pending_q && ack_in_ready;
    assign ack_in_valid=timing_start && pixel_pending_q;
    assign ack_data=pixel_config_q;
    assign chosen_base=apply_config ? pixel_config_q[31:0] : pixel_base_q;
    assign chosen_enable=apply_config ? pixel_config_q[32] : pixel_enable_q;
    assign frame_in_valid=timing_start && chosen_enable && init_pixel2_q;
    async_fifo #(.WIDTH(40),.DEPTH(4)) u_frame_command (
        .s_clk(clk_pixel),.s_rst(rst_pixel),.m_clk(clk_sys),.m_rst(rst_sys),
        .in_valid(frame_in_valid),.in_ready(frame_in_ready),.in_data({epoch_q+8'd1,chosen_base}),
        .out_valid(frame_out_valid),.out_ready(frame_out_ready),.out_data(frame_out_data));
    video_frame_reader u_reader (.clk(clk_sys),.rst(rst_sys),
        .frame_valid(frame_out_valid),.frame_ready(frame_out_ready),.frame_base(frame_out_data[31:0]),.frame_epoch(frame_out_data[39:32]),
        .memory_req,.memory_rsp,.pair_valid(pair_in_valid),.pair_ready(pair_in_ready),.pair_data(pair_in_data),
        .running(reader_running),.bus_errors);
    video_pair_fifo #(.DEPTH(FIFO_DEPTH)) u_pixels (
        .s_clk(clk_sys),.s_rst(rst_sys),.m_clk(clk_pixel),.m_rst(rst_pixel),
        .in_valid(pair_in_valid),.in_ready(pair_in_ready),.in_data(pair_in_data),
        .out_valid(pair_out_valid),.out_ready(pair_out_ready),.out_data(pair_out_data));
    assign tag_ok=pair_out_data[72:65]==epoch_q && pair_out_data[64]==(timing_x==0 && timing_y==0);
    always_comb begin
        pair_out_ready=0;
        if (!pixel_enable_q || !init_pixel2_q || frame_bad_q) pair_out_ready=1;
        else if (timing_de) pair_out_ready=!timing_x[0] && pair_out_valid && tag_ok;
        // 行消隐必须保留下一行已预取的像素；仅在垂直消隐清理旧帧尾部。
        else if (timing_y>=1080) pair_out_ready=pair_out_valid && !(pair_out_data[72:65]==epoch_q && pair_out_data[64]);
    end
    always_ff @(posedge clk_pixel) begin
        if (rst_pixel) begin
            pixel_pending_q<=0;pixel_enable_q<=0;pixel_config_q<=0;pixel_base_q<=0;
            init_pixel1_q<=0;init_pixel2_q<=0;epoch_q<=0;frame_bad_q<=1;
            frame_count_q<=0;underflow_q<=0;frame_gray_q<=0;underflow_gray_q<=0;
            video_hs<=0;video_vs<=0;video_de<=0;video_rgb<=0;
        end else begin
            init_pixel1_q<=init_done;init_pixel2_q<=init_pixel1_q;
            video_hs<=timing_hs;video_vs<=timing_vs;video_de<=timing_de;video_rgb<=0;
            if (cfg_out_valid && cfg_out_ready) begin pixel_config_q<=cfg_data;pixel_pending_q<=1;end
            if (apply_config) begin pixel_base_q<=pixel_config_q[31:0];pixel_enable_q<=pixel_config_q[32];pixel_pending_q<=0;end
            if (timing_start) begin
                epoch_q<=epoch_q+1'b1;frame_count_q<=frame_count_q+1'b1;
                frame_gray_q<=((frame_count_q+1)>>1)^(frame_count_q+1);
                frame_bad_q<=!chosen_enable || !init_pixel2_q || !frame_in_ready;
                if (chosen_enable && init_pixel2_q && !frame_in_ready) begin
                    underflow_q<=underflow_q+1'b1;underflow_gray_q<=((underflow_q+1)>>1)^(underflow_q+1);
                end
            end
            if (timing_de && pixel_enable_q && init_pixel2_q && !frame_bad_q) begin
                if (!timing_x[0]) begin
                    if (pair_out_valid && tag_ok) begin pixels_q<=pair_out_data[63:0];video_rgb<=pair_out_data[23:0];end
                    else begin
                        frame_bad_q<=1;underflow_q<=underflow_q+1'b1;
                        underflow_gray_q<=((underflow_q+1)>>1)^(underflow_q+1);
                    end
                end else video_rgb<=pixels_q[55:32];
            end
        end
    end
endmodule
