/* Module: yolo_network_ops_test
 * Description: Scalar convolution, ties-even quantization, CPU graph operators and class-agnostic NMS checks.
 */
#include "network.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned allocations;
static void *allocate(void *ctx,size_t size){(void)ctx;allocations++;return malloc(size);}
static void release(void *ctx,void *ptr){(void)ctx;if(ptr){assert(allocations);allocations--;free(ptr);}}
static void quantize(void) {
    float input[]={127,.5f,1.5f,2.5f,126.5f,-.5f,-1.5f,-2.5f,-126.5f};int8_t expected[]={127,0,2,2,126,0,-2,-2,-126},result[9];float scale;
    assert(!yolo_network_quantize(input,9,result,&scale));assert(scale==1);assert(!memcmp(result,expected,9));
    float zeros[4]={0};assert(!yolo_network_quantize(zeros,4,result,&scale));assert(scale>0&&scale<1e-11f);
    for(unsigned i=0;i<4;i++)assert(result[i]==0);
    float bad[]={NAN};assert(yolo_network_quantize(bad,1,result,&scale)==YOLO_NET_NUMERIC);
}
static void batchnorm(void) {
    const float input[]={1,2,3,-1,-2,-3},gamma[]={2,-3},beta[]={1,2},mean[]={1,-1},variance[]={4,9};float output[6];
    assert(!yolo_network_batchnorm(input,output,2,3,gamma,beta,mean,variance));
    for(unsigned channel=0;channel<2;channel++)for(unsigned i=0;i<3;i++)
        assert(fabsf(output[channel*3+i]-((input[channel*3+i]-mean[channel])/sqrtf(variance[channel]+.001f)*gamma[channel]+beta[channel]))<1e-6f);
    float bad[]={-1};assert(yolo_network_batchnorm(input,output,1,1,gamma,beta,mean,bad)==YOLO_NET_NUMERIC);
}
static void reference(const struct yolo_conv *c,int32_t *output) {
    unsigned w=(c->width+c->pad*2-c->kernel)/c->stride+1,h=(c->height+c->pad*2-c->kernel)/c->stride+1;
    for(unsigned oc=0;oc<c->cout;oc++)for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
        int32_t sum=c->bias?c->bias[oc]:0;
        for(unsigned ic=0;ic<c->cin;ic++)for(unsigned ky=0;ky<c->kernel;ky++)for(unsigned kx=0;kx<c->kernel;kx++) {
            int iy=(int)(y*c->stride+ky)-(int)c->pad,ix=(int)(x*c->stride+kx)-(int)c->pad;
            if(iy<0||ix<0||iy>=(int)c->height||ix>=(int)c->width)continue;
            sum+=(int)c->input[((size_t)ic*c->height+(unsigned)iy)*c->width+(unsigned)ix]*c->weight[((size_t)oc*c->cin+ic)*c->kernel*c->kernel+ky*c->kernel+kx];
        }
        output[((size_t)oc*h+y)*w+x]=sum;
    }
}
static void convolution(void) {
    int8_t input[60],weights[54];int32_t actual[40],expected[40],bias[2]={-31,27};
    for(unsigned i=0;i<60;i++)input[i]=(int8_t)((int)(i*13%255)-127);
    for(unsigned i=0;i<54;i++)weights[i]=(int8_t)((int)(i*19%255)-127);
    for(unsigned kernel=1;kernel<=3;kernel+=2)for(unsigned stride=1;stride<=2;stride++) {
        struct yolo_conv c={input,weights,bias,actual,5,4,3,2,kernel,stride,kernel/2};
        unsigned count=((5+2*c.pad-kernel)/stride+1)*((4+2*c.pad-kernel)/stride+1)*2;
        reference(&c,expected);assert(!yolo_network_scalar_conv(NULL,&c));assert(!memcmp(actual,expected,count*4));
    }
    struct yolo_conv c={input,weights,NULL,actual,1,1,3,2,3,1,1};reference(&c,expected);
    assert(!yolo_network_scalar_conv(NULL,&c));assert(!memcmp(actual,expected,8));
}
static void graph(void) {
    float input[16],other[16],out[64];for(unsigned i=0;i<16;i++){input[i]=(float)i;other[i]=1;}
    struct yolo_network_tensor in[4]={{1,4,4,0,0},{1,4,4,0,0}},shape={4,2,2,0,0};const float *args[4]={input,other};uint32_t p[4]={0};
    const float focus[]={0,2,8,10,4,6,12,14,1,3,9,11,5,7,13,15};
    assert(!yolo_network_graph_op(YOLO_NET_FOCUS,&shape,out,in,args,1,p));assert(!memcmp(focus,out,64));
    shape=in[0];assert(!yolo_network_graph_op(YOLO_NET_ADD,&shape,out,in,args,2,p));for(unsigned i=0;i<16;i++)assert(out[i]==input[i]+1);
    for(unsigned i=0;i<4;i++){in[i]=(struct yolo_network_tensor){1,1,4,0,0};args[i]=input+i*4;}
    shape=(struct yolo_network_tensor){4,1,4,0,0};assert(!yolo_network_graph_op(YOLO_NET_CONCAT,&shape,out,in,args,4,p));assert(!memcmp(out,input,64));
    float negative[]={-5,-2,-4,-3};in[0]=(struct yolo_network_tensor){1,2,2,0,0};shape=in[0];args[0]=negative;p[0]=3;p[1]=1;p[2]=1;
    assert(!yolo_network_graph_op(YOLO_NET_MAXPOOL,&shape,out,in,args,1,p));for(unsigned i=0;i<4;i++)assert(out[i]==-2);
    shape=(struct yolo_network_tensor){1,4,4,0,0};p[0]=2;
    assert(!yolo_network_graph_op(YOLO_NET_UPSAMPLE,&shape,out,in,args,1,p));for(unsigned y=0;y<4;y++)for(unsigned x=0;x<4;x++)assert(out[y*4+x]==negative[y/2*2+x/2]);
    float activation[]={-1,0,2};in[0]=(struct yolo_network_tensor){3,1,1,0,0};shape=in[0];args[0]=activation;
    assert(!yolo_network_graph_op(YOLO_NET_SIGMOID,&shape,out,in,args,1,p));assert(fabsf(out[0]-.26894143f)<1e-6f&&out[1]==.5f&&fabsf(out[2]-.88079708f)<1e-6f);
    assert(!yolo_network_graph_op(YOLO_NET_SILU,&shape,out,in,args,1,p));assert(fabsf(out[0]+.26894143f)<1e-6f&&out[1]==0&&fabsf(out[2]-1.76159416f)<1e-6f);
}
static void detections(void) {
    float head0[85*16]={0},head1[85*4]={0},head2[85]={0};const float *heads[3]={head0,head1,head2};
    /* 固定头部测试向量，log(2)的最近单精度值；生产解码仍调用真实expf。 */
    const float log_two=0x1.62e43p-1f;
    unsigned i=5;head0[i]=0;head0[16+i]=0;head0[32+i]=log_two;head0[48+i]=log_two;head0[64+i]=.9f;head0[(5+2)*16+i]=.8f;
    i=6;head0[i]=-1;head0[16+i]=0;head0[32+i]=log_two;head0[48+i]=log_two;head0[64+i]=.7f;head0[(5+3)*16+i]=1;
    i=15;head0[i]=0;head0[16+i]=0;head0[32+i]=0;head0[48+i]=0;head0[64+i]=.6f;head0[(5+5)*16+i]=1;
    struct yolo_detection output[4];struct yolo_network_stats stats={0};struct yolo_network_allocator memory={allocate,release,NULL};
    assert(!yolo_network_decode(heads,32,32,.25f,.45f,output,4,memory,&stats));assert(!allocations);
    assert(stats.candidates==3&&stats.detections==2&&stats.written==2&&output[0].class_id==2&&output[1].class_id==5);
    assert(fabsf(output[0].score-.72f)<1e-6f&&output[0].x1==0&&output[0].y1==0&&output[0].x2==16&&output[0].y2==16);
    memset(&stats,0,sizeof(stats));assert(!yolo_network_decode(heads,32,32,.25f,.45f,output,1,memory,&stats));assert(stats.detections==2&&stats.written==1&&!allocations);
}
int main(void){quantize();batchnorm();convolution();graph();detections();puts("PASS YOLO network C operators groups=5 quantize=ties-even bn=eps1e-3 conv_cases=5 focus=TL-BL-TR-BR pool=negative-boundary nms=class-agnostic memory=returned");return 0;}
