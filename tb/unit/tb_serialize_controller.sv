// Module: tb_serialize_controller
// Description: Checks frontend flush and persistent fetch blocking during serialization.
module tb_serialize_controller;
    timeunit 1ns;
    timeprecision 1ps;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic serialize_start;
    logic serialize_complete;
    logic serialize_cancel;
    logic frontend_flush;
    logic fetch_request_enable;

    always #5 clk = ~clk;

    serialize_controller dut (.*);

    initial begin
        serialize_start = 1'b0;
        serialize_complete = 1'b0;
        serialize_cancel = 1'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;
        assert (!frontend_flush && fetch_request_enable)
            else $fatal(1, "idle fetch permission");

        // 开始事件当拍立即清前端，并在时钟沿保存 pending 状态。
        serialize_start = 1'b1;
        #1;
        assert (frontend_flush && !fetch_request_enable)
            else $fatal(1, "serialization start");
        @(posedge clk);
        @(negedge clk);
        serialize_start = 1'b0;
        #1;
        assert (!frontend_flush && !fetch_request_enable)
            else $fatal(1, "serialization pending hold");

        // WB 正常完成序列化并清除 pending；当拍仍不提前发出新请求。
        serialize_complete = 1'b1;
        #1;
        assert (!frontend_flush && !fetch_request_enable)
            else $fatal(1, "serialization completion cycle");
        @(posedge clk);
        @(negedge clk);
        serialize_complete = 1'b0;
        #1;
        assert (!frontend_flush && fetch_request_enable)
            else $fatal(1, "fetch resumes after completion");

        // 重新建立 pending，验证更老控制流走独立的 cancel 端口。
        serialize_start = 1'b1;
        #1;
        @(posedge clk);
        @(negedge clk);
        serialize_start = 1'b0;
        serialize_cancel = 1'b1;
        #1;
        assert (!frontend_flush && !fetch_request_enable)
            else $fatal(1, "serialization cancellation cycle");
        @(posedge clk);
        @(negedge clk);
        serialize_cancel = 1'b0;
        #1;
        assert (fetch_request_enable)
            else $fatal(1, "fetch resumes after cancellation");

        // 同时开始与取消按更老控制流处理，不留下 pending 状态。
        serialize_start = 1'b1;
        serialize_cancel = 1'b1;
        #1;
        assert (!frontend_flush && !fetch_request_enable)
            else $fatal(1, "cancellation priority");
        @(posedge clk);
        @(negedge clk);
        serialize_start = 1'b0;
        serialize_cancel = 1'b0;
        #1;
        assert (fetch_request_enable)
            else $fatal(1, "cancellation priority cleared pending");

        $display("PASS tb_serialize_controller");
        $finish;
    end
endmodule
