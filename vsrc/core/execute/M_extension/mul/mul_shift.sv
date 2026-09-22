// Module: mul_shift
// Description: Unsigned radix-2 shift-and-add multiplication backend.
// 移位乘法器
module mul_shift #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input logic clk, rst, cancel, start,
    input logic [WIDTH-1:0] operand_a, operand_b,
    output logic done,
    output logic [2*WIDTH-1:0] product
);
    localparam int COUNT_W = $clog2(WIDTH + 1);
    logic [COUNT_W-1:0] count_q;
    logic [2*WIDTH-1:0] multiplicand_q, accumulator_q, sum;
    logic [WIDTH-1:0] multiplier_q;

    assign sum = accumulator_q + (multiplier_q[0] ? multiplicand_q : '0);

    // 每拍消费乘数一位；count 只表示算法进度。
    always_ff @(posedge clk) begin
        if (rst || cancel) begin
            count_q <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start)
                count_q <= COUNT_W'(WIDTH);
            else if (count_q != '0) begin
                count_q <= count_q - COUNT_W'(1);
                done <= (count_q == COUNT_W'(1));
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (start) begin
                accumulator_q <= '0;
                multiplicand_q <= {{WIDTH{1'b0}}, operand_a};
                multiplier_q <= operand_b;
            end else if (count_q != '0) begin
                accumulator_q <= sum;
                multiplicand_q <= multiplicand_q << 1;
                multiplier_q <= multiplier_q >> 1;
                if (count_q == COUNT_W'(1))
                    product <= sum;
            end
        end
    end
endmodule
