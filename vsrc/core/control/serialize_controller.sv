// Module: serialize_controller
// Description: Blocks fetch while serialization drains, completes, or is cancelled.
// 开始序列化时清空年轻取指；WB 完成该事件，或更老的重定向取消错误路径事件。
module serialize_controller (
    input  logic clk,
    input  logic rst,
    input  logic serialize_start,
    input  logic serialize_complete,
    input  logic serialize_cancel,
    output logic frontend_flush,
    output logic fetch_request_enable
);
    logic serialize_pending_q;
    logic serialize_release;

    // complete 表示序列化指令在 WB 正常完成，cancel 表示更老控制流将其杀死。
    // 开始或 pending 期间禁止新取指；释放当拍已有 redirect，因此下一拍再恢复请求。
    always_comb begin
        serialize_release = serialize_complete || serialize_cancel;
        frontend_flush = serialize_start && !serialize_release;
        fetch_request_enable = !serialize_pending_q && !serialize_start;
    end

    // 正常完成与错误路径取消都释放 pending；释放优先于同拍的新开始事件。
    always_ff @(posedge clk) begin
        if (rst || serialize_release)
            serialize_pending_q <= 1'b0;
        else if (serialize_start)
            serialize_pending_q <= 1'b1;
    end
endmodule
