// Module: mm3_softmax
// Description: Q16.16 scores, integer exp interpolation and stable largest-remainder UINT16 probabilities.
module mm3_softmax(
    input logic clk,rst,start,
    input logic[31:0] n,
    input logic signed[31:0] scores[mm3_config_pkg::MM3_SEQ_CAP],
    input logic[31:0] exp_lut[4097],
    output logic busy,done,failed,
    output logic[15:0] probabilities[mm3_config_pkg::MM3_SEQ_CAP]
);
    import mm3_config_pkg::*;import mm3_fixed_pkg::*;
    typedef enum logic[3:0]{IDLE,MAXIMUM,EXPONENTS,D_START,D_WAIT,SELECT_INIT,SELECT_SCAN,SELECT_SWAP,FINISH} state_e;
    state_e state;
    logic signed[31:0] maximum;
    logic[31:0] index,assigned,left,selection,j,best,order[MM3_SEQ_CAP];
    logic[63:0] remainders[MM3_SEQ_CAP],sum,numerator,quotient,remainder;
    logic ddone,dfailed,better;
    logic signed[63:0] difference;
    logic[63:0] t,interpolation;
    logic[31:0] table_index,fraction,exp_value;
    assign busy=state!=IDLE;
    always_comb begin
        difference=64'(scores[index])-64'(maximum);t=$unsigned(-difference);table_index=32'(t>>8);fraction=32'(t&255);interpolation=0;exp_value=0;
        if(difference>=0)exp_value=32'h80000000;
        else if(difference>=-1048576)begin
            if(table_index>=4096)exp_value=exp_lut[4096];
            else begin interpolation=64'(exp_lut[table_index])*(256-64'(fraction))+64'(exp_lut[table_index+1])*64'(fraction);exp_value=32'(round128({64'b0,interpolation},8));end
        end
        numerator=remainders[index]*65535;
        better=remainders[order[j]]>remainders[order[best]]||(remainders[order[j]]==remainders[order[best]]&&order[j]<order[best]);
    end
    mm3_udiv u_div(.clk,.rst,.start(state==D_START),.numerator,.denominator(sum),.done(ddone),.failed(dfailed),.quotient,.remainder);
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;index<=0;maximum<=0;sum<=0;assigned<=0;left<=0;selection<=0;j<=0;best<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin failed<=n==0||n>MM3_SEQ_CAP;state<=n==0||n>MM3_SEQ_CAP?FINISH:MAXIMUM;maximum<=scores[0];index<=0;sum<=0;assigned<=0;end
                MAXIMUM:begin if(scores[index]>maximum)maximum<=scores[index];if(index+1==n)begin index<=0;state<=EXPONENTS;end else index<=index+1;end
                EXPONENTS:begin remainders[index]<=64'(exp_value);sum<=sum+64'(exp_value);order[index]<=index;if(index+1==n)begin index<=0;state<=D_START;end else index<=index+1;end
                D_START:state<=D_WAIT;
                D_WAIT:if(ddone)begin
                    probabilities[index]<=16'(quotient);remainders[index]<=remainder;assigned<=assigned+32'(quotient);
                    if(dfailed)begin failed<=1;state<=FINISH;end
                    else if(index+1==n)state<=SELECT_INIT;else begin index<=index+1;state<=D_START;end
                end
                SELECT_INIT:begin left<=65535-assigned;selection<=0;best<=0;j<=1;state<=assigned==65535?FINISH:SELECT_SCAN;end
                SELECT_SCAN:begin
                    if(j<n)begin if(better)best<=j;if(j+1==n)state<=SELECT_SWAP;else j<=j+1;end
                    else state<=SELECT_SWAP;
                end
                SELECT_SWAP:begin
                    probabilities[order[best]]<=probabilities[order[best]]+1;
                    order[selection]<=order[best];order[best]<=order[selection];
                    if(selection+1==left)state<=FINISH;else begin selection<=selection+1;best<=selection+1;j<=selection+2;state<=SELECT_SCAN;end
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
