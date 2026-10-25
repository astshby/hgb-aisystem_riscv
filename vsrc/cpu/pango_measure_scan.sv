// Module: pango_measure_scan
// Description: Independent synchronous scan drive/snapshot boundary for physical diagnostics.
module pango_measure_scan #(
    parameter int unsigned INPUT_BITS = 1,
    parameter int unsigned OUTPUT_BITS = 1
) (
    input logic clk, rst,
    input logic shift, update, capture, serial_in,
    output logic serial_out,
    output logic [INPUT_BITS-1:0] drive,
    input logic [OUTPUT_BITS-1:0] observe
);
    logic [INPUT_BITS-1:0] input_shift_q;
    logic [OUTPUT_BITS-1:0] snapshot_q;

    // MSB 先输入/读出。移位不改变 DUT 输入；update 原子提交上一拍的完整输入串。
    // 提交后清空装载串，下一次 update 可立即撤销 valid；holding 在再次 update 前不变。
    // capture 优先于输出移位，读取快照不会向 DUT 的 ready/valid 添加反馈。
    assign serial_out = snapshot_q[OUTPUT_BITS-1];
    always_ff @(posedge clk) begin
        if (rst) begin
            input_shift_q <= '0;
            drive <= '0;
            snapshot_q <= '0;
        end else begin
            if (update) begin
                drive <= input_shift_q;
                input_shift_q <= '0;
            end else if (shift) input_shift_q <= (input_shift_q << 1) | INPUT_BITS'(serial_in);
            if (capture) snapshot_q <= observe;
            else if (shift) snapshot_q <= snapshot_q << 1;
        end
    end

    initial begin
        assert (INPUT_BITS > 0 && OUTPUT_BITS > 0)
            else $fatal(1, "measurement scan widths must be positive");
    end
endmodule
