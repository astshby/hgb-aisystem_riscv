// Module: div_srt4_qds
// Description: Selects a minimally redundant radix-4 digit from truncated carry-save remainder bits.
// qds选择，依据pd-table
module div_srt4_qds #(
    parameter int WIDTH = 132
) (
    input  logic [WIDTH-1:0] partial_sum,
    input  logic [WIDTH-1:0] partial_carry,
    input  logic [3:0]       divisor_prefix,
    output logic signed [2:0] digit
);
    localparam int PREFIX_W = 11;
    localparam int GUARD_W = 2;
    localparam int ESTIMATE_W = PREFIX_W - GUARD_W;

    logic [PREFIX_W-1:0] prefix_bits;
    logic signed [PREFIX_W-1:0] signed_prefix;
    logic signed [ESTIMATE_W-1:0] estimate;
    logic [ESTIMATE_W-1:0] magnitude;
    logic [5:0] select_one;
    logic [5:0] select_two;

    div_srt4_pd_table u_pd_table (.*);

    // 只对余数最高 11 位做短进位加法；丢弃的低位进位由 PD 重叠区容纳。
    // 负数使用截断补码的反码幅值，避免在 QDS 前放置宽取负器。
    always_comb begin
        prefix_bits = partial_sum[WIDTH-1 -: PREFIX_W] +
                      partial_carry[WIDTH-1 -: PREFIX_W];
        signed_prefix = $signed(prefix_bits);
        estimate = signed_prefix >>> GUARD_W;
        magnitude = estimate[ESTIMATE_W-1] ? ~estimate : estimate;

        if (magnitude < ESTIMATE_W'(select_one))
            digit = 3'sd0;
        else if (magnitude < ESTIMATE_W'(select_two))
            digit = estimate[ESTIMATE_W-1] ? -3'sd1 : 3'sd1;
        else
            digit = estimate[ESTIMATE_W-1] ? -3'sd2 : 3'sd2;
    end
endmodule
