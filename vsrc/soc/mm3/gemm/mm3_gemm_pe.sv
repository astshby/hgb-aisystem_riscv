// Module: mm3_gemm_pe
// Description: Registered systolic movement, registered integer product and INT64 accumulation.
module mm3_gemm_pe(
    input logic clk,rst,clear,advance,av,bv,
    input logic signed[16:0] a,
    input logic signed[31:0] b,
    output logic a_valid,b_valid,
    output logic signed[16:0] a_out,
    output logic signed[31:0] b_out,
    output logic signed[63:0] accumulator
);
    logic valid;
    logic signed[48:0] product;
    always_ff @(posedge clk)begin
        if(rst||clear)begin a_valid<=0;b_valid<=0;valid<=0;accumulator<=0;product<=0;a_out<=0;b_out<=0;end
        else if(advance)begin
            a_out<=a;b_out<=b;a_valid<=av;b_valid<=bv;valid<=av&&bv;
            if(av&&bv)product<=$signed(a)*$signed(b);
            if(valid)accumulator<=accumulator+64'(product);
        end
    end
endmodule
