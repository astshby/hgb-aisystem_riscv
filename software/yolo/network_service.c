/* Module: yolo_network_service
 * Description: Complete model is published only after validation; repeated DETECT returns cached results for an annotated frame.
 */
#include "network_service.h"
#include <math.h>
#include <string.h>

static uint32_t csr_read(void *context,uint32_t offset)
{ (void)context; return *(volatile uint32_t *)(uintptr_t)(0x20000000u+offset); }
static void csr_write(void *context,uint32_t offset,uint32_t value)
{ (void)context; *(volatile uint32_t *)(uintptr_t)(0x20000000u+offset)=value; }
static int convolve(void *context,const struct yolo_conv *conv)
{ struct yolo_network_service *service=context; return yolo_conv_s8(conv,service->npu); }

static void invalidate(void *context)
{
    struct yolo_network_service *service=context;
    service->model_valid=service->cached=0;
}
static void store(void *context,uint32_t offset,uint8_t byte)
{ struct yolo_network_service *service=context; service->model_memory[offset]=byte; }
static int ready(void *context)
{ return ((struct yolo_network_service *)context)->model_valid!=0; }
static uint32_t capabilities(void *context)
{
    struct yolo_network_service *service=context;
    return yolo_video_healthy(&service->display)?YDM_CAP_HDMI:0;
}
static int publish(void *context,uint32_t bytes)
{
    struct yolo_network_service *service=context;
    service->model_valid=service->cached=0;
    if (bytes>service->model_capacity || yolo_network_model_init(&service->model,service->model_memory,bytes) ||
        yolo_network_memory_plan(&service->model,&service->plan)) return 1;
    uint32_t side=service->model.input_w;
    if (service->model.input_c!=3 || side!=service->model.input_h || (side!=320 && side!=416) ||
        service->plan.convolution_count!=83 ||
        service->plan.inference_peak_bytes+(uint64_t)side*side*3u+1024u*64u>service->arena_capacity) return 1;
    service->model_valid=1;
    return 0;
}
int yolo_network_service_try_preloaded(struct yolo_network_service *service)
{
    if (service->model_capacity<YOLO_NETWORK_HEADER_BYTES) return 0;
    const uint8_t *p=service->model_memory;
    if (memcmp(p,"YOLONET1",8)) return 0;
    uint32_t bytes=(uint32_t)p[12]|((uint32_t)p[13]<<8)|((uint32_t)p[14]<<16)|((uint32_t)p[15]<<24);
    if (bytes<YOLO_NETWORK_HEADER_BYTES || bytes>service->model_capacity || publish(service,bytes)) return -1;
    return 1;
}

static void axis(uint32_t index,uint32_t source,uint32_t destination,uint32_t *low,uint32_t *high,uint32_t *fraction)
{
    int64_t fixed=(int64_t)(((uint64_t)(2u*index+1u)*source<<15)/destination)-32768;
    if (fixed<=0) { *low=*high=0; *fraction=0; }
    else if ((uint64_t)fixed>=((uint64_t)(source-1u)<<16)) { *low=*high=source-1u; *fraction=0; }
    else { *low=(uint32_t)(fixed>>16); *high=*low+1u; *fraction=(uint32_t)fixed&65535u; }
}
int yolo_network_service_preprocess(const uint8_t *source,uint32_t width,uint32_t height,
    uint8_t *output,uint32_t side,float *ratio)
{
    if (!source || !output || !ratio || !width || !height || width>YDM_MAX_WIDTH || height>YDM_MAX_HEIGHT || !side || side>416) return 1;
    *ratio=(float)side/(float)(width>height ? width : height);
    if (width==side && height==side) { memcpy(output,source,(size_t)side*side*3u); return 0; }
    uint32_t resized_width=width>=height ? side : width*side/height;
    uint32_t resized_height=height>=width ? side : height*side/width;
    if (!resized_width) resized_width=1;
    if (!resized_height) resized_height=1;
    memset(output,114,(size_t)side*side*3u);
    for (uint32_t y=0;y<resized_height;y++) {
        uint32_t y0,y1,fy; axis(y,height,resized_height,&y0,&y1,&fy);
        for (uint32_t x=0;x<resized_width;x++) {
            uint32_t x0,x1,fx; axis(x,width,resized_width,&x0,&x1,&fx);
            for (uint32_t c=0;c<3;c++) {
                uint32_t top=(uint32_t)source[((size_t)y0*width+x0)*3u+c]*(65536u-fx)+
                             (uint32_t)source[((size_t)y0*width+x1)*3u+c]*fx;
                uint32_t bottom=(uint32_t)source[((size_t)y1*width+x0)*3u+c]*(65536u-fx)+
                                (uint32_t)source[((size_t)y1*width+x1)*3u+c]*fx;
                uint64_t value=(uint64_t)top*(65536u-fy)+(uint64_t)bottom*fy+(UINT64_C(1)<<31);
                output[((size_t)y*side+x)*3u+c]=(uint8_t)(value>>32);
            }
        }
    }
    return 0;
}

static float clamp(float value,float maximum)
{ return value<0 ? 0 : value>maximum ? maximum : value; }
static void pixel(uint8_t *rgb,uint32_t width,uint32_t x,uint32_t y,const uint8_t color[3])
{ for (uint32_t c=0;c<3;c++) rgb[((size_t)y*width+x)*3u+c]=color[c]; }
void yolo_network_service_draw(uint8_t *rgb,uint32_t width,uint32_t height,const struct yolo_detection *boxes,uint32_t count)
{
    if (!rgb || !width || !height) return;
    for (uint32_t i=0;i<count;i++) {
        if (!isfinite(boxes[i].x1) || !isfinite(boxes[i].y1) || !isfinite(boxes[i].x2) || !isfinite(boxes[i].y2)) continue;
        uint32_t x1=(uint32_t)clamp(boxes[i].x1,(float)(width-1u)),x2=(uint32_t)clamp(boxes[i].x2,(float)(width-1u));
        uint32_t y1=(uint32_t)clamp(boxes[i].y1,(float)(height-1u)),y2=(uint32_t)clamp(boxes[i].y2,(float)(height-1u));
        if (x2<x1 || y2<y1) continue;
        uint8_t color[3]={(uint8_t)(64u+boxes[i].class_id*53u%192u),
                          (uint8_t)(64u+boxes[i].class_id*97u%192u),(uint8_t)(64u+boxes[i].class_id*139u%192u)};
        for (uint32_t y=y1;y<=y2;y++) for (uint32_t t=0;t<2u && t<=x2-x1;t++) {
            pixel(rgb,width,x1+t,y,color); pixel(rgb,width,x2-t,y,color);
        }
        for (uint32_t x=x1;x<=x2;x++) for (uint32_t t=0;t<2u && t<=y2-y1;t++) {
            pixel(rgb,width,x,y1+t,color); pixel(rgb,width,x,y2-t,color);
        }
    }
}
static void set32(uint8_t *p,uint32_t value)
{ for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(value>>(8*i)); }
static void set_float(uint8_t *p,float value)
{ uint32_t bits; memcpy(&bits,&value,sizeof bits); set32(p,bits); }

static int detect(void *context,uint32_t width,uint32_t height,uint8_t *output,uint32_t *bytes)
{
    struct yolo_network_service *service=context;
    if (!service->model_valid || !width || !height || width>YDM_MAX_WIDTH || height>YDM_MAX_HEIGHT ||
        !output || !bytes || *bytes<YOLO_SERVICE_RESULT_BYTES) return 1;
    if (!service->cached || service->cached_width!=width || service->cached_height!=height) {
        /* 模型重载会清结果缓存；已画框的旧帧仍须重新上传，不能当成原图再推理。 */
        if (service->annotated) return 1;
        if (yolo_network_pool_init(&service->pool,service->arena,service->arena_capacity)) return 1;
        uint32_t side=service->model.input_w; size_t resized_bytes=(size_t)side*side*3u;
        uint8_t *resized=yolo_network_pool_allocate(&service->pool,resized_bytes);
        if (!resized) return 1;
        float ratio=0;
        int error=yolo_network_service_preprocess(service->frame,width,height,resized,side,&ratio);
        struct yolo_network_backend backend={convolve,service,0,0};
        struct yolo_network_allocator allocator={yolo_network_pool_allocate,yolo_network_pool_release,&service->pool};
        if (!error) error=yolo_network_infer_rgb888(&service->model,resized,resized_bytes,backend,allocator,
            0.25f,0.45f,service->boxes,YOLO_SERVICE_BOXES,&service->stats);
        yolo_network_pool_release(&service->pool,resized);
        if (error || service->pool.live || service->stats.conv_calls!=83) return 1;
        uint32_t count=service->stats.written;
        if (count>YOLO_SERVICE_BOXES) return 1;
        set32(service->result,count);
        for (uint32_t i=0;i<count;i++) {
            struct yolo_detection *box=&service->boxes[i];
            box->x1=clamp(box->x1/ratio,(float)(width-1u)); box->x2=clamp(box->x2/ratio,(float)(width-1u));
            box->y1=clamp(box->y1/ratio,(float)(height-1u)); box->y2=clamp(box->y2/ratio,(float)(height-1u));
            uint8_t *entry=service->result+4u+i*24u;
            set32(entry,box->class_id); set_float(entry+4,box->score);
            set_float(entry+8,box->x1); set_float(entry+12,box->y1); set_float(entry+16,box->x2); set_float(entry+20,box->y2);
        }
        yolo_network_service_draw(service->frame,width,height,service->boxes,count);
        if (service->display.available)
            (void)yolo_video_publish_rgb(&service->display,service->frame,width,height);
        service->annotated=1;
        service->cached=1; service->cached_width=width; service->cached_height=height;
        service->cached_bytes=4u+count*24u;
    }
    memcpy(output,service->result,service->cached_bytes); *bytes=service->cached_bytes;
    return 0;
}

int yolo_network_service_configure(struct yolo_network_service *service,uint8_t *model,size_t model_bytes,
    uint8_t *frame,void *arena,size_t arena_bytes,struct yolo_npu_io npu)
{
    if (!service || !model || !frame || !arena || !npu.read || !npu.write || model_bytes>YDM_MODEL_BYTES) return 1;
    memset(service,0,sizeof(*service));
    service->model_memory=model; service->model_capacity=model_bytes; service->frame=frame;
    service->arena=arena; service->arena_capacity=arena_bytes; service->npu=npu;
    if (yolo_network_pool_init(&service->pool,arena,arena_bytes)) return 1;
    struct ydm_network endpoint={invalidate,store,publish,ready,detect,service,capabilities};
    service->endpoint=endpoint;
    return 0;
}
#if defined(YOLO_DEMO_HDMI) && YOLO_DEMO_HDMI
static uint32_t video_read(void *context,uint32_t offset)
{ (void)context; return *(volatile uint32_t *)(uintptr_t)(YOLO_VIDEO_MMIO+offset); }
static void video_write(void *context,uint32_t offset,uint32_t value)
{ (void)context; *(volatile uint32_t *)(uintptr_t)(YOLO_VIDEO_MMIO+offset)=value; }
static int video_clean(void *context)
{
    (void)context;
#if defined(__riscv)
    __asm__ volatile("fence rw,rw":::"memory");
#endif
    volatile uint32_t *command=(volatile uint32_t *)(uintptr_t)0x10040020u;
    volatile uint32_t *status=(volatile uint32_t *)(uintptr_t)0x10040030u;
    *command=3;
    for (uint32_t poll=0;poll<1000000u;poll++)
        if (!(*status&1u)) return (*status&0x1eu)!=0;
    return 1;
}
#endif
int yolo_network_service_set_video(struct yolo_network_service *service,uint32_t *a,uint32_t *b,struct yolo_video_io io)
{ return yolo_video_configure(&service->display,a,b,io); }
void yolo_network_service_init(struct yolo_network_service *service)
{
    struct yolo_npu_io io={csr_read,csr_write,0};
    (void)yolo_network_service_configure(service,(uint8_t *)(uintptr_t)YDM_MODEL_ADDRESS,YDM_MODEL_BYTES,
        (uint8_t *)(uintptr_t)YDM_FRAME_ADDRESS,(void *)(uintptr_t)YOLO_SERVICE_ARENA_ADDRESS,YOLO_SERVICE_ARENA_BYTES,io);
#if defined(YOLO_DEMO_HDMI) && YOLO_DEMO_HDMI
    struct yolo_video_io display_io={video_read,video_write,video_clean,0};
    (void)yolo_network_service_set_video(service,(uint32_t *)(uintptr_t)YOLO_VIDEO_A,
        (uint32_t *)(uintptr_t)YOLO_VIDEO_B,display_io);
#endif
}
const struct ydm_network *yolo_network_service_endpoint(struct yolo_network_service *service)
{ return &service->endpoint; }
void yolo_network_service_frame_changed(struct yolo_network_service *service)
{ service->cached=service->annotated=0; }
