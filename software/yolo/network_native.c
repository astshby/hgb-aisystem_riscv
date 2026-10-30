/* Module: yolo_network_native
 * Description: Native graph runner with an explicit scalar reference or real AXI/CDC/NPU RTL convolution backend.
 */
#define _POSIX_C_SOURCE 200809L
#include "network.h"
#include "npu_rtl_cosim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#include <dlfcn.h>
struct trace {
    FILE *file,*reference,*progress;
    unsigned convolutions;
    uint64_t checked_outputs;
    void *rtl,*library;
    int (*rtl_conv)(void *,const struct yolo_conv *);
    void (*rtl_stats)(void *,struct yolo_npu_rtl_stats *);
    void (*rtl_destroy)(void *);
};
static double seconds(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (double)t.tv_sec+t.tv_nsec*1e-9;}
static void *alloc(void *context,size_t size){(void)context;return malloc(size);}
static void dealloc(void *context,void *ptr){(void)context;free(ptr);}
static unsigned char *read_file(const char *path,size_t *size) {
    FILE *file=fopen(path,"rb");if(!file)return NULL;
    if(fseek(file,0,SEEK_END)){fclose(file);return NULL;}
    long end=ftell(file);if(end<=0||end>32*1024*1024||fseek(file,0,SEEK_SET)){fclose(file);return NULL;}
    unsigned char *data=malloc((size_t)end);if(!data){fclose(file);return NULL;}
    *size=(size_t)end;size_t count=fread(data,1,*size,file);fclose(file);if(count!=*size){free(data);return NULL;}return data;
}
static int compare(FILE *file,const void *data,size_t size) {
    const unsigned char *expected=data;unsigned char block[65536];
    while(size){size_t count=size<sizeof(block)?size:sizeof(block);if(fread(block,1,count,file)!=count||memcmp(block,expected,count))return 1;expected+=count;size-=count;}
    return 0;
}
static void tile_progress(void *context,uint64_t tiles,uint64_t cycles) {
    struct trace *trace=context;
    if(tiles%64)return;
    fprintf(stderr,"TILE layer=%u total=%llu sys_cycles=%llu\n",trace->convolutions,(unsigned long long)tiles,(unsigned long long)cycles);fflush(stderr);
    if(trace->progress){fprintf(trace->progress,"{\"event\":\"tile\",\"layer\":%u,\"tiles\":%llu,\"sys_cycles\":%llu}\n",trace->convolutions,(unsigned long long)tiles,(unsigned long long)cycles);fflush(trace->progress);}
}
static int convolve(void *context,const struct yolo_conv *conv) {
    struct trace *trace=context;
    fprintf(stderr,"CONV %u/83 input=%ux%ux%u output_channels=%u kernel=%u stride=%u\n",++trace->convolutions,conv->cin,conv->height,conv->width,conv->cout,conv->kernel,conv->stride);fflush(stderr);
    uint32_t input=conv->width*conv->height*conv->cin;
    uint32_t output=((conv->width+2*conv->pad-conv->kernel)/conv->stride+1)*
                    ((conv->height+2*conv->pad-conv->kernel)/conv->stride+1)*conv->cout;
    uint32_t header[10]={trace->convolutions,conv->width,conv->height,conv->cin,conv->cout,conv->kernel,conv->stride,conv->pad,input,output};
    if(trace->reference&&(compare(trace->reference,header,sizeof(header))||compare(trace->reference,conv->input,input))){fprintf(stderr,"reference input mismatch layer=%u\n",trace->convolutions);return 1;}
    if(trace->progress){fprintf(trace->progress,"{\"event\":\"begin\",\"layer\":%u,\"outputs\":%u}\n",trace->convolutions,output);fflush(trace->progress);}
    struct yolo_npu_rtl_stats before={0},after={0};if(trace->rtl)trace->rtl_stats(trace->rtl,&before);
    double start=seconds();int error=trace->rtl?trace->rtl_conv(trace->rtl,conv):yolo_network_scalar_conv(NULL,conv);if(error)return error;
    if(trace->reference){if(compare(trace->reference,conv->output,(size_t)output*4)){fprintf(stderr,"reference INT32 mismatch layer=%u\n",trace->convolutions);return 1;}trace->checked_outputs+=output;}
    if(trace->file) {
        if(fwrite(header,4,10,trace->file)!=10||fwrite(conv->input,1,input,trace->file)!=input||fwrite(conv->output,4,output,trace->file)!=output)return 1;
        fflush(trace->file);
    }
    if(trace->rtl)trace->rtl_stats(trace->rtl,&after);
    if(trace->progress){fprintf(trace->progress,"{\"event\":\"complete\",\"layer\":%u,\"outputs\":%u,\"reference_checked_outputs\":%llu,\"sys_cycles\":%llu,\"npu_cycles\":%llu,\"transactions\":%llu,\"seconds\":%.6f}\n",trace->convolutions,output,(unsigned long long)trace->checked_outputs,(unsigned long long)(after.sys_cycles-before.sys_cycles),(unsigned long long)(after.npu_cycles-before.npu_cycles),(unsigned long long)(after.reads+after.writes-before.reads-before.writes),seconds()-start);fflush(trace->progress);}
    return 0;
}
int main(int argc,char **argv) {
    const char *model=NULL,*image=NULL,*output=NULL,*trace_path=NULL,*library=NULL,*reference=NULL,*progress=NULL;int plan_only=0;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--plan-only")){plan_only=1;continue;}
        if(i+1>=argc)return 2;
        const char *option=argv[i++],*value=argv[i];
        if(!strcmp(option,"--model"))model=value;
        else if(!strcmp(option,"--image-rgb"))image=value;
        else if(!strcmp(option,"--output"))output=value;
        else if(!strcmp(option,"--trace"))trace_path=value;
        else if(!strcmp(option,"--rtl-library"))library=value;
        else if(!strcmp(option,"--reference-trace"))reference=value;
        else if(!strcmp(option,"--progress"))progress=value;
        else return 2;
    }
    if(!model||(!plan_only&&(!image||!output)))return 2;
    size_t model_bytes=0;unsigned char *blob=read_file(model,&model_bytes);if(!blob)return 3;
    struct yolo_network network;int error=yolo_network_open(&network,blob,model_bytes);
    if(error){fprintf(stderr,"model error=%d\n",error);free(blob);return 4;}
    struct yolo_network_plan plan;yolo_network_memory_plan(&network,&plan);
    uint64_t rgb_bytes=(uint64_t)network.input_c*network.input_h*network.input_w;
    fprintf(stderr,"PLAN model=%llu inference_peak=%llu tensor_peak=%llu scratch_peak=%llu input_rgb=%llu total_model_input_inference=%llu\n",
        (unsigned long long)plan.model_bytes,(unsigned long long)plan.inference_peak_bytes,(unsigned long long)plan.tensor_peak_bytes,
        (unsigned long long)plan.scratch_peak_bytes,(unsigned long long)rgb_bytes,(unsigned long long)(model_bytes+rgb_bytes+plan.inference_peak_bytes));
    if(plan_only) {
        printf("{\"model_bytes\":%llu,\"tensor_peak_bytes\":%llu,\"scratch_peak_bytes\":%llu,\"inference_peak_bytes\":%llu,\"model_input_inference_bytes\":%llu,\"convolutions\":%u,\"nodes\":%u,\"head_locations\":%u}\n",
            (unsigned long long)plan.model_bytes,(unsigned long long)plan.tensor_peak_bytes,(unsigned long long)plan.scratch_peak_bytes,
            (unsigned long long)plan.inference_peak_bytes,(unsigned long long)(model_bytes+rgb_bytes+plan.inference_peak_bytes),plan.convolution_count,network.node_count,plan.head_locations);
        free(blob);return 0;
    }
    size_t input_bytes=0;unsigned char *rgb=read_file(image,&input_bytes);if(!rgb){free(blob);return 5;}
    struct trace trace={0};
    if(trace_path){trace.file=fopen(trace_path,"wb");if(!trace.file)return 6;fwrite("YTRC1\0\0\0",1,8,trace.file);}
    if(reference){char magic[8];trace.reference=fopen(reference,"rb");if(!trace.reference||fread(magic,1,8,trace.reference)!=8||memcmp(magic,"YTRC1\0\0\0",8))return 6;}
    if(progress){trace.progress=fopen(progress,"w");if(!trace.progress)return 6;}
    if(library) {
        trace.library=dlopen(library,RTLD_NOW|RTLD_LOCAL);if(!trace.library){fprintf(stderr,"%s\n",dlerror());return 6;}
        void *(*create)(uint64_t,uint64_t,uint64_t,uint32_t)=(void *(*)(uint64_t,uint64_t,uint64_t,uint32_t))dlsym(trace.library,"yolo_npu_rtl_create");
        trace.rtl_conv=(int (*)(void *,const struct yolo_conv *))dlsym(trace.library,"yolo_npu_rtl_conv");
        trace.rtl_stats=(void (*)(void *,struct yolo_npu_rtl_stats *))dlsym(trace.library,"yolo_npu_rtl_get_stats");
        trace.rtl_destroy=(void (*)(void *))dlsym(trace.library,"yolo_npu_rtl_destroy");
        void (*set_progress)(void *,void (*)(void *,uint64_t,uint64_t),void *)=(void (*)(void *,void (*)(void *,uint64_t,uint64_t),void *))dlsym(trace.library,"yolo_npu_rtl_progress");
        if(!create||!trace.rtl_conv||!trace.rtl_stats||!trace.rtl_destroy||!set_progress)return 6;
        trace.rtl=create(10000,10000,1700,19);if(!trace.rtl)return 6;set_progress(trace.rtl,tile_progress,&trace);
    }
    struct yolo_detection boxes[1024];struct yolo_network_stats stats;
    struct yolo_network_backend backend={convolve,&trace,NULL,NULL};struct yolo_network_allocator allocator={alloc,dealloc,NULL};
    double start=seconds();error=yolo_network_infer_rgb888(&network,rgb,input_bytes,backend,allocator,0.25f,0.45f,boxes,1024,&stats);double duration=seconds()-start;
    if(trace.file&&fclose(trace.file))error=YOLO_NET_BACKEND;
    if(trace.reference){if(!error&&fgetc(trace.reference)!=EOF)error=YOLO_NET_BACKEND;fclose(trace.reference);}
    if(trace.progress)fclose(trace.progress);
    struct yolo_npu_rtl_stats rtl_stats={0};
    if(trace.rtl){trace.rtl_stats(trace.rtl,&rtl_stats);trace.rtl_destroy(trace.rtl);dlclose(trace.library);}
    if(error){fprintf(stderr,"inference error=%d\n",error);free(rgb);free(blob);return 7;}
    struct rusage usage;getrusage(RUSAGE_SELF,&usage);
    FILE *report=fopen(output,"w");if(!report){free(rgb);free(blob);return 8;}
    fprintf(report,"{\n  \"backend\":\"%s\",\n  \"convolutions\":%u,\"nodes\":%u,\"useful_macs\":%llu,\n  \"inference_peak_bytes\":%llu,\"rss_kib\":%ld,\"seconds\":%.6f,\n  \"reference_checked_outputs\":%llu,\"sys_cycles\":%llu,\"npu_cycles\":%llu,\"csr_reads\":%llu,\"csr_writes\":%llu,\n  \"candidates\":%u,\"detections\":%u,\"written\":%u,\n  \"boxes\":[",
        library?"real AXI/CDC/NPU RTL convolution; native C graph; no RISC-V CPU/UART/HDMI":"native scalar INT8 reference; no RTL or FPGA",
        stats.conv_calls,stats.nodes_executed,(unsigned long long)stats.useful_macs,(unsigned long long)stats.allocation_peak_bytes,
        usage.ru_maxrss,duration,(unsigned long long)trace.checked_outputs,(unsigned long long)rtl_stats.sys_cycles,(unsigned long long)rtl_stats.npu_cycles,(unsigned long long)rtl_stats.reads,(unsigned long long)rtl_stats.writes,stats.candidates,stats.detections,stats.written);
    for(unsigned i=0;i<stats.written;i++) {
        struct yolo_detection d=boxes[i];
        fprintf(report,"%s{\"class_id\":%u,\"score\":%.9g,\"objectness\":%.9g,\"class_probability\":%.9g,\"box_xyxy\":[%.9g,%.9g,%.9g,%.9g]}",i?",":"",d.class_id,d.score,d.objectness,d.class_probability,d.x1,d.y1,d.x2,d.y2);
    }
    fprintf(report,"]\n}\n");fclose(report);
    printf("PASS YOLO full %s conv=%u nodes=%u detections=%u peak=%llu rss_kib=%ld seconds=%.3f checked=%llu\n",library?"real NPU RTL + native C graph":"native scalar reference",stats.conv_calls,stats.nodes_executed,stats.detections,(unsigned long long)stats.allocation_peak_bytes,usage.ru_maxrss,duration,(unsigned long long)trace.checked_outputs);
    free(rgb);free(blob);return 0;
}
