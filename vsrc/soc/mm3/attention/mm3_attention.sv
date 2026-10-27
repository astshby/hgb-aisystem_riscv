// Module: mm3_attention
// Description: GQA QK/PV orchestration using one shared GEMM and Softmax; per-position KV scales preserved.
module mm3_attention(
    input logic clk,rst,start,
    input logic[31:0] length,invsqrt_m,
    input logic signed[31:0] invsqrt_e,
    input logic signed[15:0] q[mm3_config_pkg::MM3_HIDDEN_SIZE],
    input logic[31:0] qm[mm3_config_pkg::MM3_QUERY_HEADS],
    input logic signed[31:0] qe[mm3_config_pkg::MM3_QUERY_HEADS],
    input logic signed[15:0] keys[mm3_config_pkg::MM3_SEQ_CAP*384],values[mm3_config_pkg::MM3_SEQ_CAP*384],
    input logic[31:0] km[mm3_config_pkg::MM3_SEQ_CAP*4],vm[mm3_config_pkg::MM3_SEQ_CAP*4],
    input logic signed[31:0] ke[mm3_config_pkg::MM3_SEQ_CAP*4],ve[mm3_config_pkg::MM3_SEQ_CAP*4],
    output logic busy,done,failed,
    output logic gemm_start,gemm_pv,gemm_transpose,
    output logic[31:0] gemm_m,gemm_n,gemm_k,
    output logic[15:0] gemm_a[mm3_config_pkg::MM3_GEMM_MAX_M*mm3_config_pkg::MM3_GEMM_MAX_K],
    output logic signed[31:0] gemm_b[mm3_config_pkg::MM3_GEMM_MAX_K*mm3_config_pkg::MM3_GEMM_MAX_N],
    input logic gemm_done,gemm_failed,
    input logic signed[63:0] gemm_y[mm3_config_pkg::MM3_GEMM_MAX_M*mm3_config_pkg::MM3_GEMM_MAX_N],
    output logic softmax_start,
    output logic signed[31:0] scores[mm3_config_pkg::MM3_SEQ_CAP],
    input logic softmax_done,softmax_failed,
    input logic[15:0] probabilities[mm3_config_pkg::MM3_SEQ_CAP],
    output mm3_fixed_pkg::fixed_t work[mm3_config_pkg::MM3_MAX_VECTOR]
);
    import mm3_config_pkg::*;import mm3_fixed_pkg::*;
    typedef enum logic[4:0]{IDLE,BUILD_Q,QK_START,QK_WAIT,M_START,M_WAIT,SOFT_START,SOFT_WAIT,BASE_SCAN,BASE_FINISH,PV_START,PV_WAIT,FINISH} state_e;
    state_e state;
    logic[31:0] head,t,d,index,phase,base_m;
    logic signed[31:0] base_e;
    logic found,nonzero,choose_base;
    logic mdone;
    fixed_t ma,mb,mresult,qfactor,score_partial,ratio,pvfactor;
    logic[31:0] kh,slot;
    assign kh=head/2;assign slot=t*4+kh;
    assign busy=state!=IDLE;
    assign gemm_start=state==QK_START||state==PV_START;
    assign gemm_pv=state==PV_START||state==PV_WAIT;
    assign gemm_transpose=!gemm_pv;
    assign gemm_m=1;assign gemm_n=gemm_pv?96:length;assign gemm_k=gemm_pv?length:96;
    assign softmax_start=state==SOFT_START;
    assign choose_base=!found||ve[slot]>base_e||(ve[slot]==base_e&&vm[slot]>base_m);
    always_comb begin
        ma='0;mb='0;
        case(phase)
            0:begin ma=scale_fixed(qm[head],qe[head]);mb=scale_fixed(invsqrt_m,invsqrt_e);end
            1:begin ma=make_fixed(gemm_y[t],0);mb=qfactor;end
            2:begin ma=score_partial;mb=scale_fixed(km[slot],ke[slot]);end
            3:begin ma=scale_fixed(vm[slot],ve[slot]);mb=scale_fixed(base_m,base_e);end
            4:begin ma=make_fixed(64'(values[t*384+kh*96+d]),0);mb=ratio;end
            5:begin ma=scale_fixed(base_m,base_e);mb=make_fixed(65535,0);end
            6:begin ma=make_fixed(gemm_y[d],0);mb=pvfactor;end
            default:;
        endcase
    end
    mm3_fixed_math u_math(.clk,.rst,.start(state==M_START),.divide(phase==3||phase==5),.a(ma),.b(mb),.busy(),.done(mdone),.result(mresult));
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;head<=0;t<=0;d<=0;index<=0;phase<=0;base_m<=32'h40000000;base_e<=1;found<=0;nonzero<=0;qfactor<='0;score_partial<='0;ratio<='0;pvfactor<='0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin failed<=length==0||length>MM3_SEQ_CAP;head<=0;index<=0;state<=length==0||length>MM3_SEQ_CAP?FINISH:BUILD_Q;end
                BUILD_Q:begin
                    if(index<96)gemm_a[index]<=q[head*96+index];
                    gemm_b[index]<=32'(keys[(index/96)*384+kh*96+index%96]);
                    if(index+1==length*96)state<=QK_START;else index<=index+1;
                end
                QK_START:state<=QK_WAIT;
                QK_WAIT:if(gemm_done)begin if(gemm_failed)begin failed<=1;state<=FINISH;end else begin phase<=0;t<=0;state<=M_START;end end
                M_START:state<=M_WAIT;
                M_WAIT:if(mdone)begin
                    case(phase)
                        0:begin qfactor<=mresult;phase<=1;state<=M_START;end
                        1:begin score_partial<=mresult;phase<=2;state<=M_START;end
                        2:begin
                            scores[t]<=integer32('{v:mresult.v,e:mresult.e+16});
                            if(t+1==length)state<=SOFT_START;else begin t<=t+1;phase<=1;state<=M_START;end
                        end
                        3:begin ratio<=mresult;d<=0;phase<=4;gemm_a[t]<=probabilities[t];state<=M_START;end
                        4:begin
                            gemm_b[t*96+d]<=integer32(mresult);
                            if(d==95)begin
                                if(t+1==length)state<=PV_START;else begin t<=t+1;phase<=3;state<=M_START;end
                            end else begin d<=d+1;state<=M_START;end
                        end
                        5:begin pvfactor<=mresult;d<=0;phase<=6;state<=M_START;end
                        6:begin
                            work[head*96+d]<=mresult;
                            if(d==95)begin if(head==7)state<=FINISH;else begin head<=head+1;index<=0;state<=BUILD_Q;end end
                            else begin d<=d+1;state<=M_START;end
                        end
                        default:begin failed<=1;state<=FINISH;end
                    endcase
                end
                SOFT_START:state<=SOFT_WAIT;
                SOFT_WAIT:if(softmax_done)begin if(softmax_failed)begin failed<=1;state<=FINISH;end else begin t<=0;d<=0;found<=0;nonzero<=0;base_m<=32'h40000000;base_e<=1;state<=BASE_SCAN;end end
                BASE_SCAN:begin
                    nonzero<=nonzero||values[t*384+kh*96+d]!=0;
                    if(d==95)begin
                        if((nonzero||values[t*384+kh*96+d]!=0)&&choose_base)begin base_m<=vm[slot];base_e<=ve[slot];found<=1;end
                        nonzero<=0;d<=0;
                        if(t+1==length)state<=BASE_FINISH;else t<=t+1;
                    end else d<=d+1;
                end
                BASE_FINISH:begin base_e<=base_e-14;t<=0;phase<=3;state<=M_START;end
                PV_START:state<=PV_WAIT;
                PV_WAIT:if(gemm_done)begin if(gemm_failed)begin failed<=1;state<=FINISH;end else begin phase<=5;state<=M_START;end end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
