// Module: div_srt4_otf
// Description: On-the-fly radix-4 signed-digit conversion maintaining Q and Q minus one.
module div_srt4_otf #(
    parameter int WIDTH = 66
) (
    input logic [WIDTH-1:0] quotient, quotient_minus_one,
    input logic signed [2:0] digit,
    output logic [WIDTH-1:0] next_quotient, next_minus_one
);
    // Q' = 4Q + digit，QM' = Q' - 1；只拼接两位，避免每拍宽进位加法。
    always_comb begin
        unique case (digit)
            3'sd2: begin
                next_quotient = {quotient[WIDTH-3:0], 2'b10};
                next_minus_one = {quotient[WIDTH-3:0], 2'b01};
            end
            3'sd1: begin
                next_quotient = {quotient[WIDTH-3:0], 2'b01};
                next_minus_one = {quotient[WIDTH-3:0], 2'b00};
            end
            -3'sd1: begin
                next_quotient = {quotient_minus_one[WIDTH-3:0], 2'b11};
                next_minus_one = {quotient_minus_one[WIDTH-3:0], 2'b10};
            end
            -3'sd2: begin
                next_quotient = {quotient_minus_one[WIDTH-3:0], 2'b10};
                next_minus_one = {quotient_minus_one[WIDTH-3:0], 2'b01};
            end
            default: begin
                next_quotient = {quotient[WIDTH-3:0], 2'b00};
                next_minus_one = {quotient_minus_one[WIDTH-3:0], 2'b11};
            end
        endcase
    end
endmodule
