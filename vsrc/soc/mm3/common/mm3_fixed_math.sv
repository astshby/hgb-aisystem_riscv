// Module: mm3_fixed_math
// Description: Multi-cycle 32x32 limb multiply and restoring divide, matching integer_math.c.
module mm3_fixed_math (
    input logic clk, rst, start, divide,
    input mm3_fixed_pkg::fixed_t a, b,
    output logic busy, done,
    output mm3_fixed_pkg::fixed_t result
);
    import mm3_fixed_pkg::*;
    typedef enum logic [1:0] {IDLE, MULTIPLY, DIVIDE, FINISH} state_e;
    state_e state_q;
    logic negative_q;
    logic signed [31:0] exponent_q;
    logic [63:0] av_q, bv_q, quotient_q, remainder_q;
    logic [127:0] product_q, numerator_q, completed_product;
    logic [1:0] limb_q;
    logic [7:0] bit_q;
    logic [31:0] limb_a, limb_b;
    logic [63:0] partial, next_remainder, next_quotient, rounded;
    int unsigned shift_count;
    assign busy = state_q != IDLE;
    assign limb_a = limb_q[1] ? av_q[63:32] : av_q[31:0];
    assign limb_b = limb_q[0] ? bv_q[63:32] : bv_q[31:0];
    assign partial = 64'(limb_a) * 64'(limb_b);
    always_comb begin
        completed_product = product_q + ({64'b0,partial} << (32*int'(limb_q[1]) + 32*int'(limb_q[0])));
        next_remainder = (remainder_q << 1) | 64'(numerator_q[bit_q[6:0]]);
        next_quotient = quotient_q;
        if (next_remainder >= bv_q) begin
            next_remainder -= bv_q;
            if (bit_q < 64) next_quotient[bit_q[5:0]] = 1;
        end
        rounded = next_quotient + 64'(next_remainder > bv_q-next_remainder ||
                  (next_remainder == bv_q-next_remainder && next_quotient[0]));
        shift_count = bits128(completed_product) > 61 ? bits128(completed_product)-61 : 0;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE; done <= 0; result <= '0;
            negative_q <= 0; exponent_q <= 0; av_q <= 0; bv_q <= 0;
            quotient_q <= 0; remainder_q <= 0; product_q <= 0; numerator_q <= 0;
            limb_q <= 0; bit_q <= 0;
        end else begin
            done <= 0;
            unique case (state_q)
                IDLE: if (start) begin
                    negative_q <= (a.v < 0) != (b.v < 0);
                    av_q <= magnitude(a.v); bv_q <= magnitude(b.v);
                    exponent_q <= divide ? a.e-b.e-60 : a.e+b.e;
                    product_q <= 0; limb_q <= 0;
                    numerator_q <= {64'b0,magnitude(a.v)} << 60;
                    quotient_q <= 0; remainder_q <= 0; bit_q <= 127;
                    if (a.v == 0 || b.v == 0) begin result <= '0; state_q <= FINISH; end
                    else state_q <= divide ? DIVIDE : MULTIPLY;
                end
                MULTIPLY: begin
                    product_q <= completed_product;
                    if (limb_q == 3) begin
                        result <= make_fixed(negative_q ? -$signed(round128(completed_product,shift_count)) :
                                             $signed(round128(completed_product,shift_count)), exponent_q+32'(shift_count));
                        state_q <= FINISH;
                    end else limb_q <= limb_q+1'b1;
                end
                DIVIDE: begin
                    quotient_q <= next_quotient; remainder_q <= next_remainder;
                    if (bit_q == 0) begin
                        result <= make_fixed(negative_q ? -$signed(rounded) : $signed(rounded), exponent_q);
                        state_q <= FINISH;
                    end else bit_q <= bit_q-1'b1;
                end
                FINISH: begin done <= 1; state_q <= IDLE; end
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
