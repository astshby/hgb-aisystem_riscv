// Module: mul_dsp
// Description: Registered unsigned multiplier inferred from one multiplication operator.
module mul_dsp #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input logic clk, rst, cancel, start,
    input logic [WIDTH-1:0] operand_a, operand_b,
    output logic done,
    output logic [2*WIDTH-1:0] product
);
    // 通用 RTL 只表达一次完整乘法，由 综合工具决定 DSP 的拆分与级联。
    always_ff @(posedge clk) begin
        if (rst || cancel) begin
            done <= 1'b0;
        end else begin
            done <= start;
            if (start)
                product <= operand_a * operand_b;
        end
    end
endmodule
