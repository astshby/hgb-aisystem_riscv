// Module: yolo_demo_io
// Description: Real UART, DMA, AXI CDC, NPU and 1080p video platform with native CPU requests; no RISC-V Core/cache.
module yolo_demo_io (
    input logic clk_sys,clk_ddr,clk_periph,clk_npu,clk_pixel,reset_async,
    input logic cfg_valid,cfg_write,
    output logic cfg_ready,
    input logic [31:0] cfg_addr,cfg_wdata,
    output logic cfg_rsp_valid,
    input logic cfg_rsp_ready,
    output logic [31:0] cfg_rdata,
    output logic [1:0] cfg_error,
    input logic uart_rxd,
    output logic uart_txd,
    output logic video_hs,video_vs,video_de,
    output logic [23:0] video_rgb,
    output logic [31:0] video_frame_sequence,video_front,video_underflow,video_bus_errors,
    output logic i2c_done,i2c_error,
    output logic [7:0] i2c_writes,
    output logic [63:0] ddr_ar,ddr_aw,ddr_r,ddr_w,ddr_b
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import axi_types_pkg::*;
    localparam int DDR_BYTES=128*1024*1024;
    logic [4:0] resets;
    for (genvar domain=0;domain<5;domain++) begin : g_reset
        wire domain_clock=domain==0 ? clk_sys : domain==1 ? clk_ddr :
            domain==2 ? clk_periph : domain==3 ? clk_npu : clk_pixel;
        (* ASYNC_REG="TRUE",PAP_ASYNC_REG=1,syn_allow_retiming=0 *) logic [2:0] reset_q;
        always_ff @(posedge domain_clock or posedge reset_async) begin
            if (reset_async) reset_q<='1;
            else reset_q<={reset_q[1:0],1'b0};
        end
        assign resets[domain]=reset_q[2];
    end
    bus_req_t request;
    bus_rsp_t response;
    logic upper_word_q;
    always_comb begin
        request='0;
        request.addr=xlen_t'(cfg_addr);
        request.write=cfg_write;
        request.size=MEM_WORD;
        request.wdata=xlen_t'(cfg_wdata) << (XLEN==64 && cfg_addr[2] ? 32 : 0);
        request.wstrb=DBUS_BYTES'(4'hf) << (XLEN==64 && cfg_addr[2] ? 4 : 0);
    end
    always_ff @(posedge clk_sys) begin
        if (resets[0]) upper_word_q<=0;
        else if (cfg_valid && cfg_ready) upper_word_q<=cfg_addr[2];
    end
    assign cfg_rdata=32'(response.rdata >> (XLEN==64 && upper_word_q ? 32 : 0));
    assign cfg_error=response.error;
    axi_req_t masters[4],targets[7],memory_req;
    axi_rsp_t master_rsp[4],target_rsp[7],memory_rsp;
    cache_axi_adapter u_native_master (
        .clk(clk_sys),.rst(resets[0]),.req_valid(cfg_valid),.req_ready(cfg_ready),.request,
        .rsp_valid(cfg_rsp_valid),.rsp_ready(cfg_rsp_ready),.response,
        .rd_cmd_valid(1'b0),.rd_cmd_ready(),.rd_cmd('0),.rd_valid(),.rd_ready(1'b1),.rd_data(),
        .wr_cmd_valid(1'b0),.wr_cmd_ready(),.wr_cmd('0),.wr_valid(1'b0),.wr_ready(),.wr_data('0),
        .wr_rsp_valid(),.wr_rsp_ready(1'b1),.wr_rsp(),.axi_req(masters[0]),.axi_rsp(master_rsp[0]));
    assign masters[1]='0;
    axi_system_fabric #(.DDR_BYTES(DDR_BYTES),.NPU_BYTES(65536),.VIDEO_ENABLE(1)) u_fabric (
        .clk(clk_sys),.rst(resets[0]),.m_req(masters),.m_rsp(master_rsp),.s_req(targets),.s_rsp(target_rsp));
    // 无 Core 的协同平台不实例 ROM/TCM/Flash；误访问仍走真实有界 AXI 错误响应。
    for (genvar target=0;target<7;target++) begin : g_error
        if (target==0 || target==1 || target==2 || target==5) begin : g_absent
            axi_error_target u_error (.clk(clk_sys),.rst(resets[0]),.req(targets[target]),.rsp(target_rsp[target]));
        end
    end
    axi_clock_bridge u_ddr_cdc (.s_clk(clk_sys),.s_rst(resets[0]),.m_clk(clk_ddr),.m_rst(resets[1]),
        .s_req(targets[3]),.s_rsp(target_rsp[3]),.m_req(memory_req),.m_rsp(memory_rsp));
    yolo_demo_ddr u_memory (.clk(clk_ddr),.rst(resets[1]),.req(memory_req),.rsp(memory_rsp),
        .ar_count(ddr_ar),.aw_count(ddr_aw),.r_count(ddr_r),.w_count(ddr_w),.b_count(ddr_b));
    npu_axi_target u_npu (.clk_sys,.rst_sys(resets[0]),.clk_npu,.rst_npu(resets[3]),
        .axi_req(targets[6]),.axi_rsp(target_rsp[6]));
    axil_req_t mmio_req,video_req,periph_control_req,periph_req;
    axil_rsp_t mmio_rsp,video_rsp,periph_control_rsp,periph_rsp;
    axi_to_axil u_control (.clk(clk_sys),.rst(resets[0]),.s_req(targets[4]),.s_rsp(target_rsp[4]),
        .m_req(mmio_req),.m_rsp(mmio_rsp));
    axil_video_split u_video_control (.clk(clk_sys),.rst(resets[0]),.s_req(mmio_req),.s_rsp(mmio_rsp),
        .video_req,.video_rsp,.periph_req(periph_control_req),.periph_rsp(periph_control_rsp));
    axil_clock_bridge u_periph_cdc (.s_clk(clk_sys),.s_rst(resets[0]),.m_clk(clk_periph),.m_rst(resets[2]),
        .s_req(periph_control_req),.s_rsp(periph_control_rsp),.m_req(periph_req),.m_rsp(periph_rsp));
    logic dma_req_valid,dma_req_ready,dma_rsp_valid,dma_rsp_ready,dma_irq;
    bus_req_t dma_request,flash_request;
    bus_rsp_t dma_response,flash_response;
    logic flash_req_valid,flash_req_ready,flash_rsp_valid,flash_rsp_ready;
    logic [1:0] uart_rx,uart_tx;
    logic [31:0] gpio_in[3],gpio_out[3],gpio_oe[3];
    for (genvar pin=0;pin<3;pin++) begin : g_gpio
        assign gpio_in[pin]='0;
    end
    assign uart_rx={1'b1,uart_rxd};
    assign uart_txd=uart_tx[0];
    // 本平台由电脑执行 C，无 CPU Cache；维护命令即时完成，发现位明确报无 D$。
    mmio_bus #(.DDR_BYTES(DDR_BYTES),.NPU_BYTES(65536),.DCACHE_ENABLE(0),.DCACHE_BYTES(0),
        .CLOCK_HZ(90000000),.CLOCK_INFO_ENABLE(1),.CORE_CLOCK_HZ(90000000),
        .SYS_CLOCK_HZ(100000000),.DDR_CLOCK_HZ(125000000),.PERIPH_CLOCK_HZ(60000000),
        .UART_DIVISOR(521)) u_peripherals (
        .clk(clk_periph),.rst(resets[2]),.ddr_ready(1'b1),.axi_req(periph_req),.axi_rsp(periph_rsp),
        .uart_rx,.uart_tx,.gpio_in,.gpio_out,.gpio_oe,.irq_software(),.irq_timer(),.irq_external(),
        .cache_command_valid(),.cache_command(),.cache_command_ready(1'b1),.cache_busy(1'b0),
        .cache_fatal(1'b0),.cache_error(cache_pkg::CACHE_OK),.cache_fault_addr('0),
        .dma_req_valid,.dma_req_ready,.dma_request,.dma_rsp_valid,.dma_rsp_ready,.dma_response,.dma_irq,
        .flash_req_valid,.flash_req_ready,.flash_request,.flash_rsp_valid,.flash_rsp_ready,.flash_response);
    dma_command_cdc #(.DDR_BYTES(DDR_BYTES),.NPU_ENABLE(1)) u_dma (
        .clk_sys,.rst_sys(resets[0]),.clk_periph,.rst_periph(resets[2]),
        .req_valid(dma_req_valid),.req_ready(dma_req_ready),.request(dma_request),
        .rsp_valid(dma_rsp_valid),.rsp_ready(dma_rsp_ready),.response(dma_response),.irq(dma_irq),
        .axi_req(masters[2]),.axi_rsp(master_rsp[2]));
    bus_error_slave u_flash_error (.clk(clk_periph),.rst(resets[2]),.req_valid(flash_req_valid),
        .req_ready(flash_req_ready),.req_error(BUS_DECERR),.rsp_valid(flash_rsp_valid),
        .rsp_ready(flash_rsp_ready),.response(flash_response));
    logic scl,sda_drive_low,sda_in,hdmi_reset_n,slave_error;
    int writes_checked,reads_checked,repeated_starts;
    // 板级等待缩短为600周期，仅用于协同运行；400kHz真实SDA事务及完整49项表保留。
    yolo_video #(.I2C_RESET_CYCLES(600),.I2C_SETTLE_CYCLES(600)) u_video (
        .clk_sys,.rst_sys(resets[0]),.clk_periph,.rst_periph(resets[2]),.clk_pixel,.rst_pixel(resets[4]),
        .control_req(video_req),.control_rsp(video_rsp),.memory_req(masters[3]),.memory_rsp(master_rsp[3]),
        .hdmi_sda_in(sda_in),.hdmi_scl(scl),.hdmi_sda_drive_low(sda_drive_low),.hdmi_reset_n,
        .video_hs,.video_vs,.video_de,.video_rgb);
    ms7210_i2c_model u_hdmi (.scl,.master_drive_low(sda_drive_low),.rst(resets[2]),
        .nack_budget(8'd0),.force_bad_read(1'b0),.sda_in,.writes_checked,.reads_checked,.repeated_starts,.model_error(slave_error));
    // 以下仅导出只读观测量；CPU功能仍通过真实MMIO读取，像素CRC由C++采样输出引脚。
    assign video_frame_sequence=u_video.frame_count_sys;
    assign video_front=u_video.front_sys_q;
    assign video_underflow=u_video.underflow_sys;
    assign video_bus_errors=u_video.bus_errors;
    assign i2c_done=u_video.init_done;
    assign i2c_error=u_video.init_error || slave_error;
    assign i2c_writes=u_video.init_writes;
    assert property (@(posedge clk_sys) disable iff(resets[0])
        cfg_rsp_valid && !cfg_rsp_ready |=> cfg_rsp_valid && $stable({cfg_rdata,cfg_error}));
endmodule

// Module: yolo_demo_ddr
// Description: Behavioral DDR slave behind the real AXI CDC; a shared lazy C++ allocation owns all memory bytes.
module yolo_demo_ddr (
    input logic clk,rst,
    input axi_types_pkg::axi_req_t req,
    output axi_types_pkg::axi_rsp_t rsp,
    output logic [63:0] ar_count,aw_count,r_count,w_count,b_count
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    import "DPI-C" function void yolo_demo_ddr_read(input int unsigned address,output bit [255:0] value);
    import "DPI-C" function void yolo_demo_ddr_write(input int unsigned address,input bit [255:0] value,input int unsigned mask);
    axi_a_t read_head,read_q,write_q;
    logic read_valid,read_ready,read_active_q,write_active_q,r_valid_q,b_valid_q;
    logic [7:0] read_beat_q,write_beat_q;
    logic [2:0] delay_q;
    logic [31:0] random_q;
    bit [255:0] read_data;
    axi_r_t read_response_q;
    axi_b_t write_response_q;
    rv_fifo #(.WIDTH($bits(axi_a_t)),.DEPTH(8)) u_read_commands (
        .clk,.rst,.in_valid(req.ar_valid),.in_ready(rsp.ar_ready),.in_data(req.ar),
        .out_valid(read_valid),.out_ready(read_ready),.out_data(read_head),.occupancy());
    assign read_ready=!read_active_q;
    always_comb begin
        rsp.aw_ready=!rst && !write_active_q && !b_valid_q && |random_q[2:0];
        rsp.w_ready=!rst && write_active_q && !b_valid_q && |random_q[5:3];
        rsp.b_valid=b_valid_q;
        rsp.b=write_response_q;
        rsp.r_valid=r_valid_q;
        rsp.r=read_response_q;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            read_active_q<=0;write_active_q<=0;r_valid_q<=0;b_valid_q<=0;
            read_beat_q<=0;write_beat_q<=0;delay_q<=0;random_q<=32'h8d41c732;
            ar_count<=0;aw_count<=0;r_count<=0;w_count<=0;b_count<=0;
        end else begin
            random_q<={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if (req.ar_valid && rsp.ar_ready) ar_count<=ar_count+1'b1;
            if (read_valid && read_ready) begin
                read_q<=read_head;read_active_q<=1;read_beat_q<=0;delay_q<=3'(1+random_q[1:0]);
            end
            if (read_active_q && !r_valid_q) begin
                if (delay_q!=0) delay_q<=delay_q-1'b1;
                else begin
                    yolo_demo_ddr_read((read_q.addr+(32'(read_beat_q)<<read_q.size)) & 32'hffffffe0,read_data);
                    read_response_q<='{id:read_q.id,data:read_data,resp:AXI_OKAY,last:read_beat_q==read_q.len};
                    r_valid_q<=1;
                end
            end
            if (r_valid_q && req.r_ready) begin
                r_count<=r_count+1'b1;r_valid_q<=0;
                if (read_response_q.last) read_active_q<=0;
                else begin read_beat_q<=read_beat_q+1'b1;delay_q<=0;end
            end
            if (req.aw_valid && rsp.aw_ready) begin
                aw_count<=aw_count+1'b1;write_q<=req.aw;write_beat_q<=0;write_active_q<=1;
            end
            if (req.w_valid && rsp.w_ready) begin
                w_count<=w_count+1'b1;
                yolo_demo_ddr_write((write_q.addr+(32'(write_beat_q)<<write_q.size)) & 32'hffffffe0,req.w.data,req.w.strb);
                assert (req.w.last==(write_beat_q==write_q.len)) else $fatal(1,"DDR WLAST mismatch");
                if (write_beat_q==write_q.len) begin
                    write_active_q<=0;b_valid_q<=1;write_response_q<='{id:write_q.id,resp:AXI_OKAY};
                end else write_beat_q<=write_beat_q+1'b1;
            end
            if (b_valid_q && req.b_ready) begin b_valid_q<=0;b_count<=b_count+1'b1;end
        end
    end
    assert property (@(posedge clk) disable iff(rst) rsp.r_valid && !req.r_ready |=>
        rsp.r_valid && $stable(rsp.r));
    assert property (@(posedge clk) disable iff(rst) rsp.b_valid && !req.b_ready |=>
        rsp.b_valid && $stable(rsp.b));
endmodule
