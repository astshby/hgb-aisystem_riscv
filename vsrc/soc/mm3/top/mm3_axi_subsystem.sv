// Module: mm3_axi_subsystem
// Description: Independent-clock MiniMind control target and DDR AXI master.
module mm3_axi_subsystem #(
    parameter int unsigned DDR_BYTES = 128*1024*1024,
    parameter int unsigned MAC_LANES = mm3_config_pkg::MM3_GEMV_LANES,
    parameter logic [31:0] BASE = soc_addr_pkg::NPU_SRAM_BASE
) (
    input logic clk_sys, rst_sys, clk_npu, rst_npu,
    input axi_types_pkg::axi_req_t control_req,
    output axi_types_pkg::axi_rsp_t control_rsp,
    output axi_types_pkg::axi_req_t memory_req,
    input axi_types_pkg::axi_rsp_t memory_rsp
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import axi_types_pkg::*;
    axi_req_t local_control, local_memory;
    axi_rsp_t local_control_rsp, local_memory_rsp;
    bus_req_t request;
    bus_rsp_t response, device_response;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    logic legal, device_ready, device_valid, error_valid_q;
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    block_w_t wr_data;
    block_b_t wr_rsp;

    // 控制和数据使用独立 FIFO；反压只占用各自通道，不形成跨域组合 ready 链。
    // 两侧必须由同一个系统复位异步置位，再在各自时钟域同步释放。
    axi_clock_bridge #(.DEPTH(4)) u_control_cdc (
        .s_clk(clk_sys), .s_rst(rst_sys), .m_clk(clk_npu), .m_rst(rst_npu),
        .s_req(control_req), .s_rsp(control_rsp), .m_req(local_control), .m_rsp(local_control_rsp)
    );
    axi_bus_target #(.LOCAL_BYTES(4)) u_control_target (
        .clk(clk_npu), .rst(rst_npu), .axi_req(local_control), .axi_rsp(local_control_rsp),
        .req_valid, .req_ready, .request, .rsp_valid, .rsp_ready, .response
    );
    // 完整地址检查先于低位寄存器译码，窗口之外的访问不能产生设备副作用。
    assign legal = request.addr >= xlen_t'(BASE) &&
        65'(request.addr) < 65'(BASE) + 4096 && !request.execute &&
        request.size == MEM_WORD && request.addr[1:0] == 0;
    assign req_ready = !rst_npu && (legal ? device_ready : !error_valid_q);
    assign rsp_valid = device_valid || error_valid_q;
    assign response = error_valid_q ? bus_rsp_t'{rdata:'0, error:BUS_DECERR} : device_response;
    always_ff @(posedge clk_npu) begin
        if (rst_npu) error_valid_q <= 0;
        else begin
            if (rsp_valid && rsp_ready) error_valid_q <= 0;
            if (req_valid && req_ready) error_valid_q <= !legal;
        end
    end
    mm3_accel #(.DDR_BYTES(DDR_BYTES), .MAC_LANES(MAC_LANES)) u_accel (
        .clk(clk_npu), .rst(rst_npu), .req_valid(req_valid && legal), .req_ready(device_ready),
        .request, .rsp_valid(device_valid), .rsp_ready, .response(device_response),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
    );
    // 复用带 4 KiB 切分的 block 桥；读写各有一个 owner，保持原算子的完成语义。
    assign local_memory.aw.id[AXI_ID_W-1:1] = '0;
    assign local_memory.ar.id[AXI_ID_W-1:1] = '0;
    block_to_axi #(.DDR_BYTES(DDR_BYTES)) u_memory_adapter (
        .clk(clk_npu), .rst(rst_npu),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp,
        .awvalid(local_memory.aw_valid), .awready(local_memory_rsp.aw_ready),
        .awid(local_memory.aw.id[0]), .awaddr(local_memory.aw.addr), .awlen(local_memory.aw.len),
        .awsize(local_memory.aw.size), .awburst(local_memory.aw.burst), .awlock(local_memory.aw.lock),
        .awcache(local_memory.aw.cache), .awqos(local_memory.aw.qos), .awregion(), .awprot(local_memory.aw.prot),
        .wvalid(local_memory.w_valid), .wready(local_memory_rsp.w_ready),
        .wdata(local_memory.w.data), .wstrb(local_memory.w.strb), .wlast(local_memory.w.last),
        .bvalid(local_memory_rsp.b_valid), .bready(local_memory.b_ready),
        .bid(local_memory_rsp.b.id[0]), .bresp(local_memory_rsp.b.resp),
        .arvalid(local_memory.ar_valid), .arready(local_memory_rsp.ar_ready),
        .arid(local_memory.ar.id[0]), .araddr(local_memory.ar.addr), .arlen(local_memory.ar.len),
        .arsize(local_memory.ar.size), .arburst(local_memory.ar.burst), .arlock(local_memory.ar.lock),
        .arcache(local_memory.ar.cache), .arqos(local_memory.ar.qos), .arregion(), .arprot(local_memory.ar.prot),
        .rvalid(local_memory_rsp.r_valid), .rready(local_memory.r_ready),
        .rid(local_memory_rsp.r.id[0]), .rdata(local_memory_rsp.r.data),
        .rresp(local_memory_rsp.r.resp), .rlast(local_memory_rsp.r.last)
    );
    axi_clock_bridge #(.DEPTH(4)) u_memory_cdc (
        .s_clk(clk_npu), .s_rst(rst_npu), .m_clk(clk_sys), .m_rst(rst_sys),
        .s_req(local_memory), .s_rsp(local_memory_rsp), .m_req(memory_req), .m_rsp(memory_rsp)
    );
endmodule
