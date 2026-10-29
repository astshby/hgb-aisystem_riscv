/* Module: yolo_network
 * Description: Last-use tensor lifetime, dynamic INT8 activation quantization, graph operators and YOLOX detection decoding.
 */
#include "network.h"
#include <math.h>
#include <string.h>
#include <limits.h>

static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint32_t crc32(const unsigned char *p,size_t size) {
    uint32_t table[256],value=UINT32_MAX;
    for(unsigned i=0;i<256;i++){uint32_t n=i;for(unsigned j=0;j<8;j++)n=(n>>1)^((n&1)?0xedb88320u:0);table[i]=n;}
    for(size_t i=0;i<size;i++)value=table[(value^p[i])&255]^(value>>8);
    return value^UINT32_MAX;
}
static size_t elements(struct yolo_network_tensor t){return (size_t)t.c*t.h*t.w;}
static int same(struct yolo_network_tensor a,struct yolo_network_tensor b){return a.c==b.c&&a.h==b.h&&a.w==b.w;}
static int range(const struct yolo_network *m,uint32_t offset,size_t count,size_t unit) {
    return !(offset&3u)&&offset>=m->data_offset&&offset<=m->bytes&&unit&&count<=(m->bytes-offset)/unit;
}
int yolo_network_get_tensor(const struct yolo_network *m,uint32_t index,struct yolo_network_tensor *t) {
    if(index>=m->tensor_count)return YOLO_NET_FORMAT;
    const unsigned char *p=m->blob+m->tensor_offset+(size_t)index*32;
    t->c=u32(p);t->h=u32(p+4);t->w=u32(p+8);t->last_use=u32(p+12);t->flags=u32(p+16);
    return YOLO_NET_OK;
}
int yolo_network_get_node(const struct yolo_network *m,uint32_t index,struct yolo_network_node *n) {
    if(index>=m->node_count)return YOLO_NET_FORMAT;
    const unsigned char *p=m->blob+m->node_offset+(size_t)index*64;
    n->op=u32(p);n->out=u32(p+4);n->ninputs=u32(p+8);
    for(unsigned i=0;i<4;i++){n->in[i]=u32(p+12+i*4);n->p[i]=u32(p+28+i*4);n->data[i]=u32(p+44+i*4);}
    n->flags=u32(p+60);return YOLO_NET_OK;
}
static int validate_shape(const struct yolo_network *m,struct yolo_network_node n) {
    struct yolo_network_tensor output,input[4];
    if(n.out>=m->tensor_count||!n.ninputs||n.ninputs>4||n.flags)return YOLO_NET_SHAPE;
    yolo_network_get_tensor(m,n.out,&output);
    for(unsigned i=0;i<n.ninputs;i++)if(yolo_network_get_tensor(m,n.in[i],&input[i]))return YOLO_NET_SHAPE;
    switch(n.op) {
        case YOLO_NET_CONV: {
            unsigned k=n.p[0],s=n.p[1],pad=n.p[2];
            if(n.ninputs!=1||(k!=1&&k!=3)||(s!=1&&s!=2)||pad>k/2||n.p[3]||
               input[0].w+pad*2<k||input[0].h+pad*2<k||
               output.h!=(input[0].h+pad*2-k)/s+1||output.w!=(input[0].w+pad*2-k)/s+1||
               !range(m,n.data[0],(size_t)output.c*input[0].c*k*k,1)||
               !range(m,n.data[1],output.c,4)||
               (n.data[2]!=YOLO_NETWORK_KEEP&&!range(m,n.data[2],output.c,4)))return YOLO_NET_SHAPE;
            const float *scales=(const float *)(m->blob+n.data[1]);
            const float *bias=n.data[2]==YOLO_NETWORK_KEEP?NULL:(const float *)(m->blob+n.data[2]);
            for(unsigned i=0;i<output.c;i++)if(!isfinite(scales[i])||scales[i]<=0||(bias&&!isfinite(bias[i])))return YOLO_NET_NUMERIC;
            break;
        }
        case YOLO_NET_BN:
            if(n.ninputs!=1||!same(output,input[0]))return YOLO_NET_SHAPE;
            for(unsigned i=0;i<4;i++)if(!range(m,n.data[i],output.c,4))return YOLO_NET_SHAPE;
            for(unsigned i=0;i<output.c;i++)for(unsigned j=0;j<4;j++) {
                float value=((const float *)(m->blob+n.data[j]))[i];
                if(!isfinite(value)||(j==3&&value<0))return YOLO_NET_NUMERIC;
            }
            break;
        case YOLO_NET_SILU:case YOLO_NET_SIGMOID:
            if(n.ninputs!=1||!same(output,input[0]))return YOLO_NET_SHAPE;
            break;
        case YOLO_NET_FOCUS:
            if(n.ninputs!=1||input[0].h%2||input[0].w%2||output.c!=input[0].c*4||
               output.h!=input[0].h/2||output.w!=input[0].w/2)return YOLO_NET_SHAPE;
            break;
        case YOLO_NET_ADD:
            if(n.ninputs!=2||!same(output,input[0])||!same(output,input[1]))return YOLO_NET_SHAPE;
            break;
        case YOLO_NET_CONCAT: {
            unsigned channels=0;
            if(n.ninputs<2)return YOLO_NET_SHAPE;
            for(unsigned i=0;i<n.ninputs;i++){if(input[i].h!=output.h||input[i].w!=output.w)return YOLO_NET_SHAPE;channels+=input[i].c;}
            if(channels!=output.c)return YOLO_NET_SHAPE;
            break;
        }
        case YOLO_NET_MAXPOOL: {
            unsigned k=n.p[0],s=n.p[1],pad=n.p[2];
            if(n.ninputs!=1||!k||k>13||!s||s>2||pad>k/2||output.c!=input[0].c||
               input[0].w+2*pad<k||input[0].h+2*pad<k||
               output.h!=(input[0].h+2*pad-k)/s+1||output.w!=(input[0].w+2*pad-k)/s+1)return YOLO_NET_SHAPE;
            break;
        }
        case YOLO_NET_UPSAMPLE:
            if(n.ninputs!=1||!n.p[0]||n.p[0]>4||output.c!=input[0].c||
               output.h!=input[0].h*n.p[0]||output.w!=input[0].w*n.p[0])return YOLO_NET_SHAPE;
            break;
        default:return YOLO_NET_FORMAT;
    }
    return YOLO_NET_OK;
}
int yolo_network_open(struct yolo_network *m,const void *blob,size_t bytes) {
    memset(m,0,sizeof(*m));
    uint32_t endian=1;if(*(unsigned char *)&endian!=1||sizeof(float)!=4||bytes<128||bytes>UINT32_MAX||
       ((uintptr_t)blob&3u)||memcmp(blob,"YOLONET1",8))return YOLO_NET_FORMAT;
    const unsigned char *p=blob;
    if(u32(p+8)!=1||u32(p+12)!=bytes)return YOLO_NET_FORMAT;
    m->blob=p;m->bytes=bytes;m->tensor_count=u32(p+16);m->node_count=u32(p+20);m->input_id=u32(p+24);
    for(unsigned i=0;i<3;i++)m->head[i]=u32(p+28+i*4);
    m->tensor_offset=u32(p+40);m->node_offset=u32(p+44);m->data_offset=u32(p+48);
    m->input_c=u32(p+56);m->input_h=u32(p+60);m->input_w=u32(p+64);
    if(!m->tensor_count||m->tensor_count>YOLO_NETWORK_MAX_TENSORS||!m->node_count||m->node_count>YOLO_NETWORK_MAX_NODES||
       m->input_id>=m->tensor_count||m->input_c!=3||!m->input_h||!m->input_w||
       m->input_h>416||m->input_w>416||m->input_h%32||m->input_w%32||
       (m->tensor_offset&3u)||(m->node_offset&3u)||(m->data_offset&3u)||m->tensor_offset<128||
       m->node_offset<m->tensor_offset+(size_t)m->tensor_count*32||
       m->data_offset<m->node_offset+(size_t)m->node_count*64||m->data_offset>bytes)return YOLO_NET_FORMAT;
    if(crc32(p+128,bytes-128)!=u32(p+52))return YOLO_NET_CRC;
    uint32_t last[YOLO_NETWORK_MAX_TENSORS];unsigned char produced[YOLO_NETWORK_MAX_TENSORS]={0};
    for(unsigned i=0;i<m->tensor_count;i++) {
        struct yolo_network_tensor t;yolo_network_get_tensor(m,i,&t);
        if(!t.c||t.c>768||!t.h||t.h>416||!t.w||t.w>416||(t.flags&~3u))return YOLO_NET_SHAPE;
        if(i==m->input_id){if(t.c!=3||t.h!=m->input_h||t.w!=m->input_w||t.flags!=1)return YOLO_NET_SHAPE;}
        else if(t.flags&1)return YOLO_NET_SHAPE;
        last[i]=YOLO_NETWORK_KEEP;
    }
    produced[m->input_id]=1;
    for(unsigned i=0;i<m->node_count;i++) {
        struct yolo_network_node n;yolo_network_get_node(m,i,&n);
        if(n.out>=m->tensor_count||produced[n.out]||!n.ninputs||n.ninputs>4)return YOLO_NET_SHAPE;
        for(unsigned j=0;j<n.ninputs;j++) {
            if(n.in[j]>=m->tensor_count||!produced[n.in[j]])return YOLO_NET_SHAPE;
            last[n.in[j]]=i;
        }
        int error=validate_shape(m,n);if(error)return error;
        produced[n.out]=1;
    }
    for(unsigned i=0;i<3;i++) {
        struct yolo_network_tensor t;
        if(m->head[i]>=m->tensor_count||!produced[m->head[i]])return YOLO_NET_SHAPE;
        yolo_network_get_tensor(m,m->head[i],&t);
        if(t.flags!=2||t.c!=85||t.w!=m->input_w/(8u<<i)||t.h!=m->input_h/(8u<<i)||
           (i&&m->head[i]==m->head[0])||(i==2&&m->head[i]==m->head[1]))return YOLO_NET_SHAPE;
        last[m->head[i]]=YOLO_NETWORK_KEEP;
    }
    for(unsigned i=0;i<m->tensor_count;i++) {
        struct yolo_network_tensor t;yolo_network_get_tensor(m,i,&t);
        if(!produced[i]||t.last_use!=last[i]||((t.flags&2u)==0&&t.last_use==YOLO_NETWORK_KEEP))return YOLO_NET_SHAPE;
    }
    return YOLO_NET_OK;
}
int yolo_network_model_init(struct yolo_network *m,const void *p,size_t n){return yolo_network_open(m,p,n);}

int yolo_network_quantize(const float *input,size_t size,int8_t *output,float *scale) {
    float maximum=0;
    for(size_t i=0;i<size;i++){if(!isfinite(input[i]))return YOLO_NET_NUMERIC;float value=fabsf(input[i]);if(value>maximum)maximum=value;}
    *scale=(float)fmax((double)maximum/127.0,1e-12);
    for(size_t i=0;i<size;i++) {
        float value=input[i]/(*scale),magnitude=fabsf(value),low=floorf(magnitude),fraction=magnitude-low;
        int rounded=(int)low;if(fraction>0.5f||(fraction==0.5f&&(rounded&1)))rounded++;
        if(rounded>127)rounded=127;
        output[i]=(int8_t)(value<0?-rounded:rounded);
    }
    return YOLO_NET_OK;
}
int yolo_network_batchnorm(const float *input,float *output,uint32_t channels,size_t spatial,
    const float *gamma,const float *beta,const float *mean,const float *variance) {
    for(unsigned channel=0;channel<channels;channel++) {
        if(!isfinite(variance[channel])||variance[channel]<0)return YOLO_NET_NUMERIC;
        /* 单精度逆标准差、仿射系数和偏移分别舍入；不依赖FMA或折叠卷积。 */
        float inverse=1.0f/sqrtf(variance[channel]+0.001f);
        float alpha=gamma[channel]*inverse,shift=beta[channel]-mean[channel]*alpha;
        for(size_t i=0;i<spatial;i++){size_t offset=(size_t)channel*spatial+i;output[offset]=input[offset]*alpha+shift;}
    }
    return YOLO_NET_OK;
}
int yolo_network_scalar_conv(void *context,const struct yolo_conv *c) {
    (void)context;
    if(!c||!c->input||!c->weight||!c->output||!c->width||!c->height||!c->cin||!c->cout||
       c->width>416||c->height>416||c->cin>768||c->cout>768||
       (c->kernel!=1&&c->kernel!=3)||(c->stride!=1&&c->stride!=2)||c->pad>c->kernel/2||
       c->width+2*c->pad<c->kernel||c->height+2*c->pad<c->kernel)return YOLO_CONV_SHAPE;
    unsigned ow=(c->width+2*c->pad-c->kernel)/c->stride+1,oh=(c->height+2*c->pad-c->kernel)/c->stride+1;
    size_t plane=(size_t)ow*oh;
    for(unsigned oc=0;oc<c->cout;oc++) {
        int32_t *out=c->output+(size_t)oc*plane;
        for(size_t i=0;i<plane;i++)out[i]=c->bias?c->bias[oc]:0;
        for(unsigned ic=0;ic<c->cin;ic++)for(unsigned ky=0;ky<c->kernel;ky++)for(unsigned kx=0;kx<c->kernel;kx++) {
            int weight=c->weight[((size_t)oc*c->cin+ic)*c->kernel*c->kernel+ky*c->kernel+kx];
            int xstart=(int)c->pad-(int)kx,ystart=(int)c->pad-(int)ky;
            unsigned x0=xstart>0?(unsigned)(xstart+(int)c->stride-1)/c->stride:0;
            unsigned y0=ystart>0?(unsigned)(ystart+(int)c->stride-1)/c->stride:0;
            unsigned x1=(c->width+c->pad-kx+c->stride-1)/c->stride;
            unsigned y1=(c->height+c->pad-ky+c->stride-1)/c->stride;
            if(x1>ow)x1=ow;
            if(y1>oh)y1=oh;
            for(unsigned oy=y0;oy<y1;oy++) {
                unsigned iy=oy*c->stride+ky-c->pad;
                for(unsigned ox=x0;ox<x1;ox++) {
                    unsigned ix=ox*c->stride+kx-c->pad;
                    out[(size_t)oy*ow+ox]+=(int)c->input[((size_t)ic*c->height+iy)*c->width+ix]*weight;
                }
            }
        }
    }
    return YOLO_CONV_OK;
}
int yolo_network_graph_op(uint32_t op,const struct yolo_network_tensor *out_shape,float *output,
    const struct yolo_network_tensor *in_shape,const float *const *input,uint32_t ninputs,const uint32_t *parameters) {
    size_t count=elements(*out_shape);
    if(!output||!input||!input[0]||!ninputs||ninputs>4)return YOLO_NET_SHAPE;
    switch(op) {
        case YOLO_NET_SILU:
            for(size_t i=0;i<count;i++)output[i]=input[0][i]/(1.0f+expf(-input[0][i]));
            break;
        case YOLO_NET_SIGMOID:
            for(size_t i=0;i<count;i++)output[i]=1.0f/(1.0f+expf(-input[0][i]));
            break;
        case YOLO_NET_ADD:
            if(ninputs!=2||!input[1])return YOLO_NET_SHAPE;
            for(size_t i=0;i<count;i++)output[i]=input[0][i]+input[1][i];
            break;
        case YOLO_NET_CONCAT: {
            size_t offset=0;
            for(unsigned i=0;i<ninputs;i++){size_t length=elements(in_shape[i]);memcpy(output+offset,input[i],length*4);offset+=length;}
            if(offset!=count)return YOLO_NET_SHAPE;
            break;
        }
        case YOLO_NET_FOCUS: {
            unsigned h=out_shape->h,w=out_shape->w;
            for(unsigned group=0;group<4;group++)for(unsigned channel=0;channel<in_shape[0].c;channel++)
                for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++)
                    output[(((size_t)group*in_shape[0].c+channel)*h+y)*w+x]=
                        input[0][((size_t)channel*in_shape[0].h+y*2+(group&1))*in_shape[0].w+x*2+(group>>1)];
            break;
        }
        case YOLO_NET_MAXPOOL: {
            unsigned k=parameters[0],stride=parameters[1],pad=parameters[2];
            if(!k||!stride)return YOLO_NET_SHAPE;
            for(unsigned channel=0;channel<out_shape->c;channel++)for(unsigned y=0;y<out_shape->h;y++)for(unsigned x=0;x<out_shape->w;x++) {
                float maximum=-INFINITY;
                for(unsigned ky=0;ky<k;ky++)for(unsigned kx=0;kx<k;kx++) {
                    int iy=(int)(y*stride+ky)-(int)pad,ix=(int)(x*stride+kx)-(int)pad;
                    if(iy<0||ix<0||iy>=(int)in_shape[0].h||ix>=(int)in_shape[0].w)continue;
                    float value=input[0][((size_t)channel*in_shape[0].h+(unsigned)iy)*in_shape[0].w+(unsigned)ix];
                    if(value>maximum)maximum=value;
                }
                output[((size_t)channel*out_shape->h+y)*out_shape->w+x]=maximum;
            }
            break;
        }
        case YOLO_NET_UPSAMPLE: {
            unsigned factor=parameters[0];if(!factor)return YOLO_NET_SHAPE;
            for(unsigned channel=0;channel<out_shape->c;channel++)for(unsigned y=0;y<out_shape->h;y++)for(unsigned x=0;x<out_shape->w;x++)
                output[((size_t)channel*out_shape->h+y)*out_shape->w+x]=
                    input[0][((size_t)channel*in_shape[0].h+y/factor)*in_shape[0].w+x/factor];
            break;
        }
        default:return YOLO_NET_FORMAT;
    }
    return YOLO_NET_OK;
}

struct allocation {struct yolo_network_allocator io;uint64_t live;struct yolo_network_stats *stats;};
static void *allocate(struct allocation *a,size_t size) {
    void *ptr=a->io.allocate(a->io.context,size);
    if(ptr){a->live+=size;if(a->live>a->stats->allocation_peak_bytes)a->stats->allocation_peak_bytes=a->live;}
    return ptr;
}
static void release(struct allocation *a,void *ptr,size_t size) {
    if(ptr){a->io.release(a->io.context,ptr);a->live-=size;}
}
struct candidate {struct yolo_detection box;uint32_t index;};
static int before(struct candidate a,struct candidate b) {
    return a.box.score>b.box.score||(a.box.score==b.box.score&&a.index<b.index);
}
static void sort(struct candidate *items,unsigned count) {
    /* 原地heapsort只需一个临时记录；同分时保留head/像素扫描顺序。 */
    for(unsigned start=count/2;start>0;) {
        unsigned root=--start;
        for(;;){unsigned child=root*2+1;if(child>=count)break;
            if(child+1<count&&before(items[child],items[child+1]))child++;
            if(!before(items[root],items[child]))break;
            struct candidate temp=items[root];items[root]=items[child];items[child]=temp;root=child;}
    }
    for(unsigned end=count;end>1;){struct candidate temp=items[0];items[0]=items[--end];items[end]=temp;unsigned root=0;
        for(;;){unsigned child=root*2+1;if(child>=end)break;
            if(child+1<end&&before(items[child],items[child+1]))child++;
            if(!before(items[root],items[child]))break;
            temp=items[root];items[root]=items[child];items[child]=temp;root=child;}}
}
static float iou(struct yolo_detection a,struct yolo_detection b) {
    float left=fmaxf(a.x1,b.x1),right=fminf(a.x2,b.x2),top=fmaxf(a.y1,b.y1),bottom=fminf(a.y2,b.y2);
    float overlap=fmaxf(0,right-left)*fmaxf(0,bottom-top);
    float area=(a.x2-a.x1)*(a.y2-a.y1)+(b.x2-b.x1)*(b.y2-b.y1)-overlap;
    return area>0?overlap/area:0;
}
static int decode(const float *const heads[3],unsigned width,unsigned height,float threshold,float nms,
    struct yolo_detection *output,unsigned capacity,struct allocation *memory) {
    unsigned locations=0;for(unsigned h=0;h<3;h++)locations+=(width/(8u<<h))*(height/(8u<<h));
    struct candidate *candidates=allocate(memory,(size_t)locations*sizeof(*candidates));
    if(!candidates)return YOLO_NET_MEMORY;
    unsigned count=0,index=0;
    for(unsigned h=0;h<3;h++) {
        unsigned stride=8u<<h,w=width/stride,ht=height/stride;size_t plane=(size_t)w*ht;
        for(unsigned y=0;y<ht;y++)for(unsigned x=0;x<w;x++,index++) {
            size_t i=(size_t)y*w+x;const float *head=heads[h];
            float probability=head[5*plane+i];unsigned class_id=0;
            for(unsigned c=1;c<80;c++)if(head[(5+c)*plane+i]>probability){probability=head[(5+c)*plane+i];class_id=c;}
            float objectness=head[4*plane+i],score=objectness*probability;
            if(!isfinite(score)||score<threshold)continue;
            float center_x=(head[i]+x)*stride,center_y=(head[plane+i]+y)*stride;
            float bw=expf(head[2*plane+i])*stride,bh=expf(head[3*plane+i])*stride;
            if(!isfinite(center_x)||!isfinite(center_y)||!isfinite(bw)||!isfinite(bh)||bw<=0||bh<=0)continue;
            candidates[count++]=(struct candidate){{center_x-bw/2,center_y-bh/2,center_x+bw/2,center_y+bh/2,score,objectness,probability,class_id},index};
        }
    }
    memory->stats->candidates=count;sort(candidates,count);
    unsigned accepted=0;
    for(unsigned i=0;i<count;i++) {
        if(candidates[i].box.score<0)continue;
        if(accepted<capacity)output[accepted]=candidates[i].box;
        accepted++;
        for(unsigned j=i+1;j<count;j++)if(candidates[j].box.score>=0&&iou(candidates[i].box,candidates[j].box)>nms)candidates[j].box.score=-1;
    }
    memory->stats->detections=accepted;memory->stats->written=accepted<capacity?accepted:capacity;
    release(memory,candidates,(size_t)locations*sizeof(*candidates));return YOLO_NET_OK;
}
int yolo_network_decode(const float *const heads[3],unsigned width,unsigned height,float confidence,float nms,
    struct yolo_detection *output,unsigned capacity,struct yolo_network_allocator allocator,struct yolo_network_stats *stats) {
    if(!width||!height||width%32||height%32||width>416||height>416||!allocator.allocate||!allocator.release||!stats||
       (capacity&&!output)||!isfinite(confidence)||!isfinite(nms)||confidence<0||confidence>1||nms<0||nms>1)return YOLO_NET_SHAPE;
    struct allocation memory={allocator,0,stats};return decode(heads,width,height,confidence,nms,output,capacity,&memory);
}
int yolo_network_memory_plan(const struct yolo_network *m,struct yolo_network_plan *plan) {
    memset(plan,0,sizeof(*plan));plan->model_bytes=m->bytes;
    struct yolo_network_tensor input;yolo_network_get_tensor(m,m->input_id,&input);
    uint64_t live=elements(input)*4,peak=live;plan->tensor_peak_bytes=live;
    for(unsigned i=0;i<m->node_count;i++) {
        struct yolo_network_node n;struct yolo_network_tensor out;yolo_network_get_node(m,i,&n);yolo_network_get_tensor(m,n.out,&out);
        uint64_t bytes=elements(out)*4,scratch=0;live+=bytes;
        if(n.op==YOLO_NET_CONV){struct yolo_network_tensor in;yolo_network_get_tensor(m,n.in[0],&in);scratch=elements(in)+bytes;plan->convolution_count++;}
        if(live>plan->tensor_peak_bytes)plan->tensor_peak_bytes=live;
        if(scratch>plan->scratch_peak_bytes)plan->scratch_peak_bytes=scratch;
        if(live+scratch>peak)peak=live+scratch;
        for(unsigned j=0;j<m->tensor_count;j++){struct yolo_network_tensor t;yolo_network_get_tensor(m,j,&t);if(t.last_use==i)live-=elements(t)*4;}
    }
    for(unsigned i=0;i<3;i++){struct yolo_network_tensor t={0};yolo_network_get_tensor(m,m->head[i],&t);plan->head_locations+=t.h*t.w;}
    live+=(size_t)plan->head_locations*sizeof(struct candidate);if(live>peak)peak=live;
    plan->inference_peak_bytes=peak;return YOLO_NET_OK;
}
int yolo_network_infer_rgb888(const struct yolo_network *m,const uint8_t *rgb,size_t bytes,
    struct yolo_network_backend backend,struct yolo_network_allocator allocator,float confidence,float nms,
    struct yolo_detection *output,uint32_t capacity,struct yolo_network_stats *stats) {
    if(!m||!m->blob||!rgb||bytes!=(size_t)m->input_c*m->input_h*m->input_w||!backend.convolve||
       !allocator.allocate||!allocator.release||!stats||(capacity&&!output)||!isfinite(confidence)||!isfinite(nms)||
       confidence<0||confidence>1||nms<0||nms>1)return YOLO_NET_SHAPE;
    memset(stats,0,sizeof(*stats));struct allocation memory={allocator,0,stats};
    float *values[YOLO_NETWORK_MAX_TENSORS]={0};int error=YOLO_NET_OK;
    struct yolo_network_tensor input;yolo_network_get_tensor(m,m->input_id,&input);
    values[m->input_id]=allocate(&memory,elements(input)*4);
    if(!values[m->input_id])return YOLO_NET_MEMORY;
    size_t plane=(size_t)input.w*input.h;
    for(size_t i=0;i<plane;i++)for(unsigned channel=0;channel<3;channel++)values[m->input_id][(size_t)channel*plane+i]=rgb[i*3+2-channel];
    for(unsigned index=0;index<m->node_count;index++) {
        struct yolo_network_node n;struct yolo_network_tensor out,in[4];const float *arguments[4];
        yolo_network_get_node(m,index,&n);yolo_network_get_tensor(m,n.out,&out);
        if(backend.progress)backend.progress(backend.progress_context,index,n.op);
        for(unsigned j=0;j<n.ninputs;j++){yolo_network_get_tensor(m,n.in[j],&in[j]);arguments[j]=values[n.in[j]];}
        size_t count=elements(out);float *result=allocate(&memory,count*4);
        if(!result){error=YOLO_NET_MEMORY;goto cleanup;}values[n.out]=result;
        if(n.op==YOLO_NET_CONV) {
            size_t input_count=elements(in[0]);int8_t *quantized=allocate(&memory,input_count);
            int32_t *raw=allocate(&memory,count*4);float activation_scale=0;
            if(!quantized||!raw){release(&memory,quantized,input_count);release(&memory,raw,count*4);error=YOLO_NET_MEMORY;goto cleanup;}
            error=yolo_network_quantize(arguments[0],input_count,quantized,&activation_scale);
            struct yolo_conv convolution={quantized,(const int8_t *)(m->blob+n.data[0]),NULL,raw,in[0].w,in[0].h,in[0].c,out.c,n.p[0],n.p[1],n.p[2]};
            if(!error&&backend.convolve(backend.context,&convolution))error=YOLO_NET_BACKEND;
            if(!error) {
                const float *scales=(const float *)(m->blob+n.data[1]);const float *bias=n.data[2]==YOLO_NETWORK_KEEP?NULL:(const float *)(m->blob+n.data[2]);
                size_t spatial=(size_t)out.w*out.h;
                for(unsigned channel=0;channel<out.c;channel++) {
                    float scale=activation_scale*scales[channel];
                    for(size_t i=0;i<spatial;i++){size_t offset=(size_t)channel*spatial+i;float value=(float)raw[offset]*scale;if(bias)value+=bias[channel];result[offset]=value;}
                }
                stats->conv_calls++;stats->useful_macs+=(uint64_t)count*in[0].c*n.p[0]*n.p[0];
            }
            release(&memory,quantized,input_count);release(&memory,raw,count*4);
        } else if(n.op==YOLO_NET_BN) {
            const float *gamma=(const float *)(m->blob+n.data[0]),*beta=(const float *)(m->blob+n.data[1]);
            const float *mean=(const float *)(m->blob+n.data[2]),*variance=(const float *)(m->blob+n.data[3]);
            error=yolo_network_batchnorm(arguments[0],result,out.c,(size_t)out.w*out.h,gamma,beta,mean,variance);
        } else error=yolo_network_graph_op(n.op,&out,result,in,arguments,n.ninputs,n.p);
        if(error)goto cleanup;
        stats->nodes_executed++;
        for(unsigned j=0;j<m->tensor_count;j++){struct yolo_network_tensor t;yolo_network_get_tensor(m,j,&t);if(t.last_use==index){release(&memory,values[j],elements(t)*4);values[j]=NULL;}}
    }
    {const float *heads[3]={values[m->head[0]],values[m->head[1]],values[m->head[2]]};
     error=decode(heads,m->input_w,m->input_h,confidence,nms,output,capacity,&memory);}
cleanup:
    for(unsigned j=0;j<m->tensor_count;j++)if(values[j]){struct yolo_network_tensor t;yolo_network_get_tensor(m,j,&t);release(&memory,values[j],elements(t)*4);}
    return error;
}
