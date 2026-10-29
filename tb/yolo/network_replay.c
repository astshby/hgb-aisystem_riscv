/* Module: yolo_network_replay_test
 * Description: Two real 83-convolution requests share a model; every tensor allocation is returned between requests.
 */
#include "network.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct memory {size_t live,peak,calls;long fail_after;};
static void *allocate(void *context,size_t size) {
    struct memory *m=context;
    if(m->fail_after>=0&&m->calls++>=(size_t)m->fail_after)return NULL;
    unsigned char *p=malloc(size+16);if(!p)return NULL;
    memcpy(p,&size,sizeof(size));m->live+=size;if(m->live>m->peak)m->peak=m->live;return p+16;
}
static void release(void *context,void *ptr) {
    if(ptr){struct memory *m=context;unsigned char *p=(unsigned char *)ptr-16;size_t size;memcpy(&size,p,sizeof(size));assert(m->live>=size);m->live-=size;free(p);}
}
static unsigned char *read_file(const char *path,size_t *bytes) {
    FILE *f=fopen(path,"rb");assert(f);assert(!fseek(f,0,SEEK_END));long length=ftell(f);assert(length>0);rewind(f);
    unsigned char *data=malloc((size_t)length);assert(data);assert(fread(data,1,(size_t)length,f)==(size_t)length);fclose(f);*bytes=(size_t)length;return data;
}
static int fail_backend(void *context,const struct yolo_conv *conv){(void)context;(void)conv;return YOLO_CONV_DEVICE;}
int main(int argc,char **argv) {
    assert(argc==3);size_t model_bytes,input_bytes;unsigned char *model=read_file(argv[1],&model_bytes),*input=read_file(argv[2],&input_bytes);
    struct yolo_network network;assert(!yolo_network_open(&network,model,model_bytes));
    struct yolo_network_plan plan;assert(!yolo_network_memory_plan(&network,&plan));
    struct memory memory={0,0,0,-1};struct yolo_network_allocator allocator={allocate,release,&memory};
    struct yolo_network_backend backend={yolo_network_scalar_conv,NULL,NULL,NULL};struct yolo_network_stats stats;
    struct yolo_detection first[32],second[32];
    assert(!yolo_network_infer_rgb888(&network,input,input_bytes,backend,allocator,.25f,.45f,first,32,&stats));
    assert(stats.conv_calls==83&&stats.nodes_executed==network.node_count&&stats.allocation_peak_bytes==plan.inference_peak_bytes);
    assert(!memory.live);unsigned count=stats.written;uint64_t macs=stats.useful_macs;
    assert(!yolo_network_infer_rgb888(&network,input,input_bytes,backend,allocator,.25f,.45f,second,32,&stats));
    assert(!memory.live&&stats.conv_calls==83&&stats.written==count&&stats.useful_macs==macs&&!memcmp(first,second,count*sizeof(*first)));
    for(long failure=0;failure<4;failure++) {
        memory.calls=0;memory.fail_after=failure;
        assert(yolo_network_infer_rgb888(&network,input,input_bytes,backend,allocator,.25f,.45f,second,32,&stats)==YOLO_NET_MEMORY);
        assert(!memory.live);
    }
    memory.fail_after=-1;backend.convolve=fail_backend;
    assert(yolo_network_infer_rgb888(&network,input,input_bytes,backend,allocator,.25f,.45f,second,32,&stats)==YOLO_NET_BACKEND);assert(!memory.live);
    model[model_bytes-1]^=1;struct yolo_network invalid;assert(yolo_network_open(&invalid,model,model_bytes)==YOLO_NET_CRC);model[model_bytes-1]^=1;
    printf("PASS YOLO network replay requests=2 convolutions=166 detections=%u useful_macs_per_request=%llu allocation_peak=%zu live_after_request=0 allocation_failures=4 backend_failure=1 crc_failure=1\n",count,(unsigned long long)macs,memory.peak);
    free(input);free(model);return 0;
}
