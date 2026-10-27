// Module: mm3_udiv
// Description: Unsigned restoring divider with explicit remainder, one bit per cycle.
module mm3_udiv(input logic clk,rst,start,input logic[63:0] numerator,denominator,
    output logic done,failed,output logic[63:0] quotient,remainder);
    logic busy;logic[6:0] bit_q;logic[63:0] num,den,q,rem,next_rem;
    logic[64:0] wide_rem;
    always_comb begin wide_rem={rem,1'b0}|65'(num[bit_q[5:0]]);next_rem=64'(wide_rem>=65'(den)?wide_rem-65'(den):wide_rem);end
    always_ff @(posedge clk)begin
        if(rst)begin busy<=0;done<=0;failed<=0;quotient<=0;remainder<=0;num<=0;den<=0;q<=0;rem<=0;bit_q<=0;end
        else begin
            done<=0;
            if(start&&!busy)begin num<=numerator;den<=denominator;bit_q<=63;q<=0;rem<=0;failed<=denominator==0;if(denominator==0)done<=1;else busy<=1;end
            else if(busy)begin
                rem<=next_rem;q[bit_q[5:0]]<=wide_rem>=65'(den);
                if(bit_q==0)begin busy<=0;done<=1;quotient<={q[63:1],wide_rem>=65'(den)};remainder<=next_rem;end
                else bit_q<=bit_q-1;
            end
        end
    end
endmodule
