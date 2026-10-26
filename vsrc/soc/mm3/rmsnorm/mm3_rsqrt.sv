// Module: mm3_rsqrt
// Description: Integer mantissa LUT and registered Newton iterations, with signed exponent restoration.
module mm3_rsqrt(
    input logic clk,rst,start,
    input mm3_fixed_pkg::fixed_t value,
    output logic busy,done,failed,
    output mm3_fixed_pkg::fixed_t result
);
    import mm3_fixed_pkg::*;
    import mm3_config_pkg::*;
    import mm3_tables_pkg::*;
    typedef enum logic[3:0]{IDLE,NORMALIZE,LOOKUP,SQUARE,RNE_SQUARE,PRODUCT,RNE_PRODUCT,CORRECTION,REFINE,RNE_REFINE,RESTORE,FINISH} state_e;
    state_e state;
    fixed_t input_q;
    logic signed [31:0] exponent,k;
    logic parity;
    logic [63:0] t,y,product,y2,ty2,correction,next_y;
    logic [31:0] iteration,index;
    assign busy=state!=IDLE;
    assign exponent=input_q.e+60;
    assign next_y=round128({64'b0,product},31);
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;result<='0;input_q<='0;t<=0;y<=0;product<=0;y2<=0;ty2<=0;correction<=0;k<=0;parity<=0;index<=0;iteration<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin input_q<=value;failed<=value.v<=0;iteration<=0;state<=value.v<=0?FINISH:NORMALIZE;end
                NORMALIZE:begin
                    parity<=exponent[0];k<=(exponent-$signed({31'b0,exponent[0]}))>>>1;
                    t<=round128({64'b0,$unsigned(input_q.v)},32'(30-int'(exponent[0])));
                    index<=(32'($unsigned(input_q.v)>>(60-MM3_RSQRT_LUT_BITS))&((1<<MM3_RSQRT_LUT_BITS)-1))+(32'(exponent[0])<<MM3_RSQRT_LUT_BITS);
                    state<=LOOKUP;
                end
                LOOKUP:begin y<={32'b0,rsqrt_seed(index)};state<=SQUARE;end
                SQUARE:begin product<=y*y;state<=RNE_SQUARE;end
                RNE_SQUARE:begin y2<=round128({64'b0,product},31);state<=PRODUCT;end
                PRODUCT:begin product<=t*y2;state<=RNE_PRODUCT;end
                RNE_PRODUCT:begin ty2<=round128({64'b0,product},30);state<=CORRECTION;end
                CORRECTION:begin
                    if(ty2>=(64'd3<<31))begin failed<=1;state<=FINISH;end
                    else begin correction<=round128({64'b0,(64'd3<<31)-ty2},1);state<=REFINE;end
                end
                REFINE:begin product<=y*correction;state<=RNE_REFINE;end
                RNE_REFINE:begin
                    y<=next_y>(64'd1<<31)?64'd1<<31:next_y;
                    iteration<=iteration+1;state<=iteration+1==MM3_RSQRT_ITERS?RESTORE:SQUARE;
                end
                RESTORE:begin result<=make_fixed($signed(y),-31-k);state<=FINISH;end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
