// Module: npu_csr_cosim
// Description: Scalar master, real AXI CDC and unchanged NPU1 for native C/RTL co-simulation.
module npu_csr_cosim (
    input logic clk_sys, clk_npu, rst_sys, rst_npu,
    input logic cfg_valid,
    output logic cfg_ready,
    input logic cfg_write,
    input logic [31:0] cfg_addr, cfg_wdata,
    input logic [3:0] cfg_wstrb,
    input logic [1:0] cfg_size,
    output logic cfg_rsp_valid,
    input logic cfg_rsp_ready,
    output logic [31:0] cfg_rdata,
    output logic [1:0] cfg_error,
    input logic allow_aw, allow_w, allow_ar, allow_b, allow_r,
    output logic pending_b, pending_r,
    output logic [1:0] pending_bresp, pending_rresp,
    output logic [63:0] aw_count, w_count, b_count, ar_count, r_count
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import axi_types_pkg::*;
    bus_req_t request;
    bus_rsp_t response;
    axi_req_t master_req, target_req;
    axi_rsp_t master_rsp, target_rsp;
    logic upper_word_q;

    always_comb begin
        request = '0;
        request.addr = xlen_t'(cfg_addr);
        request.write = cfg_write;
        request.size = mem_size_e'(cfg_size);
        request.wdata = xlen_t'(cfg_wdata) << (XLEN == 64 && cfg_addr[2] ? 32 : 0);
        request.wstrb = DBUS_BYTES'(cfg_wstrb) << (XLEN == 64 && cfg_addr[2] ? 4 : 0);
    end
    always_ff @(posedge clk_sys) begin
        if (rst_sys) upper_word_q <= 0;
        else if (cfg_valid && cfg_ready) upper_word_q <= cfg_addr[2];
    end
    assign cfg_rdata = 32'(response.rdata >> (XLEN == 64 && upper_word_q ? 32 : 0));
    assign cfg_error = response.error;
    cache_axi_adapter u_master (
        .clk(clk_sys), .rst(rst_sys), .req_valid(cfg_valid), .req_ready(cfg_ready),
        .request, .rsp_valid(cfg_rsp_valid), .rsp_ready(cfg_rsp_ready), .response,
        .rd_cmd_valid(1'b0), .rd_cmd_ready(), .rd_cmd('0), .rd_valid(),
        .rd_ready(1'b1), .rd_data(), .wr_cmd_valid(1'b0), .wr_cmd_ready(),
        .wr_cmd('0), .wr_valid(1'b0), .wr_ready(), .wr_data('0),
        .wr_rsp_valid(), .wr_rsp_ready(1'b1), .wr_rsp(), .axi_req(master_req), .axi_rsp(master_rsp)
    );
    // 测试端只在每笔请求开始时停住通道；放行后保持至握手，不撤回已出现的VALID。
    always_comb begin
        target_req = master_req;
        master_rsp = target_rsp;
        target_req.aw_valid = master_req.aw_valid && allow_aw;
        master_rsp.aw_ready = target_rsp.aw_ready && allow_aw;
        target_req.w_valid = master_req.w_valid && allow_w;
        master_rsp.w_ready = target_rsp.w_ready && allow_w;
        target_req.ar_valid = master_req.ar_valid && allow_ar;
        master_rsp.ar_ready = target_rsp.ar_ready && allow_ar;
        master_rsp.b_valid = target_rsp.b_valid && allow_b;
        target_req.b_ready = master_req.b_ready && allow_b;
        master_rsp.r_valid = target_rsp.r_valid && allow_r;
        target_req.r_ready = master_req.r_ready && allow_r;
    end
    assign pending_b = target_rsp.b_valid;
    assign pending_r = target_rsp.r_valid;
    assign pending_bresp = target_rsp.b.resp;
    assign pending_rresp = target_rsp.r.resp;
    npu_axi_target u_target (
        .clk_sys, .rst_sys, .clk_npu, .rst_npu, .axi_req(target_req), .axi_rsp(target_rsp)
    );
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            aw_count <= 0; w_count <= 0; b_count <= 0; ar_count <= 0; r_count <= 0;
        end else begin
            if (target_req.aw_valid && target_rsp.aw_ready) aw_count <= aw_count + 1;
            if (target_req.w_valid && target_rsp.w_ready) w_count <= w_count + 1;
            if (target_rsp.b_valid && target_req.b_ready) b_count <= b_count + 1;
            if (target_req.ar_valid && target_rsp.ar_ready) ar_count <= ar_count + 1;
            if (target_rsp.r_valid && target_req.r_ready) r_count <= r_count + 1;
        end
    end
    assert property (@(posedge clk_sys) disable iff (rst_sys)
        cfg_rsp_valid && !cfg_rsp_ready |=> cfg_rsp_valid && $stable({cfg_rdata,cfg_error}));
    assert property (@(posedge clk_sys) disable iff (rst_sys)
        target_rsp.b_valid && !target_req.b_ready |=> target_rsp.b_valid && $stable(target_rsp.b));
    assert property (@(posedge clk_sys) disable iff (rst_sys)
        target_rsp.r_valid && !target_req.r_ready |=> target_rsp.r_valid && $stable(target_rsp.r));
endmodule
