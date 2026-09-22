// Module: div_shift
// Description: Unsigned radix-2 restoring division backend without division operators.
// 移位除法器
module div_shift #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input logic clk, rst, cancel, start,
    input logic [WIDTH-1:0] dividend, divisor,
    input logic word_mode,
    output logic done,
    output logic [WIDTH-1:0] quotient, remainder
);
    localparam int COUNT_W = $clog2(WIDTH + 1);
    logic [COUNT_W-1:0] count_q;
    logic [WIDTH-1:0] dividend_q, divisor_q, quotient_q, remainder_q;
    logic [WIDTH-1:0] quotient_d;
    logic [WIDTH:0] remainder_d;

    // 每拍移入被除数的一位，试减除数，并产生商的一位。
    always_comb begin
        remainder_d = {remainder_q, dividend_q[WIDTH-1]};
        quotient_d = {quotient_q[WIDTH-2:0], 1'b0};
        if (remainder_d >= {1'b0, divisor_q}) begin
            remainder_d -= {1'b0, divisor_q};
            quotient_d[0] = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || cancel) begin
            count_q <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start)
                count_q <= COUNT_W'((word_mode && WIDTH > 32) ? 32 : WIDTH);
            else if (count_q != '0) begin
                count_q <= count_q - COUNT_W'(1);
                done <= (count_q == COUNT_W'(1));
            end
        end
    end

    // W 被除数左对齐后只迭代 32 位，复用 WIDTH 宽试减器。
    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (start) begin
                dividend_q <= (word_mode && WIDTH > 32) ? dividend << (WIDTH-32) : dividend;
                divisor_q <= divisor;
                quotient_q <= '0;
                remainder_q <= '0;
            end else if (count_q != '0) begin
                dividend_q <= dividend_q << 1;
                quotient_q <= quotient_d;
                remainder_q <= remainder_d[WIDTH-1:0];
                if (count_q == COUNT_W'(1)) begin
                    quotient <= quotient_d;
                    remainder <= remainder_d[WIDTH-1:0];
                end
            end
        end
    end
endmodule
