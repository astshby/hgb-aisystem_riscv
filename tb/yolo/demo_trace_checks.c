/* Module: yolo_demo_trace_checks
 * Description: CPU-only observer/parser test; scalar computation is explicit and does not instantiate any RTL.
 */
#include "yolo_demo_app.c"

int __real_yolo_conv_s8(const struct yolo_conv *conv,struct yolo_npu_io io)
{
    (void)io;
    return yolo_network_scalar_conv(NULL,conv);
}
static int scalar_observed(void *context,const struct yolo_conv *conv)
{
    (void)context;
    struct yolo_npu_io io={0};
    return __wrap_yolo_conv_s8(conv,io);
}
static void *allocate(void *context,size_t bytes) {(void)context;return malloc(bytes);}
static void release(void *context,void *pointer) {(void)context;free(pointer);}
static uint8_t *load(const char *path,size_t *bytes)
{
    FILE *file=fopen(path,"rb");if(!file)return NULL;
    if(fseek(file,0,SEEK_END)){fclose(file);return NULL;}
    long end=ftell(file);if(end<=0||fseek(file,0,SEEK_SET)){fclose(file);return NULL;}
    *bytes=(size_t)end;uint8_t *data=malloc(*bytes);
    if(!data||fread(data,1,*bytes,file)!=*bytes){free(data);data=NULL;}
    fclose(file);return data;
}
int main(int argc,char **argv)
{
    if(argc!=5)return 2;
    size_t model_bytes=0,input_bytes=0;uint8_t *model=load(argv[1],&model_bytes),*input=load(argv[2],&input_bytes);
    if(!model||!input)return 3;
    struct yolo_network network;
    if(yolo_network_model_init(&network,model,model_bytes))return 4;
    struct yolo_demo_app app={0};
    if(yolo_demo_app_reference_begin(&app,argv[3]))return 5;
    struct yolo_detection boxes[32];struct yolo_network_stats stats;
    struct yolo_network_backend backend={scalar_observed,NULL,NULL,NULL};
    struct yolo_network_allocator allocator={allocate,release,NULL};
    if(yolo_network_infer_rgb888(&network,input,input_bytes,backend,allocator,0.25f,0.45f,boxes,32,&stats))return 6;
    if(stats.conv_calls!=83||stats.nodes_executed!=266||yolo_demo_app_reference_finish(&app,5775300))return 7;
    FILE *bad=fopen(argv[4],"wb");if(!bad)return 8;
    if(fwrite("BADTRACE",1,8,bad)!=8||fclose(bad))return 9;
    if(yolo_demo_app_reference_begin(&app,argv[4])!=1||app.reference||observed_app)return 10;
    free(input);free(model);
    puts("PASS trace observer: real scalar trace83 layers/5775300 INT32, bad-magic cleanup; CPU-only, no RTL");
    return 0;
}
