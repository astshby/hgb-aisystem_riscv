// Module: mm3_ew_add
// Description: Registered scale products, normalization and aligned wide residual sum.
module mm3_ew_add #(parameter int LANES=mm3_config_pkg::MM3_VEC_LANES)(
    input logic clk,rst,start,
    input logic signed[15:0] a[LANES],b[LANES],
    input logic[31:0] am,bm,
    input logic signed[31:0] ae,be,
    output logic done,
    output mm3_fixed_pkg::fixed_t y[LANES]
);
    import mm3_fixed_pkg::*;
    logic[2:0] valid;
    logic signed[63:0] ap[LANES],bp[LANES];
    fixed_t av[LANES],bv[LANES];
    always_ff @(posedge clk)if(rst)begin valid<=0;done<=0;end else begin valid<={valid[1:0],start};done<=valid[2];end
    for(genvar g=0;g<LANES;g++)begin:g_lane
        always_ff @(posedge clk)begin
            if(start)begin ap[g]<=$signed(a[g])*$signed({1'b0,am});bp[g]<=$signed(b[g])*$signed({1'b0,bm});end
            if(valid[0])begin av[g]<=make_fixed(ap[g],ae-31);bv[g]<=make_fixed(bp[g],be-31);end
            if(valid[1])y[g]<=add_fixed(av[g],bv[g]);
        end
    end
endmodule
