// Module: mm3_rope_lane
// Description: Front/back pairing with pre-exported integer Q1.15 sin/cos.
module mm3_rope_lane(
    input logic clk,rst,start,
    input logic signed[15:0] a,b,co,si,
    output logic done,
    output logic signed[63:0] front,back
);
    logic signed[31:0] ac,bs,bc,asine;
    logic valid;
    always_ff @(posedge clk)begin
        if(rst)begin valid<=0;done<=0;end
        else begin
            valid<=start;done<=valid;
            if(start)begin ac<=$signed(a)*$signed(co);bs<=$signed(b)*$signed(si);bc<=$signed(b)*$signed(co);asine<=$signed(a)*$signed(si);end
            if(valid)begin front<=64'(ac)-64'(bs);back<=64'(bc)+64'(asine);end
        end
    end
endmodule
