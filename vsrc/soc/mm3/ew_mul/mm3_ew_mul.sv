// Module: mm3_ew_mul
// Description: Registered signed INT16 products; no intermediate INT16 requantization.
module mm3_ew_mul #(parameter int LANES=mm3_config_pkg::MM3_VEC_LANES)(
    input logic clk,rst,start,
    input logic signed[15:0] a[LANES],b[LANES],
    output logic done,
    output logic signed[63:0] product[LANES]
);
    always_ff @(posedge clk)if(rst)done<=0;else done<=start;
    for(genvar g=0;g<LANES;g++)begin:g_lane
        always_ff @(posedge clk)if(start)product[g]<=64'($signed(a[g])*$signed(b[g]));
    end
endmodule
