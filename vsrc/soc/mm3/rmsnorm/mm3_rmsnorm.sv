// Module: mm3_rmsnorm
// Description: Buffered integer RMSNorm: pipelined reduction, NR reciprocal sqrt, vector gamma products.
module mm3_rmsnorm(
    input logic clk,rst,start,
    input logic[31:0] n,am,bm,eps_m,
    input logic signed[31:0] ae,be,eps_e,
    input logic signed[15:0] a[mm3_config_pkg::MM3_MAX_VECTOR],b[mm3_config_pkg::MM3_MAX_VECTOR],
    output logic busy,done,failed,
    output mm3_fixed_pkg::fixed_t work[mm3_config_pkg::MM3_MAX_VECTOR]
);
    import mm3_config_pkg::*;import mm3_fixed_pkg::*;import mm3_tables_pkg::*;
    localparam int L=MM3_VEC_LANES;
    typedef enum logic[3:0]{IDLE,REDUCE_START,REDUCE_WAIT,M_START,M_WAIT,R_START,R_WAIT,V_START,V_WAIT,FINISH} state_e;
    state_e state;
    logic[31:0] phase,index;
    logic[63:0] sum;
    logic reduce_done,math_done,rsqrt_done,rsqrt_failed,lanes_done;
    fixed_t ma,mb,mresult,sx2,variance,gfactor,inverse,factor,mean_eps;
    fixed_t va[L],vb[L],vy[L];
    logic signed[15:0] reduce_x[MM3_NORM_MAX_LEN];
    always_comb for(int i=0;i<MM3_NORM_MAX_LEN;i++)reduce_x[i]=a[i];
    assign busy=state!=IDLE;
    mm3_reduce u_reduce(.clk,.rst,.start(state==REDUCE_START),.n,.x(reduce_x),.busy(),.done(reduce_done),.sum);
    always_comb begin
        ma='0;mb='0;
        case(phase)
            0:begin ma=scale_fixed(am,ae);mb=ma;end
            1:begin ma=make_fixed($signed(sum),0);mb=sx2;end
            2:begin ma=variance;mb=make_fixed($signed(length_recip(n)),-48);end
            3:begin ma=scale_fixed(am,ae);mb=scale_fixed(bm,be);end
            4:begin ma=gfactor;mb=inverse;end
            default:;
        endcase
        for(int g=0;g<L;g++)begin
            va[g]=index+32'(g)<n?make_fixed(64'($signed(a[index+32'(g)])*$signed(b[index+32'(g)])),0):make_fixed(0,0);
            vb[g]=factor;
        end
    end
    mm3_fixed_math u_scalar(.clk,.rst,.start(state==M_START),.divide(1'b0),.a(ma),.b(mb),.busy(),.done(math_done),.result(mresult));
    mm3_rsqrt u_rsqrt(.clk,.rst,.start(state==R_START),.value(mean_eps),.busy(),.done(rsqrt_done),.failed(rsqrt_failed),.result(inverse));
    mm3_mul_lanes u_lanes(.clk,.rst,.start(state==V_START),.divide(1'b0),.a(va),.b(vb),.busy(),.done(lanes_done),.y(vy));
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;phase<=0;index<=0;sx2<='0;variance<='0;gfactor<='0;factor<='0;mean_eps<='0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin failed<=n==0||n>MM3_NORM_MAX_LEN;state<=n==0||n>MM3_NORM_MAX_LEN?FINISH:REDUCE_START;phase<=0;index<=0;end
                REDUCE_START:state<=REDUCE_WAIT;
                REDUCE_WAIT:if(reduce_done)state<=M_START;
                M_START:state<=M_WAIT;
                M_WAIT:if(math_done)begin
                    case(phase)
                        0:begin sx2<=mresult;phase<=1;state<=M_START;end
                        1:begin variance<=mresult;phase<=2;state<=M_START;end
                        2:begin mean_eps<=add_fixed(mresult,scale_fixed(eps_m,eps_e));state<=R_START;end
                        3:begin gfactor<=mresult;phase<=4;state<=M_START;end
                        4:begin factor<=mresult;state<=V_START;end
                        default:state<=FINISH;
                    endcase
                end
                R_START:state<=R_WAIT;
                R_WAIT:if(rsqrt_done)begin if(rsqrt_failed)begin failed<=1;state<=FINISH;end else begin phase<=3;state<=M_START;end end
                V_START:state<=V_WAIT;
                V_WAIT:if(lanes_done)begin
                    for(int g=0;g<L;g++)if(index+32'(g)<n)work[index+32'(g)]<=vy[g];
                    if(index+L>=n)state<=FINISH;else begin index<=index+L;state<=V_START;end
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
