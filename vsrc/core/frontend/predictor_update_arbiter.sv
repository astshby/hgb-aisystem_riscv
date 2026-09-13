// Module: predictor_update_arbiter
// Description: Gives older EX updates priority and buffers a simultaneous D1 JAL update.
// 用于给predictor提供更新信息，从EX与D1选择，同时出现则使用pending保存
module predictor_update_arbiter (
    input  logic                       clk,
    input  logic                       rst,
    input  logic                       flush,
    input  pipeline_pkg::pred_update_t d1_update,
    input  pipeline_pkg::pred_update_t ex_update,
    output pipeline_pkg::pred_update_t update,
    output logic                       overflow
);
    import pipeline_pkg::*;

    pred_update_t pending_q;

    // 单端口选择：EX > pending > D1。
    always_comb begin
        // 引发 EX 重定向的老分支仍需训练；flush 只丢弃被杀死的 pending/D1。
        if (ex_update.valid)
            update = ex_update;
        else if (flush)
            update = '0;
        else if (pending_q.valid)
            update = pending_q;
        else
            update = d1_update;
        overflow = !flush && ex_update.valid && pending_q.valid && d1_update.valid;
        // 如果同时出现，也就是pending过载了（因为pending本质还需要在ex没有的时候保存旧的d1阶段信息）
    end

    // pending 管理：EX 占用端口时缓存 D1，pending 发出后可由新 D1 接替。
    always_ff @(posedge clk) begin
        if (rst || flush)
            pending_q <= '0;
        else if (ex_update.valid) begin
            if (d1_update.valid && !pending_q.valid)
                pending_q <= d1_update;
        end
        else if (pending_q.valid) begin
            if (d1_update.valid)
                pending_q <= d1_update;
            else
                pending_q <= '0;
        end
        else
            pending_q <= '0;
    end
endmodule
