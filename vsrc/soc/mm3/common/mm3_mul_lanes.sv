// Module: mm3_mul_lanes
// Description: Registered multi-cycle integer lane group; zero lanes may finish earlier.
module mm3_mul_lanes #(parameter int LANES=mm3_config_pkg::MM3_VEC_LANES)(
    input logic clk,rst,start,divide,
    input mm3_fixed_pkg::fixed_t a[LANES],b[LANES],
    output logic busy,done,
    output mm3_fixed_pkg::fixed_t y[LANES]
);
    logic [LANES-1:0] lane_done,seen;
    for(genvar g=0;g<LANES;g++)begin:g_lane
        mm3_fixed_pkg::fixed_t result;
        mm3_fixed_math u_math(.clk,.rst,.start(start&&!busy),.divide,.a(a[g]),.b(b[g]),.busy(),.done(lane_done[g]),.result);
        always_ff @(posedge clk)if(!rst&&lane_done[g])y[g]<=result;
    end
    always_ff @(posedge clk)begin
        if(rst)begin busy<=0;done<=0;seen<=0;end
        else begin
            done<=0;
            if(start&&!busy)begin busy<=1;seen<=0;end
            else if(busy)begin
                seen<=seen|lane_done;
                if(&(seen|lane_done))begin busy<=0;done<=1;end
            end
        end
    end
endmodule
