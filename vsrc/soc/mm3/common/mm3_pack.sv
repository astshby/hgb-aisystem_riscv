// Module: mm3_pack
// Description: Vector-wide absmax, dynamic scale and RNE integer output. No floating point.
module mm3_pack #(parameter int MAX_N=mm3_config_pkg::MM3_MAX_VECTOR)(
    input logic clk,rst,start,bits32,
    input logic [31:0] n,
    input mm3_fixed_pkg::fixed_t values[MAX_N],
    output logic busy,done,failed,
    output logic signed [31:0] y[MAX_N],
    output logic [31:0] scale_m,
    output logic signed [31:0] scale_e,
    output logic [63:0] saturated,underflow
);
    import mm3_fixed_pkg::*;
    typedef enum logic[2:0]{IDLE,SCAN,SCALE_START,SCALE_WAIT,PACK_START,PACK_WAIT,FINISH} state_e;
    state_e state;
    logic [31:0] index,len;
    fixed_t maximum,a,b,result;
    logic go,mdone;
    logic [63:0] cm;
    assign busy=state!=IDLE;
    assign go=state==SCALE_START||state==PACK_START;
    assign a=state==SCALE_START?maximum:values[index];
    assign b=state==SCALE_START?make_fixed(bits32?64'sh7fffffff:64'sh7fff,0):scale_fixed(scale_m,scale_e);
    assign cm=(magnitude(result.v)+64'h3fffffff)>>30;
    mm3_fixed_math u_math(.clk,.rst,.start(go),.divide(1'b1),.a,.b,.busy(),.done(mdone),.result);
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;index<=0;len<=0;maximum<='0;scale_m<=0;scale_e<=0;saturated<=0;underflow<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    failed<=n==0||n>MAX_N;saturated<=0;underflow<=0;index<=0;len<=n;maximum<='0;
                    state<=n==0||n>MAX_N?FINISH:SCAN;
                end
                SCAN:begin
                    if(abs_greater(values[index],maximum))begin maximum.v<=$signed(magnitude(values[index].v));maximum.e<=values[index].e;end
                    if(index+1==len)begin index<=0;state<=SCALE_START;end else index<=index+1;
                end
                SCALE_START:state<=SCALE_WAIT;
                SCALE_WAIT:if(mdone)begin
                    if(maximum.v==0)begin scale_m<=32'h40000000;scale_e<=1;end
                    else begin scale_m<=32'(cm>=(64'd1<<31)?(cm+1)>>1:cm);scale_e<=result.e+61+(cm>=(64'd1<<31)?1:0);end
                    state<=PACK_START;
                end
                PACK_START:state<=PACK_WAIT;
                PACK_WAIT:if(mdone)begin
                    y[index]<=result.v<0?-$signed(32'(integer_mag(result,bits32))):$signed(32'(integer_mag(result,bits32)));
                    if(quant_saturated(result,bits32))saturated<=saturated+1;
                    if(result.v!=0&&integer_mag(result,bits32)==0)underflow<=underflow+1;
                    if(index+1==len)state<=FINISH;else begin index<=index+1;state<=PACK_START;end
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
