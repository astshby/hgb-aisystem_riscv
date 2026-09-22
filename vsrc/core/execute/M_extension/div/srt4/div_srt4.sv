// Module: div_srt4
// Description: Normalized radix-4 SRT divider with PD-QDS, carry-save remainder, OTF quotient, and correction.
// srt的主体控制
module div_srt4 #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input logic clk, rst, cancel, start,
    input logic [WIDTH-1:0] dividend, divisor,
    input logic word_mode,
    output logic done,
    output logic [WIDTH-1:0] quotient, remainder
);
    localparam int PARTIAL_W = 2*WIDTH + 4;
    localparam int QUOTIENT_W = WIDTH + 2;
    localparam int COUNT_W = $clog2(WIDTH + 2);
    localparam int SHIFT_W = $clog2(WIDTH);
    localparam int REMAINDER_SHIFT_W = $clog2(2*WIDTH + 1);
    typedef logic signed [PARTIAL_W-1:0] partial_t;

    logic [WIDTH-1:0] aligned_dividend, aligned_divisor;
    logic [WIDTH-1:0] normalized_divisor;
    logic [2*WIDTH-1:0] normalized_dividend;
    logic [SHIFT_W-1:0] normalization_shift;
    logic [COUNT_W-1:0] active_width, operand_padding;
    logic [COUNT_W-1:0] count_q;
    logic [REMAINDER_SHIFT_W-1:0] remainder_shift_q;
    logic active_q;

    partial_t partial_start, scaled_divisor_start;
    partial_t partial_sum_q, partial_carry_q;
    partial_t divisor_q, negative_divisor_q, addend;
    partial_t residual_sum, residual_carry, residual_binary;
    partial_t corrected_remainder;
    logic signed [2:0] digit;
    logic [QUOTIENT_W-1:0] quotient_q, minus_one_q;
    logic [QUOTIENT_W-1:0] next_quotient, next_minus_one;
    logic [QUOTIENT_W-1:0] corrected_quotient;

    // RV64 W 形式先左对齐到 XLEN，但只生成 32 位商；RV32 与普通 RV64 使用全宽。
    generate
        if (WIDTH > 32) begin : g_word_mode
            always_comb begin
                if (word_mode) begin
                    aligned_dividend = dividend << (WIDTH - 32);
                    aligned_divisor = divisor << (WIDTH - 32);
                    active_width = COUNT_W'(32);
                    operand_padding = COUNT_W'(WIDTH - 32);
                end else begin
                    aligned_dividend = dividend;
                    aligned_divisor = divisor;
                    active_width = COUNT_W'(WIDTH);
                    operand_padding = '0;
                end
            end
        end else begin : g_full_width
            always_comb begin
                aligned_dividend = dividend;
                aligned_divisor = divisor;
                active_width = COUNT_W'(WIDTH);
                operand_padding = '0;
            end
        end
    endgenerate

    div_srt4_normalize #(.WIDTH(WIDTH)) u_normalize (
        .dividend(aligned_dividend),
        .divisor(aligned_divisor),
        .shift(normalization_shift),
        .normalized_dividend,
        .normalized_divisor
    );

    // D 的最高位固定在 PARTIAL 的 2*WIDTH-1，W 形式额外填充 P0 以保持同一 QDS 位置。
    always_comb begin
        scaled_divisor_start = partial_t'(normalized_divisor) <<< WIDTH;
        partial_start = partial_t'(normalized_dividend) <<< operand_padding;
    end

    div_srt4_qds #(.WIDTH(PARTIAL_W)) u_qds (
        .partial_sum(partial_sum_q),
        .partial_carry(partial_carry_q),
        .divisor_prefix(divisor_q[2*WIDTH-1 -: 4]),
        .digit
    );

    // 预计算的 ±D 由商位选择，迭代内只剩一级 3:2 压缩。
    always_comb begin
        unique case (digit)
            3'sd2:  addend = negative_divisor_q <<< 1;
            3'sd1:  addend = negative_divisor_q;
            -3'sd1: addend = divisor_q;
            -3'sd2: addend = divisor_q <<< 1;
            default: addend = '0;
        endcase
    end

    div_srt4_csa #(.WIDTH(PARTIAL_W)) u_remainder_csa (
        .row_a(partial_sum_q),
        .row_b(partial_carry_q),
        .addend,
        .sum(residual_sum),
        .carry(residual_carry)
    );

    div_srt4_otf #(.WIDTH(QUOTIENT_W)) u_otf (
        .quotient(quotient_q),
        .quotient_minus_one(minus_one_q),
        .digit,
        .next_quotient,
        .next_minus_one
    );

    // 完整进位加法只出现在最终结果路径；负余数加 D 并选择 Q-1。
    always_comb begin
        residual_binary = residual_sum + residual_carry;
        corrected_quotient = next_quotient;
        corrected_remainder = residual_binary;
        if (residual_binary < 0) begin
            corrected_quotient = next_minus_one;
            corrected_remainder = residual_binary + divisor_q;
        end
    end

    // 每拍生成一个 {-2,-1,0,1,2} 商位，非末轮将余数两行同时左移两位。
    always_ff @(posedge clk) begin
        if (rst || cancel) begin
            active_q <= 1'b0;
            count_q <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                active_q <= 1'b1;
                count_q <= (active_width >> 1) + COUNT_W'(1);
                remainder_shift_q <= REMAINDER_SHIFT_W'(WIDTH) +
                                     REMAINDER_SHIFT_W'(operand_padding) +
                                     REMAINDER_SHIFT_W'(normalization_shift);
                partial_sum_q <= partial_start;
                partial_carry_q <= '0;
                divisor_q <= scaled_divisor_start;
                negative_divisor_q <= -scaled_divisor_start;
                quotient_q <= '0;
                minus_one_q <= '1;
            end else if (active_q) begin
                quotient_q <= next_quotient;
                minus_one_q <= next_minus_one;
                if (count_q == COUNT_W'(1)) begin
                    active_q <= 1'b0;
                    count_q <= '0;
                    done <= 1'b1;
                    quotient <= corrected_quotient[WIDTH-1:0];
                    remainder <= WIDTH'(corrected_remainder >>> remainder_shift_q);
                end else begin
                    count_q <= count_q - COUNT_W'(1);
                    partial_sum_q <= residual_sum <<< 2;
                    partial_carry_q <= residual_carry <<< 2;
                end
            end
        end
    end

`ifndef SYNTHESIS
    logic signed [PARTIAL_W+1:0] three_residual;
    logic signed [PARTIAL_W+1:0] two_divisor;

    // 可执行不变量防止 PD 表、截断位或 CSA 更改破坏 SRT 收敛边界。
    always_comb begin
        three_residual = ({{2{residual_binary[PARTIAL_W-1]}}, residual_binary} <<< 1) +
                         {{2{residual_binary[PARTIAL_W-1]}}, residual_binary};
        two_divisor = {{2{divisor_q[PARTIAL_W-1]}}, divisor_q} <<< 1;
    end

    always_ff @(posedge clk) begin
        if (!rst && !cancel) begin
            if (start) begin
                assert (divisor != '0) else $fatal(1, "SRT zero divisor escaped ISA handling");
                assert (normalized_divisor[WIDTH-1]) else $fatal(1, "SRT divisor normalization");
            end
            if (active_q) begin
                assert ((three_residual <= two_divisor) &&
                        (three_residual >= -two_divisor))
                    else $fatal(1, "SRT PD/QDS residual bound");
                assert (next_minus_one == next_quotient - QUOTIENT_W'(1))
                    else $fatal(1, "SRT on-the-fly Q/QM invariant");
                if (count_q == COUNT_W'(1))
                    assert ((corrected_remainder >= 0) &&
                            (corrected_remainder < divisor_q))
                        else $fatal(1, "SRT final remainder correction");
            end
        end
    end
`endif
endmodule
