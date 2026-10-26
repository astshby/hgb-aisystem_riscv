// Module: mm3_ops_engine
// Description: Descriptor DMA, bounded operand SRAM, shared compute engines and masked DDR writeback.
module mm3_ops_engine #(
    parameter int unsigned DDR_BYTES=128*1024*1024
)(
    input logic clk,rst,start,
    input logic[31:0] descriptor_address,expected_op,
    output logic busy,done,failed,
    output logic[31:0] error_code,
    output logic[63:0] saturated,underflow,
    output logic rd_cmd_valid,input logic rd_cmd_ready,output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,output logic rd_ready,input block_types_pkg::block_r_t rd_data,
    output logic wr_cmd_valid,input logic wr_cmd_ready,output block_types_pkg::block_cmd_t wr_cmd,
    output logic wr_valid,input logic wr_ready,output block_types_pkg::block_w_t wr_data,
    input logic wr_rsp_valid,output logic wr_rsp_ready,input block_types_pkg::block_b_t wr_rsp
);
    import mm3_config_pkg::*;import mm3_fixed_pkg::*;import block_types_pkg::*;import bus_types_pkg::*;
    localparam int AW=(MM3_MAX_VECTOR*4>MM3_GEMM_MAX_M*MM3_GEMM_MAX_K*2?MM3_MAX_VECTOR*4:MM3_GEMM_MAX_M*MM3_GEMM_MAX_K*2)/4;
    localparam int BW=(MM3_GEMM_MAX_K*MM3_GEMM_MAX_N*4>MM3_MAX_VECTOR*2?MM3_GEMM_MAX_K*MM3_GEMM_MAX_N*4:MM3_MAX_VECTOR*2)/4;
    logic[31:0] abuf[AW],bbuf[BW],asbuf[16],bsbuf[8],auxbuf[4097];
    logic[31:0] kbuf[MM3_SEQ_CAP*192],vbuf[MM3_SEQ_CAP*192],ksbuf[MM3_SEQ_CAP*8],vsbuf[MM3_SEQ_CAP*8];
    logic[31:0] desc[32];
    logic signed[15:0] av[MM3_MAX_VECTOR],bv[MM3_MAX_VECTOR];
    logic signed[15:0] attq[768];
    always_comb for(int i=0;i<768;i++)attq[i]=av[i];
    logic[15:0] siglut[8193];logic[31:0] explut[4097];
    logic signed[15:0] keys[MM3_SEQ_CAP*384],values[MM3_SEQ_CAP*384];
    logic[31:0] qm[8],km[MM3_SEQ_CAP*4],vm[MM3_SEQ_CAP*4];
    logic signed[31:0] qe[8],ke[MM3_SEQ_CAP*4],ve[MM3_SEQ_CAP*4];
    logic[15:0] raw_ga[MM3_GEMM_MAX_M*MM3_GEMM_MAX_K],att_ga[MM3_GEMM_MAX_M*MM3_GEMM_MAX_K],ga[MM3_GEMM_MAX_M*MM3_GEMM_MAX_K];
    logic signed[31:0] raw_gb[MM3_GEMM_MAX_K*MM3_GEMM_MAX_N],att_gb[MM3_GEMM_MAX_K*MM3_GEMM_MAX_N],gb[MM3_GEMM_MAX_K*MM3_GEMM_MAX_N];
    logic signed[63:0] gy[MM3_GEMM_MAX_M*MM3_GEMM_MAX_N];
    logic signed[31:0] raw_scores[MM3_SEQ_CAP],att_scores[MM3_SEQ_CAP],scores[MM3_SEQ_CAP];
    logic[15:0] probabilities[MM3_SEQ_CAP];
    fixed_t vwork[MM3_MAX_VECTOR],nwork[MM3_MAX_VECTOR],awork[MM3_MAX_VECTOR],work[MM3_MAX_VECTOR];
    logic signed[31:0] packed_values[MM3_MAX_VECTOR];logic[31:0] packed_m;logic signed[31:0] packed_e;
    logic norm_done,norm_fail,vec_done,vec_fail,att_done,att_fail,gemm_done,gemm_fail,soft_done,soft_fail,pack_done,pack_fail;
    logic agstart,agpv,agtrans,asstart;logic[31:0] agm,agn,agk;
    logic reader_start,reader_busy,reader_failed,stream_valid,stream_ready,stream_last;
    logic[31:0] reader_address,reader_bytes;logic[255:0] stream_data;logic[5:0] stream_count;
    typedef enum logic[4:0]{IDLE,D_START,D_LOAD,VALIDATE,K_START,K_WAIT,LOAD_SELECT,LOAD_START,LOAD_DATA,COMPUTE_START,COMPUTE_WAIT,PACK_START,PACK_WAIT,WRITE_SELECT,WRITE_CMD,WRITE_DATA,WRITE_WAIT,FINISH} state_e;
    state_e state;
    logic[31:0] load_slot,load_bank,load_address,load_bytes,load_offset,write_slot,output_address,output_bytes,write_address;
    logic[31:0] op,n;logic kv_valid,kv_fail;logic[31:0] ka,va,ksa,vsa;
    logic[63:0] region_end,a_span,b_span;
    logic[31:0] a_stride,b_stride;
    assign a_stride=desc[25]!=0?desc[25]:desc[4];
    assign b_stride=desc[26]!=0?desc[26]:desc[5][1]?desc[4]:n;
    assign a_span=64'(desc[3]-1)*64'(a_stride)+64'(desc[4]);
    assign b_span=((desc[5][1]?64'(n):64'(desc[4]))-64'd1)*64'(b_stride)+(desc[5][1]?64'(desc[4]):64'(n));
    assign op=desc[1];assign n=desc[2];assign busy=state!=IDLE;
    logic scales_valid;
    function automatic logic scale_ok(input logic[31:0] m,e);
        return m>=32'h40000000&&m<32'h80000000&&$signed(e)>=-256&&$signed(e)<=256;
    endfunction
    always_comb begin
        scales_valid=1;
        if(op!=5&&op!=7)begin
            for(int i=0;i<8;i++)if(i<(op==9?8:op==8?4:1))
                if(!scale_ok(asbuf[2*i],asbuf[2*i+1]))scales_valid=0;
            if(op!=9)for(int i=0;i<4;i++)if(i<(op==8?(desc[5][1]&&!desc[5][0]?1:4):1))
                if(!scale_ok(bsbuf[2*i],bsbuf[2*i+1]))scales_valid=0;
        end
        if(op==3&&!scale_ok(desc[16],desc[17]))scales_valid=0;
        if(op==9)begin
            if(!scale_ok(desc[23],desc[24]))scales_valid=0;
            for(int i=0;i<MM3_SEQ_CAP*4;i++)if(i<int'(desc[15]*4))
                if(!scale_ok(ksbuf[2*i],ksbuf[2*i+1])||!scale_ok(vsbuf[2*i],vsbuf[2*i+1]))scales_valid=0;
        end
    end
    function automatic logic region_ok(input logic[31:0] address,bytes);
        logic[63:0] endpoint;
        endpoint=64'(address)+64'(bytes);
        return address>=32'h80000000&&bytes!=0&&((endpoint+31)&~64'd31)<=64'h80000000+64'(DDR_BYTES);
    endfunction
    function automatic logic[31:0] bank_word(input logic[31:0] bank,index);
        case(bank)
            0:return abuf[index];1:return bbuf[index];2:return asbuf[index];3:return bsbuf[index];4:return auxbuf[index];
            5:return kbuf[index];6:return vbuf[index];7:return ksbuf[index];8:return vsbuf[index];9:return desc[index];
            default:return 0;
        endcase
    endfunction
    function automatic logic[7:0] output_byte(input logic[31:0] offset);
        logic[31:0] word_value;
        logic[63:0] wide_value;
        word_value=0;wide_value=0;
        if(op==8)begin
            word_value=bank_word(write_slot,op==8&&write_slot==3&&desc[5][1]&&!desc[5][0]?(offset%8)/4:offset/4);return 8'(word_value>>(8*(offset%4)));
        end
        if(write_slot==1)begin word_value=offset<4?packed_m:32'(packed_e);return 8'(word_value>>(8*(offset%4)));end
        if(op==7)begin wide_value=64'(gy[offset/8]);return 8'(wide_value>>(8*(offset%8)));end
        word_value=op==5?32'(probabilities[offset/2]):32'(packed_values[offset/2]);
        return 8'(word_value>>(8*(offset%2)));
    endfunction
    always_comb begin for(int g=0;g<MM3_MAX_VECTOR;g++)begin av[g]=$signed(abuf[g/2][(g%2)*16+:16]);bv[g]=$signed(bbuf[g/2][(g%2)*16+:16]);
        work[g]=op==3?nwork[g]:op==9?awork[g]:vwork[g];
     end end
    always_comb begin for(int g=0;g<8193;g++)begin siglut[g]=auxbuf[g/2][(g%2)*16+:16]; end end
    always_comb begin for(int g=0;g<4097;g++)begin explut[g]=auxbuf[g]; end end
    always_comb begin for(int g=0;g<MM3_SEQ_CAP*384;g++)begin keys[g]=$signed(kbuf[g/2][(g%2)*16+:16]);values[g]=$signed(vbuf[g/2][(g%2)*16+:16]);
     end end
    always_comb begin for(int g=0;g<8;g++)begin qm[g]=asbuf[2*g];qe[g]=$signed(asbuf[2*g+1]); end end
    always_comb begin for(int g=0;g<MM3_SEQ_CAP*4;g++)begin km[g]=ksbuf[2*g];ke[g]=$signed(ksbuf[2*g+1]);vm[g]=vsbuf[2*g];ve[g]=$signed(vsbuf[2*g+1]);
     end end
    always_comb begin for(int g=0;g<MM3_GEMM_MAX_M*MM3_GEMM_MAX_K;g++)begin raw_ga[g]=abuf[g/2][(g%2)*16+:16];ga[g]=op==9?att_ga[g]:raw_ga[g];
     end end
    always_comb begin for(int g=0;g<MM3_GEMM_MAX_K*MM3_GEMM_MAX_N;g++)begin raw_gb[g]=desc[5][0]?$signed(bbuf[g]):32'($signed(bbuf[g/2][(g%2)*16+:16]));gb[g]=op==9?att_gb[g]:raw_gb[g];
     end end
    always_comb begin for(int g=0;g<MM3_SEQ_CAP;g++)begin raw_scores[g]=$signed(abuf[g]);scores[g]=op==9?att_scores[g]:raw_scores[g]; end end
    mm3_reader u_reader(.clk,.rst,.start(reader_start),.address(reader_address),.bytes(reader_bytes),.busy(reader_busy),.failed(reader_failed),.valid(stream_valid),.ready(stream_ready),.data(stream_data),.count(stream_count),.last(stream_last),.rd_cmd_valid,.rd_cmd_ready,.rd_cmd,.rd_valid,.rd_ready,.rd_data);
    mm3_rmsnorm u_norm(.clk,.rst,.start(state==COMPUTE_START&&op==3),.n,.am(asbuf[0]),.bm(bsbuf[0]),.ae($signed(asbuf[1])),.be($signed(bsbuf[1])),.eps_m(desc[16]),.eps_e($signed(desc[17])),.a(av),.b(bv),.busy(),.done(norm_done),.failed(norm_fail),.work(nwork));
    mm3_vector u_vector(.clk,.rst,.start(state==COMPUTE_START&&(op==1||op==2||op==4||op==6)),.op,.n,.am(asbuf[0]),.bm(bsbuf[0]),.ae($signed(asbuf[1])),.be($signed(bsbuf[1])),.a(av),.b(bv),.sigmoid_lut(siglut),.busy(),.done(vec_done),.failed(vec_fail),.work(vwork));
    mm3_gemm u_gemm(.clk,.rst,.start(op==9?agstart:state==COMPUTE_START&&op==7),.unsigned_a(op==9?agpv:desc[5][0]),.transpose_b(op==9?agtrans:desc[5][1]),.m(op==9?agm:desc[3]),.n(op==9?agn:n),.k(op==9?agk:desc[4]),.a_stride(op==9?agk:a_stride),.b_stride(op==9?(agtrans?agk:agn):b_stride),.a(ga),.b(gb),.busy(),.done(gemm_done),.failed(gemm_fail),.y(gy));
    mm3_softmax u_softmax(.clk,.rst,.start(op==9?asstart:state==COMPUTE_START&&op==5),.n(op==9?desc[15]:n),.scores,.exp_lut(explut),.busy(),.done(soft_done),.failed(soft_fail),.probabilities);
    mm3_attention u_attention(.clk,.rst,.start(state==COMPUTE_START&&op==9),.length(desc[15]),.invsqrt_m(desc[23]),.invsqrt_e($signed(desc[24])),.q(attq),.qm,.qe,.keys,.values,.km,.ke,.vm,.ve,.busy(),.done(att_done),.failed(att_fail),.gemm_start(agstart),.gemm_pv(agpv),.gemm_transpose(agtrans),.gemm_m(agm),.gemm_n(agn),.gemm_k(agk),.gemm_a(att_ga),.gemm_b(att_gb),.gemm_done,.gemm_failed(gemm_fail),.gemm_y(gy),.softmax_start(asstart),.scores(att_scores),.softmax_done(soft_done),.softmax_failed(soft_fail),.probabilities,.work(awork));
    mm3_pack u_pack(.clk,.rst,.start(state==PACK_START),.bits32(1'b0),.n,.values(work),.busy(),.done(pack_done),.failed(pack_fail),.y(packed_values),.scale_m(packed_m),.scale_e(packed_e),.saturated,.underflow);
    mm3_kv_cache u_kv(.clk,.rst,.start(state==K_START),.ready(state==K_WAIT),.pos(desc[14]),.capacity(desc[22]),.key_base(desc[18]),.value_base(desc[19]),.key_scale_base(desc[20]),.value_scale_base(desc[21]),.valid(kv_valid),.failed(kv_fail),.key_address(ka),.value_address(va),.key_scale_address(ksa),.value_scale_address(vsa));
    always_comb begin
        load_bank=load_slot;load_address=0;load_bytes=0;
        case(load_slot)
            0:begin load_address=desc[6];load_bytes=(op==7?32'(a_span):n)*(op==5?4:2);if(op==8&&desc[5][0])begin load_address=ka;load_bytes=n*2;end end
            1:if(op==1||op==2||op==3||op==4||op==6||op==7||op==8)begin load_address=desc[7];load_bytes=op==7?32'(b_span)*(desc[5][0]?4:2):n*2;if(op==8&&desc[5][0])load_address=va;end
            2:if(op!=5&&op!=7)begin load_address=desc[9];load_bytes=op==9?64:op==8?32:8;if(op==8&&desc[5][0])load_address=ksa;end
            3:if(op!=5&&op!=7&&op!=9)begin load_address=desc[10];load_bytes=op==8?(desc[5][1]&&!desc[5][0]?8:32):8;if(op==8&&desc[5][0])load_address=vsa;end
            4:if(op==5||op==6||op==9)begin load_address=desc[12];load_bytes=op==6?16386:16388;end
            5:if(op==9)begin load_address=desc[18];load_bytes=desc[15]*768;end
            6:if(op==9)begin load_address=desc[19];load_bytes=desc[15]*768;end
            7:if(op==9)begin load_address=desc[20];load_bytes=desc[15]*32;end
            8:if(op==9)begin load_address=desc[21];load_bytes=desc[15]*32;end
            default:;
        endcase
        reader_start=state==D_START||state==LOAD_START;reader_address=state==D_START?descriptor_address:load_address;
        reader_bytes=state==D_START?128:load_bytes;stream_ready=state==D_LOAD||state==LOAD_DATA;
        output_address=desc[8];output_bytes=op==7?desc[3]*n*8:n*2;
        if(write_slot==1&&op!=8)begin output_address=desc[11];output_bytes=8;end
        if(op==8)begin
            case(write_slot)
                0:begin output_address=desc[5][0]?desc[6]:ka;output_bytes=n*2;end
                1:begin output_address=desc[5][0]?desc[7]:va;output_bytes=n*2;end
                2:begin output_address=desc[5][0]?desc[9]:ksa;output_bytes=32;end
                3:begin output_address=desc[5][0]?desc[10]:vsa;output_bytes=32;end
                default:output_bytes=0;
            endcase
        end
        wr_cmd_valid=state==WRITE_CMD;wr_cmd='0;wr_cmd.addr=core_types_pkg::xlen_t'(write_address);wr_cmd.size=5;
        wr_valid=state==WRITE_DATA;wr_data='0;wr_data.last=1;
        for(int lane=0;lane<32;lane++)if(64'(write_address)+64'(lane)>=64'(output_address)&&64'(write_address)+64'(lane)<64'(output_address)+64'(output_bytes))begin
            wr_data.strb[lane]=1;wr_data.data[lane*8+:8]=output_byte(write_address+32'(lane)-output_address);
        end
        wr_rsp_ready=state==WRITE_WAIT;
        region_end=64'(output_address)+64'(output_bytes);
    end
    always_ff @(posedge clk)begin
        if(rst)begin state<=IDLE;done<=0;failed<=0;error_code<=0;load_slot<=0;load_offset<=0;write_slot<=0;write_address<=0;end
        else begin
            done<=0;
            case(state)
                IDLE:if(start)begin failed<=0;error_code<=0;load_offset<=0;if(descriptor_address[5:0]!=0||!region_ok(descriptor_address,128))begin failed<=1;error_code<=1;state<=FINISH;end else state<=D_START;end
                D_START:state<=D_LOAD;
                D_LOAD:if(reader_failed)begin failed<=1;error_code<=3;state<=FINISH;end else if(stream_valid)begin
                    for(int i=0;i<32;i++)if(i<int'(stream_count))desc[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                    load_offset<=load_offset+32'(stream_count);if(stream_last)state<=VALIDATE;
                end
                VALIDATE:begin
                    load_slot<=0;
                    if(desc[0]!=32'h334f5031||op!=expected_op||op==0||op>9||n==0||n>MM3_MAX_VECTOR||
                       (op==3&&n>MM3_NORM_MAX_LEN)||(op==4&&n!=96)||(op==5&&n>MM3_SEQ_CAP)||
                       (op==7&&((desc[5]&~32'd3)!=0||a_stride<desc[4]||b_stride<(desc[5][1]?desc[4]:n)||a_span>MM3_GEMM_MAX_M*MM3_GEMM_MAX_K||b_span>MM3_GEMM_MAX_K*MM3_GEMM_MAX_N||desc[3]==0||desc[4]==0||desc[3]>MM3_GEMM_MAX_M||n>MM3_GEMM_MAX_N||desc[4]>MM3_GEMM_MAX_K))||
                       (op==8&&(n!=384||(desc[5]&~32'd3)!=0))||(op==9&&(n!=768||desc[15]==0||desc[15]>desc[22]||desc[22]>MM3_SEQ_CAP)))begin failed<=1;error_code<=1;state<=FINISH;end
                    else state<=op==8?K_START:LOAD_SELECT;
                end
                K_START:state<=K_WAIT;
                K_WAIT:if(kv_valid)begin if(kv_fail)begin failed<=1;error_code<=1;state<=FINISH;end else state<=LOAD_SELECT;end
                LOAD_SELECT:begin
                    load_offset<=0;
                    if(load_bytes==0)begin if(load_slot==8)state<=COMPUTE_START;else load_slot<=load_slot+1;end
                    else if(!region_ok(load_address,load_bytes)||(load_address[0]!=0)||
                         (load_bank==0&&load_bytes>AW*4)||(load_bank==1&&load_bytes>BW*4))begin failed<=1;error_code<=1;state<=FINISH;end
                    else state<=LOAD_START;
                end
                LOAD_START:state<=LOAD_DATA;
                LOAD_DATA:if(reader_failed)begin failed<=1;error_code<=3;state<=FINISH;end else if(stream_valid)begin
                    for(int i=0;i<32;i++)if(i<int'(stream_count))begin
                        case(load_bank)
                            0:abuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            1:bbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            2:asbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            3:bsbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            4:auxbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            5:kbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            6:vbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            7:ksbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            8:vsbuf[(load_offset+32'(i))/4][((load_offset+32'(i))%4)*8+:8]<=stream_data[i*8+:8];
                            default:;
                        endcase
                    end
                    load_offset<=load_offset+32'(stream_count);
                    if(stream_last)begin if(load_slot==8)state<=COMPUTE_START;else begin load_slot<=load_slot+1;state<=LOAD_SELECT;end end
                end
                COMPUTE_START:begin if(!scales_valid)begin failed<=1;error_code<=2;state<=FINISH;end else if(op==8)begin write_slot<=0;state<=WRITE_SELECT;end else state<=COMPUTE_WAIT;end
                COMPUTE_WAIT:begin
                    if((op==3&&norm_done)||(op==9&&att_done)||(op==7&&gemm_done)||(op==5&&soft_done)||((op==1||op==2||op==4||op==6)&&vec_done))begin
                        if((op==3&&norm_fail)||(op==9&&att_fail)||(op==7&&gemm_fail)||(op==5&&soft_fail)||((op==1||op==2||op==4||op==6)&&vec_fail))begin failed<=1;error_code<=2;state<=FINISH;end
                        else if(op==5||op==7)begin write_slot<=0;state<=WRITE_SELECT;end
                        else state<=PACK_START;
                    end
                end
                PACK_START:state<=PACK_WAIT;
                PACK_WAIT:if(pack_done)begin if(pack_fail)begin failed<=1;error_code<=2;state<=FINISH;end else begin write_slot<=0;state<=WRITE_SELECT;end end
                WRITE_SELECT:begin
                    if(!region_ok(output_address,output_bytes))begin failed<=1;error_code<=1;state<=FINISH;end
                    else begin write_address<=output_address&32'hffffffe0;state<=WRITE_CMD;end
                end
                WRITE_CMD:if(wr_cmd_ready)state<=WRITE_DATA;
                WRITE_DATA:if(wr_ready)state<=WRITE_WAIT;
                WRITE_WAIT:if(wr_rsp_valid)begin
                    if(wr_rsp.error!=BUS_OK)begin failed<=1;error_code<=4;state<=FINISH;end
                    else if(64'(write_address)+32<region_end)begin write_address<=write_address+32;state<=WRITE_CMD;end
                    else if((op==8&&write_slot<3)||(op!=5&&op!=7&&op!=8&&write_slot==0))begin write_slot<=write_slot+1;state<=WRITE_SELECT;end
                    else state<=FINISH;
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:begin failed<=1;error_code<=1;state<=FINISH;end
            endcase
        end
    end
endmodule
