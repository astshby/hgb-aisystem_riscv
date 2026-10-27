// Module: mm3_gemm
// Description: Configurable tiled systolic GEMM; signed QK or unsigned-probability PV, tail masking.
module mm3_gemm(
    input logic clk,rst,start,unsigned_a,transpose_b,
    input logic[31:0] m,n,k,a_stride,b_stride,
    input logic[15:0] a[mm3_config_pkg::MM3_GEMM_MAX_M*mm3_config_pkg::MM3_GEMM_MAX_K],
    input logic signed[31:0] b[mm3_config_pkg::MM3_GEMM_MAX_K*mm3_config_pkg::MM3_GEMM_MAX_N],
    output logic busy,done,failed,
    output logic signed[63:0] y[mm3_config_pkg::MM3_GEMM_MAX_M*mm3_config_pkg::MM3_GEMM_MAX_N]
);
    import mm3_config_pkg::*;
    localparam int R=MM3_GEMM_ROWS,C=MM3_GEMM_COLS;
    typedef enum logic[2:0]{IDLE,CLEAR,RUN,COPY,FINISH} state_e;
    state_e state;
    logic[31:0] row,col,step,copy_row,copy_col;
    logic signed[16:0] ax[R][C+1];logic signed[31:0] bx[R+1][C];
    logic av[R][C+1],bv[R+1][C];logic signed[63:0] acc[R][C];
    assign busy=state!=IDLE;
    for(genvar i=0;i<R;i++)begin:g_row
        logic[31:0] ai;
        assign ai=step-32'(i);
        assign av[i][0]=state==RUN&&step>=32'(i)&&ai<k&&row+32'(i)<m;
        assign ax[i][0]=av[i][0]?(unsigned_a?$signed({1'b0,a[(row+32'(i))*a_stride+ai]}):$signed({a[(row+32'(i))*a_stride+ai][15],a[(row+32'(i))*a_stride+ai]})):17'sd0;
        for(genvar j=0;j<C;j++)begin:g_col
            mm3_gemm_pe u_pe(.clk,.rst,.clear(state==CLEAR),.advance(state==RUN),.av(av[i][j]),.bv(bv[i][j]),.a(ax[i][j]),.b(bx[i][j]),.a_valid(av[i][j+1]),.b_valid(bv[i+1][j]),.a_out(ax[i][j+1]),.b_out(bx[i+1][j]),.accumulator(acc[i][j]));
        end
    end
    for(genvar j=0;j<C;j++)begin:g_top
        logic[31:0] bi,offset;
        assign bi=step-32'(j);
        assign offset=transpose_b?(col+32'(j))*b_stride+bi:bi*b_stride+col+32'(j);
        assign bv[0][j]=state==RUN&&step>=32'(j)&&bi<k&&col+32'(j)<n;
        assign bx[0][j]=bv[0][j]?b[offset]:32'sd0;
    end
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;row<=0;col<=0;step<=0;copy_row<=0;copy_col<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    failed<=m==0||n==0||k==0||m>MM3_GEMM_MAX_M||n>MM3_GEMM_MAX_N||k>MM3_GEMM_MAX_K;
                    row<=0;col<=0;state<=m==0||n==0||k==0||m>MM3_GEMM_MAX_M||n>MM3_GEMM_MAX_N||k>MM3_GEMM_MAX_K?FINISH:CLEAR;
                end
                CLEAR:begin step<=0;state<=RUN;end
                RUN:if(step>=k+R+C)begin copy_row<=0;copy_col<=0;state<=COPY;end else step<=step+1;
                COPY:begin
                    if(row+copy_row<m&&col+copy_col<n)y[(row+copy_row)*n+col+copy_col]<=acc[copy_row][copy_col];
                    if(copy_col+1==C)begin
                        copy_col<=0;
                        if(copy_row+1==R)begin
                            if(col+C<n)begin col<=col+C;state<=CLEAR;end
                            else if(row+R<m)begin row<=row+R;col<=0;state<=CLEAR;end
                            else state<=FINISH;
                        end else copy_row<=copy_row+1;
                    end else copy_col<=copy_col+1;
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
