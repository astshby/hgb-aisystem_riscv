// Module: mm3_sigmoid
// Description: Existing UINT16 sigmoid table and RNE linear interpolation; integer only.
module mm3_sigmoid(
    input logic signed[15:0] x,
    input logic[31:0] scale_m,
    input logic signed[31:0] scale_e,
    input logic[15:0] lut[8193],
    output logic[15:0] value,
    output logic outside
);
    import mm3_fixed_pkg::*;
    fixed_t real_x;
    logic signed[31:0] q;
    logic[31:0] offset,index,fraction;
    logic[63:0] interpolated;
    always_comb begin
        real_x=make_fixed(64'($signed(x)*$signed({1'b0,scale_m})),scale_e-15);
        q=integer32(real_x);offset=0;index=0;fraction=0;interpolated=0;outside=0;value=0;
        if(q < -1048576)outside=1;
        else if(q > 1048576)begin outside=1;value=65535;end
        else begin
            offset=32'(q+1048576);index=offset>>8;fraction=offset&255;
            if(index>=8192)value=lut[8192];
            else begin interpolated=64'(lut[index])*(256-64'(fraction))+64'(lut[index+1])*64'(fraction);value=16'(round128({64'b0,interpolated},8));end
        end
    end
endmodule
