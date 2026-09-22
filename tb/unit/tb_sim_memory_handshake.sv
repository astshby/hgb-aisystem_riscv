// Module: tb_sim_memory_handshake
// Description: Checks that simulation BRAM responses remain stable until accepted.
module tb_sim_memory_handshake;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic imem_req_valid;
    xlen_t imem_req_addr;
    logic imem_req_ready;
    logic imem_rsp_valid;
    logic [31:0] imem_rsp_data;
    logic imem_rsp_ready;

    logic dmem_req_valid;
    logic dmem_req_write;
    xlen_t dmem_req_addr;
    xlen_t dmem_req_wdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_req_ready;
    logic dmem_rsp_valid;
    xlen_t dmem_rsp_rdata;
    logic dmem_rsp_ready;

    always #5 clk = ~clk;

    sim_imem #(.DEPTH_WORDS(16)) u_imem (
        .clk,
        .rst,
        .req_valid(imem_req_valid),
        .req_addr(imem_req_addr),
        .req_ready(imem_req_ready),
        .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data),
        .rsp_ready(imem_rsp_ready)
    );

    sim_dmem #(.DEPTH_WORDS(16)) u_dmem (
        .clk,
        .rst,
        .req_valid(dmem_req_valid),
        .req_write(dmem_req_write),
        .req_addr(dmem_req_addr),
        .req_wdata(dmem_req_wdata),
        .req_wstrb(dmem_req_wstrb),
        .req_ready(dmem_req_ready),
        .rsp_valid(dmem_rsp_valid),
        .rsp_rdata(dmem_rsp_rdata),
        .rsp_ready(dmem_rsp_ready)
    );

    initial begin
        u_imem.mem[0] = 32'h1111_1111;
        u_imem.mem[1] = 32'h2222_2222;
        u_dmem.mem[0] = xlen_t'(32'h3333_3333);
        u_dmem.mem[1] = xlen_t'(32'h4444_4444);
        imem_req_valid = 1'b0;
        imem_req_addr = '0;
        imem_rsp_ready = 1'b0;
        dmem_req_valid = 1'b0;
        dmem_req_write = 1'b0;
        dmem_req_addr = '0;
        dmem_req_wdata = '0;
        dmem_req_wstrb = '0;
        dmem_rsp_ready = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        imem_req_valid = 1'b1;
        dmem_req_valid = 1'b1;
        #1;
        assert (imem_req_ready && dmem_req_ready)
            else $fatal(1, "initial request not accepted");

        @(posedge clk);
        @(negedge clk);
        imem_req_valid = 1'b0;
        dmem_req_valid = 1'b0;
        #1;
        assert (imem_rsp_valid && imem_rsp_data == 32'h1111_1111 && !imem_req_ready)
            else $fatal(1, "IMEM response hold");
        assert (dmem_rsp_valid && dmem_rsp_rdata == xlen_t'(32'h3333_3333) && !dmem_req_ready)
            else $fatal(1, "DMEM response hold");

        // ready=0 跨过一个时钟后，valid 和数据仍需保持。
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (imem_rsp_valid && imem_rsp_data == 32'h1111_1111)
            else $fatal(1, "IMEM response changed before handshake");
        assert (dmem_rsp_valid && dmem_rsp_rdata == xlen_t'(32'h3333_3333))
            else $fatal(1, "DMEM response changed before handshake");

        // 接收旧响应的同拍允许新请求进入响应寄存器。
        imem_rsp_ready = 1'b1;
        dmem_rsp_ready = 1'b1;
        imem_req_valid = 1'b1;
        imem_req_addr = xlen_t'(4);
        dmem_req_valid = 1'b1;
        dmem_req_addr = xlen_t'(DBUS_BYTES);
        #1;
        assert (imem_req_ready && dmem_req_ready)
            else $fatal(1, "back-to-back request handshake");
        @(posedge clk);
        @(negedge clk);
        imem_req_valid = 1'b0;
        dmem_req_valid = 1'b0;
        #1;
        assert (imem_rsp_valid && imem_rsp_data == 32'h2222_2222)
            else $fatal(1, "IMEM replacement response");
        assert (dmem_rsp_valid && dmem_rsp_rdata == xlen_t'(32'h4444_4444))
            else $fatal(1, "DMEM replacement response");

        $display("PASS tb_sim_memory_handshake RV%0d", XLEN);
        $finish;
    end
endmodule
