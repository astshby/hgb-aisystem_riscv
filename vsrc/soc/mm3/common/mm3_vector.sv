// Module: mm3_vector
// Description: ADD/MUL/SwiGLU/RoPE controller with registered vector lanes and shared scale arithmetic.
module mm3_vector(
    input logic clk,rst,start,
    input logic[31:0] op,n,am,bm,
    input logic signed[31:0] ae,be,
    input logic signed[15:0] a[mm3_config_pkg::MM3_MAX_VECTOR],b[mm3_config_pkg::MM3_MAX_VECTOR],
    input logic[15:0] sigmoid_lut[8193],
    output logic busy,done,failed,
    output mm3_fixed_pkg::fixed_t work[mm3_config_pkg::MM3_MAX_VECTOR]
);
    import mm3_config_pkg::*;import mm3_fixed_pkg::*;
    localparam int L=MM3_VEC_LANES;
    typedef enum logic[3:0]{IDLE,F_START,F_WAIT,D_START,D_WAIT,G_START,G_WAIT,V_START,V_WAIT,ROPE_START,ROPE_WAIT,ROPE_FRONT,ROPE_BACK,FINISH} state_e;
    state_e state;
    logic[31:0] index;
    logic signed[15:0] av[L],bv[L];
    logic signed[63:0] product[L],front,back;
    fixed_t added[L],va[L],vb[L],vy[L],factor,ma,mb,mresult;
    logic[15:0] sig[L];
    logic add_done,mul_done,math_done,lanes_done,rope_done;
    logic divide;
    for(genvar g=0;g<L;g++)begin:g_input
        assign av[g]=index+32'(g)<n?a[index+32'(g)]:16'sd0;
        assign bv[g]=index+32'(g)<n?b[index+32'(g)]:16'sd0;
        mm3_sigmoid u_sig(.x(av[g]),.scale_m(am),.scale_e(ae),.lut(sigmoid_lut),.value(sig[g]),.outside());
        assign va[g]=make_fixed(op==6?product[g]*$signed({1'b0,sig[g]}):product[g],0);
        assign vb[g]=factor;
    end
    mm3_ew_add u_add(.clk,.rst,.start(state==G_START&&op==1),.a(av),.b(bv),.am,.bm,.ae,.be,.done(add_done),.y(added));
    mm3_ew_mul u_mul(.clk,.rst,.start(state==G_START&&op!=1),.a(av),.b(bv),.done(mul_done),.product);
    assign divide=state==D_START;
    assign ma=divide?factor:scale_fixed(am,ae);
    assign mb=divide?make_fixed(65535,0):scale_fixed(bm,be);
    mm3_fixed_math u_math(.clk,.rst,.start(state==F_START||state==D_START),.divide,.a(ma),.b(mb),.busy(),.done(math_done),.result(mresult));
    mm3_mul_lanes u_lanes(.clk,.rst,.start(state==V_START),.divide(1'b0),.a(va),.b(vb),.busy(),.done(lanes_done),.y(vy));
    mm3_rope_lane u_rope(.clk,.rst,.start(state==ROPE_START),.a(a[index]),.b(a[index+48]),.co(b[2*index]),.si(b[2*index+1]),.done(rope_done),.front,.back);
    assign busy=state!=IDLE;
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;index<=0;factor<='0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    failed<=n==0||n>MM3_MAX_VECTOR||(op==4&&n!=96);index<=0;
                    if(n==0||n>MM3_MAX_VECTOR||(op==4&&n!=96))state<=FINISH;
                    else state<=op==4?ROPE_START:op==1?G_START:F_START;
                end
                F_START:state<=F_WAIT;
                F_WAIT:if(math_done)begin factor<=mresult;state<=op==6?D_START:G_START;end
                D_START:state<=D_WAIT;
                D_WAIT:if(math_done)begin factor<=mresult;state<=G_START;end
                G_START:state<=G_WAIT;
                G_WAIT:if(op==1?add_done:mul_done)begin
                    if(op==1)begin
                        for(int g=0;g<L;g++)if(index+32'(g)<n)work[index+32'(g)]<=added[g];
                        if(index+L>=n)state<=FINISH;else begin index<=index+L;state<=G_START;end
                    end else state<=V_START;
                end
                V_START:state<=V_WAIT;
                V_WAIT:if(lanes_done)begin
                    for(int g=0;g<L;g++)if(index+32'(g)<n)work[index+32'(g)]<=vy[g];
                    if(index+L>=n)state<=FINISH;else begin index<=index+L;state<=G_START;end
                end
                ROPE_START:state<=ROPE_WAIT;
                ROPE_WAIT:if(rope_done)state<=ROPE_FRONT;
                ROPE_FRONT:begin work[index]<=make_fixed(front*$signed({1'b0,am}),ae-46);state<=ROPE_BACK;end
                ROPE_BACK:begin work[index+48]<=make_fixed(back*$signed({1'b0,am}),ae-46);if(index==47)state<=FINISH;else begin index<=index+1;state<=ROPE_START;end end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
