// Module: mm3_reduce
// Description: Signed INT16 squares, registered balanced tree and INT64 accumulation with tail masking.
module mm3_reduce #(parameter int LANES=mm3_config_pkg::MM3_VEC_LANES,parameter int MAX_N=mm3_config_pkg::MM3_NORM_MAX_LEN)(
    input logic clk,rst,start,
    input logic[31:0] n,
    input logic signed[15:0] x[MAX_N],
    output logic busy,done,
    output logic[63:0] sum
);
    localparam int DEPTH=$clog2(LANES);
    logic[63:0] tree[DEPTH+1][LANES];
    logic[DEPTH:0] valid,last;
    logic feeding;
    logic[31:0] index;
    for(genvar g=0;g<LANES;g++)begin:g_square
        logic signed[31:0] square;
        always_comb square=index+32'(g)<n?$signed(x[index+32'(g)])*$signed(x[index+32'(g)]):0;
        always_ff @(posedge clk)if(feeding)tree[0][g]<={32'b0,$unsigned(square)};
    end
    for(genvar level=0;level<DEPTH;level++)begin:g_level
        for(genvar node=0;node<(LANES>>(level+1));node++)begin:g_node
            always_ff @(posedge clk)if(valid[level])tree[level+1][node]<=tree[level][2*node]+tree[level][2*node+1];
        end
    end
    always_ff @(posedge clk)begin
        if(rst)begin feeding<=0;busy<=0;done<=0;index<=0;sum<=0;valid<=0;last<=0;end
        else begin
            done<=0;valid[0]<=feeding;
            if(feeding)begin last[0]<=index+LANES>=n;index<=index+LANES;if(index+LANES>=n)feeding<=0;end
            for(int l=0;l<DEPTH;l++)begin valid[l+1]<=valid[l];if(valid[l])last[l+1]<=last[l];end
            if(start&&!busy)begin feeding<=1;busy<=1;sum<=0;index<=0;valid<=0;last<=0;end
            else if(valid[DEPTH])begin sum<=sum+tree[DEPTH][0];if(last[DEPTH])begin done<=1;busy<=0;end end
        end
    end
endmodule
