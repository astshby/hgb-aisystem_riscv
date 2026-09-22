// Module: mul_booth_wallace
// Description: Unsigned radix-4 Booth recoding with a registered Wallace compression tree.
// booth-wallace的主体，主要是合并积+wallace简化加法
module mul_booth_wallace #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input logic clk, rst, cancel, start,
    input logic [WIDTH-1:0] operand_a, operand_b,
    output logic done,
    output logic [2*WIDTH-1:0] product
);
    localparam int ROWS = (WIDTH + 2) / 2;
    localparam int PRODUCT_W = 2*WIDTH + 2;
    typedef logic [PRODUCT_W-1:0] wide_t;
    logic [2*ROWS:0] recoder;
    wide_t a_extended;
    wide_t partial_d [ROWS], partial_q [ROWS];
    wide_t tree_sum, tree_carry, sum_q, carry_q;
    logic partial_valid_q, tree_valid_q;

    // 无符号乘数顶端补 0，并保留额外 Booth 组；否则最高位为 1 会被解释成负数。
    assign recoder = (2*ROWS+1)'({operand_b, 1'b0});
    assign a_extended = wide_t'(operand_a);
    always_comb begin
        for (int i = 0; i < ROWS; i++) begin
            unique case (recoder[2*i +: 3])
                3'b001, 3'b010: partial_d[i] = a_extended;
                3'b011:         partial_d[i] = a_extended << 1;
                3'b100:         partial_d[i] = -(a_extended << 1);
                3'b101, 3'b110: partial_d[i] = -a_extended;
                default:        partial_d[i] = '0;
            endcase
            partial_d[i] = partial_d[i] << (2*i);
        end
    end

    wallace_tree #(.WIDTH(PRODUCT_W), .ROWS(ROWS)) u_tree (
        .rows(partial_q), .sum(tree_sum), .carry(tree_carry)
    );

    always_ff @(posedge clk) begin
        if (rst || cancel) begin
            partial_valid_q <= 1'b0;
            tree_valid_q <= 1'b0;
            done <= 1'b0;
        end else begin
            partial_valid_q <= start;
            tree_valid_q <= partial_valid_q;
            done <= tree_valid_q;
        end
    end

    // Booth 部分积、两行压缩结果、最终进位传播加法分别隔开；不使用乘法运算符。
    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (start)
                for (int i = 0; i < ROWS; i++)
                    partial_q[i] <= partial_d[i];
            if (partial_valid_q) begin
                sum_q <= tree_sum;
                carry_q <= tree_carry;
            end
            if (tree_valid_q)
                product <=  (2*WIDTH)'(sum_q + carry_q);
        end
    end
endmodule
