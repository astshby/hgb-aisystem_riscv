// Module: completion_queue
// Description: Two-entry registered completion FIFO with precise branch cancellation.
module completion_queue (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic input_valid,
    output logic input_ready,
    input pipeline_pkg::retire_completion_t input_completion,
    output logic output_valid,
    output logic output_preview_valid,
    input logic output_ready,
    output pipeline_pkg::retire_completion_t output_completion,
    output logic busy
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;

    retire_completion_t data_q [2], write_data [2];
    logic [1:0] count_q, count_d;
    logic input_fire, output_fire, input_killed;
    logic [1:0] killed, keep, payload_write;
    logic [1:0] survivor_count;
    logic accept_input;

    for (genvar slot = 0; slot < 2; slot++) begin : g_cancel
        assign killed[slot] = recovery.valid && younger_than(data_q[slot].id, recovery.id, head_slot);
    end
    assign input_killed = recovery.valid && younger_than(input_completion.id, recovery.id, head_slot);
    // 输出只来自寄存项；输入容量只依赖寄存占用，切断中央仲裁到发射的 ready 反馈。
    // 预选有效只描述寄存候选；全局 flush 关闭握手，但不穿过中央宽数据选择。
    // 预选不经过当拍恢复比较；ROB写回仍用完整ID接受位，IQ捕获另查live并随恢复取消。
    // 年龄选择先取老项，年轻的取消项不会挤占存活项；实际出队仍检查取消。
    assign output_preview_valid = !rst && count_q != 0;
    assign output_valid = output_preview_valid && !flush && !killed[0];
    assign output_completion = data_q[0];
    assign output_fire = output_valid && output_ready;
    assign input_ready = !rst && !flush && count_q < 2;
    assign input_fire = input_valid && input_ready;
    // busy 包含取消沿之前的残留项，代次复用必须等待这些项真正清除。
    assign busy = count_q != 0;

    // 占用/取消只管理所有权；宽结果仅在槽压缩或真正入队时写入。
    // 两个固定目的槽分别选择载荷，避免 count_d 可变索引贯穿整包写入口。
    assign keep[0] = count_q != 0 && !killed[0] && !output_fire;
    assign keep[1] = count_q == 2 && !killed[1];
    assign survivor_count = {1'b0, keep[0]} + {1'b0, keep[1]};
    assign accept_input = input_fire && !input_killed;
    assign count_d = survivor_count + {1'b0, accept_input};
    always_comb begin
        // 完成时间可乱序；恢复需逐项检查，不能假定年轻项只位于队尾。
        payload_write = '0;
        write_data[0] = data_q[1];
        write_data[1] = input_completion;
        if (!keep[0] && keep[1]) payload_write[0] = 1'b1;
        if (accept_input && survivor_count == 0) begin
            payload_write[0] = 1'b1;
            write_data[0] = input_completion;
        end
        if (accept_input && survivor_count == 1) payload_write[1] = 1'b1;
    end
    always_ff @(posedge clk) begin
        if (rst || flush)
            count_q <= 0;
        else count_q <= count_d;
    end
    for (genvar slot = 0; slot < 2; slot++) begin : g_payload_write
        // 复位/清空丢弃所有权即可；无效槽载荷保留，下一次入队覆盖整个结果。
        always_ff @(posedge clk)
            if (!rst && !flush && payload_write[slot]) data_q[slot] <= write_data[slot];
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst) begin
        assert (count_q <= 2 && count_d <= 2) else $fatal(1, "completion FIFO overflow");
    end
`endif
endmodule
