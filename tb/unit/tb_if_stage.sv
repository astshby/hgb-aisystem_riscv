// Module: tb_if_stage
// Description: Checks fetch response buffering and redirect cancellation.
module tb_if_stage;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic fetch_request_enable;
    logic out_ready;
    logic flush;
    redirect_t redirect;
    pred_info_t prediction;
    if_d1_t out_packet;
    logic imem_req_valid;
    logic [XLEN-1:0] imem_req_addr;
    logic imem_req_ready;
    logic imem_rsp_valid;
    logic [31:0] imem_rsp_data;
    logic imem_rsp_ready;

    always #5 clk = ~clk;
    if_stage dut (.*);

    initial begin
        fetch_request_enable = 1'b1;
        out_ready = 1'b1;
        flush = 1'b0;
        redirect = '0;
        prediction = '0;
        imem_req_ready = 1'b1;
        imem_rsp_valid = 1'b0;
        imem_rsp_data = '0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;
        assert (imem_req_valid && imem_req_addr == RESET_VECTOR)
            else $fatal(1, "initial fetch request");

        // 接受请求，随后在 D1 暂停时返回；IF 应把响应存入 buffer。
        @(posedge clk);
        @(negedge clk);
        out_ready = 1'b0;
        imem_rsp_valid = 1'b1;
        imem_rsp_data = 32'h0010_0093;
        #1;
        assert (imem_rsp_ready && out_packet.valid)
            else $fatal(1, "response must be accepted into empty buffer");
        @(posedge clk);
        @(negedge clk);
        // IF 已在上一拍同时发出下一笔请求；buffer 满时暂不接收第二个响应。
        imem_rsp_valid = 1'b1;
        imem_rsp_data = 32'h0020_0113;
        #1;
        assert (out_packet.valid && out_packet.inst == 32'h0010_0093)
            else $fatal(1, "buffered response not held");
        assert (!imem_rsp_ready)
            else $fatal(1, "full buffer accepted another response");

        // D1 恢复后取走旧 buffer，同拍接收的新响应替换进去。
        out_ready = 1'b1;
        #1;
        assert (out_packet.valid && imem_rsp_ready)
            else $fatal(1, "buffer replacement handshake");
        @(posedge clk);
        @(negedge clk);
        imem_rsp_valid = 1'b0;
        #1;
        assert (out_packet.valid && out_packet.inst == 32'h0020_0113)
            else $fatal(1, "new response did not replace consumed buffer");
        @(posedge clk);
        @(negedge clk);
        #1;
        assert (!out_packet.valid) else $fatal(1, "replacement buffer not consumed");

        // 当前已有新的未完成请求；redirect 后其迟到响应必须被消费但不能输出。
        redirect.valid = 1'b1;
        redirect.pc = xlen_t'(32'h40);
        redirect.reason = REDIR_EX_BRANCH;
        @(posedge clk);
        @(negedge clk);
        redirect.valid = 1'b0;
        imem_rsp_valid = 1'b1;
        imem_rsp_data = 32'hdead_beef;
        #1;
        assert (imem_rsp_ready && !out_packet.valid)
            else $fatal(1, "killed response handling");
        assert (imem_req_valid && imem_req_addr == xlen_t'(32'h40))
            else $fatal(1, "redirect target request");

        // 序列化 flush 不改变 PC，但必须杀死已经发出的年轻请求及其迟到响应。
        @(posedge clk);
        @(negedge clk);
        imem_rsp_valid = 1'b0;
        fetch_request_enable = 1'b0;
        flush = 1'b1;
        #1;
        assert (!imem_req_valid && !out_packet.valid)
            else $fatal(1, "serialization flush output");
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        imem_rsp_valid = 1'b1;
        imem_rsp_data = 32'hcafe_babe;
        #1;
        assert (imem_rsp_ready && !out_packet.valid)
            else $fatal(1, "serialization killed response");

        $display("PASS tb_if_stage RV%0d", XLEN);
        $finish;
    end
endmodule
