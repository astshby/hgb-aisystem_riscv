// Module: div_srt4_csa
// Description: Compresses two partial-remainder rows and one divisor multiple without carry propagation.
// 余数carry-save压缩器，3行压缩成2行，级内不做宽进位传播。
module div_srt4_csa #(
    parameter int WIDTH = 132
) (
    input  logic [WIDTH-1:0] row_a,
    input  logic [WIDTH-1:0] row_b,
    input  logic [WIDTH-1:0] addend,
    output logic [WIDTH-1:0] sum,
    output logic [WIDTH-1:0] carry
);
    // 3:2 压缩只在同位产生 sum/carry，迭代内不经过宽进位链。
    always_comb begin
        sum = row_a ^ row_b ^ addend;
        carry = ((row_a & row_b) | (row_a & addend) | (row_b & addend)) << 1;
    end
endmodule
