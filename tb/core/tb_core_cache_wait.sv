// Module: tb_core_cache_wait
// Description: Models a delayed D-Cache response and checks WB backpressure without reissue.
module tb_core_cache_wait;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import rv_asm_pkg::*;

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
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;

    logic load_pending_q;
    integer delay_q;
    integer request_count;
    integer idx;
    integer cycles;

    // 成功时先跳出采样循环，统一结束仿真，避免继续执行循环后的超时路径。
    logic completed = 1'b0;

    always #5 clk = ~clk;

    core dut (.*);

    sim_imem #(.DEPTH_WORDS(32)) u_imem (
        .clk,
        .rst,
        .req_valid(imem_req_valid),
        .req_addr(imem_req_addr),
        .req_ready(imem_req_ready),
        .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data),
        .rsp_ready(imem_rsp_ready)
    );

    // 简化的阻塞式 D-Cache：接受一次 load，等待三拍后保持响应直到 WB 接收。
    assign dmem_req_ready = !load_pending_q && (!dmem_rsp_valid || dmem_rsp_ready);

    always_ff @(posedge clk) begin
        if (rst) begin
            load_pending_q <= 1'b0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_rdata <= '0;
            delay_q <= 0;
            request_count <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready)
                dmem_rsp_valid <= 1'b0;

            if (load_pending_q) begin
                if (delay_q == 0) begin
                    load_pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= xlen_t'(41);
                end else begin
                    delay_q <= delay_q - 1;
                end
            end

            if (dmem_req_valid && dmem_req_ready) begin
                request_count <= request_count + 1;
                if (!dmem_req_write) begin
                    load_pending_q <= 1'b1;
                    delay_q <= 3;
                end
            end
        end
    end

    initial begin
        for (idx = 0; idx < 32; idx = idx + 1)
            u_imem.mem[idx] = nop();
        u_imem.mem[0] = enc_lw(5'd1, 5'd0, 0);
        u_imem.mem[1] = enc_addi(5'd2, 5'd0, 7);
        u_imem.mem[2] = enc_addi(5'd3, 5'd1, 1);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 100; cycles = cycles + 1) begin
            @(negedge clk);
            if (commit_exception && commit_valid)
                $fatal(1, "unexpected exception at pc=%h", commit_pc);
            if (commit_valid && commit_pc == xlen_t'(0)) begin
                assert (commit_rd_we && commit_rd_data == xlen_t'(41))
                    else $fatal(1, "delayed load result");
                assert (request_count == 1)
                    else $fatal(1, "load request was issued more than once");
            end
            if (commit_valid && commit_pc == xlen_t'(4)) begin
                assert (commit_rd_data == xlen_t'(7))
                    else $fatal(1, "instruction behind miss was corrupted");
            end
            if (commit_valid && commit_pc == xlen_t'(8)) begin
                assert (commit_rd_data == xlen_t'(42) && request_count == 1)
                    else $fatal(1, "WB forwarding after delayed response");
                $display("PASS tb_core_cache_wait cycles=%0d", cycles);
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            $fatal(1, "cache wait test timeout");
        $finish;
    end
endmodule
