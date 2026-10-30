/* Module: yolo_demo_app
 * Description: Native MMIO/timer/shared-RAM adaptation; packet handling, inference and video publication use the board C modules.
 */
#include "yolo_demo_app.h"
#include "demo_protocol.h"
#include "network_service.h"
#include "soc_clocks.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#define UART_BASE 0x10000000u
#define INFO_BASE 0x10040000u
struct yolo_demo_app {
    struct yolo_demo_io *io;
    struct ydm_demo demo;
    struct yolo_network_service network;
    struct hgb_soc_clocks clocks;
    struct yolo_demo_app_state state;
    FILE *progress;
    FILE *reference;
    int error;
};
static struct yolo_demo_app *observed_app;
int __real_yolo_conv_s8(const struct yolo_conv *,struct yolo_npu_io);
static int compare_reference(FILE *file,const void *data,size_t bytes) {
    uint8_t block[4096];const uint8_t *actual=data;
    while(bytes){size_t count=bytes<sizeof(block)?bytes:sizeof(block);
        if(fread(block,1,count,file)!=count||memcmp(block,actual,count))return 1;
        bytes-=count;actual+=count;
    }
    return 0;
}
int __wrap_yolo_conv_s8(const struct yolo_conv *conv,struct yolo_npu_io io) {
    struct yolo_demo_app *app=observed_app;
    if(!app||!app->reference)return __real_yolo_conv_s8(conv,io);
    uint32_t input=conv->width*conv->height*conv->cin;
    uint32_t output=((conv->width+2*conv->pad-conv->kernel)/conv->stride+1)*
        ((conv->height+2*conv->pad-conv->kernel)/conv->stride+1)*conv->cout;
    uint32_t layer=(uint32_t)app->state.reference_layers+1u;
    uint32_t header[10]={layer,conv->width,conv->height,conv->cin,conv->cout,
        conv->kernel,conv->stride,conv->pad,input,output};
    /* 链接观察器只比较原驱动前后的数据；所有计算仍经过真实CSR/AXI/NPU。 */
    if(compare_reference(app->reference,header,sizeof(header))||compare_reference(app->reference,conv->input,input)){
        fprintf(stderr,"FAIL reference quantized input layer=%u\n",layer);app->error=20;return YOLO_CONV_RESULT;
    }
    if(app->progress){fprintf(app->progress,"{\"event\":\"conv_begin\",\"layer\":%u,\"outputs\":%u}\n",layer,output);fflush(app->progress);}
    int error=__real_yolo_conv_s8(conv,io);
    if(error)return error;
    if(compare_reference(app->reference,conv->output,(size_t)output*4u)){
        fprintf(stderr,"FAIL reference INT32 output layer=%u\n",layer);app->error=21;return YOLO_CONV_RESULT;
    }
    app->state.reference_layers++;app->state.reference_outputs+=output;
    if(app->progress){fprintf(app->progress,"{\"event\":\"conv_complete\",\"layer\":%u,\"reference_outputs\":%llu}\n",layer,(unsigned long long)app->state.reference_outputs);fflush(app->progress);}
    return 0;
}
static uint32_t mmio_read(struct yolo_demo_app *app,uint32_t address) {
    uint32_t value=0;
    if(yolo_demo_io_read32(app->io,address,&value))app->error=1;
    return value;
}
static void mmio_write(struct yolo_demo_app *app,uint32_t address,uint32_t value) {
    if(yolo_demo_io_write32(app->io,address,value))app->error=1;
}
static uint64_t cycles(struct yolo_demo_app *app) {
    struct yolo_demo_io_stats stats;yolo_demo_io_get_stats(app->io,&stats);return stats.sys_cycles;
}
static int receive(void *context,uint8_t *value) {
    struct yolo_demo_app *app=context;uint64_t begin=cycles(app);
    while(!app->error&&cycles(app)-begin<(uint64_t)app->clocks.sys_hz*2u) {
        uint32_t status=mmio_read(app,UART_BASE+8u);
        if(status&12u){app->error=2;return 0;}
        if(status&2u){*value=(uint8_t)mmio_read(app,UART_BASE+4u);return !app->error;}
    }
    app->error=3;return 0;
}
static void transmit(void *context,uint8_t value) {
    struct yolo_demo_app *app=context;uint64_t begin=cycles(app);
    while(!app->error&&!(mmio_read(app,UART_BASE+8u)&1u))
        if(cycles(app)-begin>(uint64_t)app->clocks.sys_hz*2u){app->error=4;return;}
    if(!app->error)mmio_write(app,UART_BASE,value);
}
static void frame_store(void *context,uint32_t offset,uint8_t value) {
    struct yolo_demo_app *app=context;
    if(!offset)yolo_network_service_frame_changed(&app->network);
    app->network.frame[offset]=value;
}
static uint8_t frame_load(void *context,uint32_t offset) {
    return ((struct yolo_demo_app *)context)->network.frame[offset];
}
static int cacheless_clean(void *context) {
    struct yolo_demo_app *app=context;
    /* 该适配器没有CPU cache；共享DDR模型直接可见。此屏障不代表板级cache一致性已测。 */
    atomic_thread_fence(memory_order_seq_cst);app->state.cacheless_clean_calls++;return app->error!=0;
}
static uint32_t npu_read(void *context,uint32_t offset) {
    struct yolo_demo_app *app=context;if(app->error)return offset==0x0c?8u:0;
    return mmio_read(app,0x20000000u+offset);
}
static void npu_write(void *context,uint32_t offset,uint32_t value) {
    struct yolo_demo_app *app=context;if(!app->error)mmio_write(app,0x20000000u+offset,value);
}
static uint32_t video_read(void *context,uint32_t offset) {return mmio_read(context,YOLO_VIDEO_MMIO+offset);}
static void video_write(void *context,uint32_t offset,uint32_t value) {mmio_write(context,YOLO_VIDEO_MMIO+offset,value);}
static int selftest(void *context) {
    struct yolo_demo_app *app=context;
    int8_t input[3]={-7,9,4},weights[3]={1,-2,3};int32_t bias=5,output=0;
    struct yolo_conv conv={input,weights,&bias,&output,1,1,3,1,1,1,0};
    struct yolo_npu_io io={npu_read,npu_write,app};
    /* Native适配器的SELFTEST只做这项真实NPU小卷积，不运行原RISC-V operator ELF。 */
    return yolo_conv_s8(&conv,io)||app->error||output!=-8;
}
static void progress(void *context,uint64_t tiles,uint64_t sys_cycles) {
    struct yolo_demo_app *app=context;app->state.tiles=tiles;
    if(tiles%64)return;
    if(app->progress){fprintf(app->progress,"{\"event\":\"tile\",\"frame\":%u,\"layer\":%u,\"tiles\":%llu,\"sys_cycles\":%llu}\n",app->demo.frame_id,app->network.stats.conv_calls+1u,(unsigned long long)tiles,(unsigned long long)sys_cycles);fflush(app->progress);}
}
static int clocks(struct yolo_demo_app *app) {
    uint32_t discovery=mmio_read(app,INFO_BASE+HGB_SOC_DISCOVERY_OFFSET);
    if(discovery&HGB_SOC_CLOCK_INFO_PRESENT) {
        if(mmio_read(app,INFO_BASE+HGB_SOC_CLOCK_INFO_OFFSET)!=HGB_SOC_CLOCK_INFO_V1)return 1;
        app->clocks.core_hz=mmio_read(app,INFO_BASE+HGB_SOC_CORE_CLOCK_OFFSET);
        app->clocks.sys_hz=mmio_read(app,INFO_BASE+HGB_SOC_SYS_CLOCK_OFFSET);
        app->clocks.ddr_hz=mmio_read(app,INFO_BASE+HGB_SOC_DDR_CLOCK_OFFSET);
        app->clocks.periph_hz=mmio_read(app,INFO_BASE+HGB_SOC_PERIPH_CLOCK_OFFSET);
        app->clocks.timer_hz=mmio_read(app,INFO_BASE+HGB_SOC_TIMER_CLOCK_OFFSET);
    }else {
        uint32_t hz=mmio_read(app,INFO_BASE+HGB_SOC_LEGACY_CLOCK_OFFSET);
        app->clocks=(struct hgb_soc_clocks){hz,hz,hz,hz,hz};
    }
    return app->error||!app->clocks.sys_hz||!app->clocks.periph_hz;
}
struct yolo_demo_app *yolo_demo_app_create(struct yolo_demo_io *io,const uint8_t *model,size_t bytes,uint32_t baud,const char *progress_path) {
    if(!io||!model||!bytes||bytes>YDM_MODEL_BYTES)return NULL;
    struct yolo_demo_app *app=calloc(1,sizeof(*app));if(!app)return NULL;app->io=io;
    if(progress_path){app->progress=fopen(progress_path,"w");if(!app->progress)goto fail;}
    if(clocks(app)||yolo_demo_io_set_baud(io,baud))goto fail;
    mmio_write(app,UART_BASE+16u,0);mmio_write(app,UART_BASE+8u,12u);
    uint8_t *model_memory=yolo_demo_io_ram_ptr(io,YDM_MODEL_ADDRESS,YDM_MODEL_BYTES);
    uint8_t *frame=yolo_demo_io_ram_ptr(io,YDM_FRAME_ADDRESS,YDM_FRAME_BYTES);
    void *arena=yolo_demo_io_ram_ptr(io,YOLO_SERVICE_ARENA_ADDRESS,YOLO_SERVICE_ARENA_BYTES);
    uint32_t *a=yolo_demo_io_ram_ptr(io,YOLO_VIDEO_A,YOLO_VIDEO_BYTES);
    uint32_t *b=yolo_demo_io_ram_ptr(io,YOLO_VIDEO_B,YOLO_VIDEO_BYTES);
    if(!model_memory||!frame||!arena||!a||!b)goto fail;
    memcpy(model_memory,model,bytes);
    struct yolo_npu_io npu={npu_read,npu_write,app};
    if(yolo_network_service_configure(&app->network,model_memory,YDM_MODEL_BYTES,frame,arena,YOLO_SERVICE_ARENA_BYTES,npu))goto fail;
    struct yolo_video_io display={video_read,video_write,cacheless_clean,app};
    if(yolo_network_service_set_video(&app->network,a,b,display))goto fail;
    if(yolo_network_service_try_preloaded(&app->network)!=1)goto fail;
    app->state.model_publications=1;
    struct ydm_io packet_io={receive,transmit,frame_store,frame_load,cacheless_clean,selftest,app};
    ydm_init(&app->demo,packet_io);ydm_set_network(&app->demo,yolo_network_service_endpoint(&app->network));
    yolo_demo_io_progress(io,progress,app);ydm_ready(&app->demo);
    if(app->error)goto fail;
    return app;
fail:
    yolo_demo_io_progress(io,NULL,NULL);
    if(app->progress)fclose(app->progress);
    free(app);
    return NULL;
}
void yolo_demo_app_destroy(struct yolo_demo_app *app) {
    if(app){yolo_demo_io_progress(app->io,NULL,NULL);if(app->progress)fclose(app->progress);
        if(app->reference)fclose(app->reference);
        if(observed_app==app)observed_app=NULL;
        free(app);}
}
int yolo_demo_app_exchange(struct yolo_demo_app *app,const uint8_t *packet,size_t bytes) {
    if(!app||app->error||!packet||bytes<24||yolo_demo_io_queue_rx(app->io,packet,bytes))return 1;
    int result=ydm_receive_one(&app->demo);app->state.requests++;
    if(!result){ydm_abort(&app->demo);return 2;}
    return app->error||yolo_demo_io_error(app->io);
}
void yolo_demo_app_get_state(struct yolo_demo_app *app,struct yolo_demo_app_state *out) {
    *out=app->state;out->frame_id=app->demo.frame_id;out->frame_bytes=app->demo.bytes;
    out->frame_valid=app->demo.valid;out->model_valid=app->network.model_valid;
    out->pool_live=app->network.pool.live;out->pool_peak=app->network.pool.peak;
    out->convolutions=app->network.stats.conv_calls;out->nodes=app->network.stats.nodes_executed;
    out->detections=app->network.stats.written;out->display_publications=app->network.display.published;
    out->display_error=app->network.display.last_error;out->io_error=app->error;
}
int yolo_demo_app_preprocess(struct yolo_demo_app *app,uint8_t *rgb,size_t capacity,float *ratio) {
    uint32_t side=app->network.model.input_w;
    if(capacity<(size_t)side*side*3u)return 1;
    return yolo_network_service_preprocess(app->network.frame,app->demo.width,app->demo.height,rgb,side,ratio);
}
int yolo_demo_app_publish_current(struct yolo_demo_app *app) {
    if(!app||!app->demo.valid||app->demo.receiving)return 1;
    return yolo_video_publish_rgb(&app->network.display,app->network.frame,app->demo.width,app->demo.height);
}
static float reference_clamp(float value,float maximum) {
    return value<0?0:value>maximum?maximum:value;
}
void yolo_demo_app_reference_rgb(uint8_t *rgb,uint32_t width,uint32_t height,
    struct yolo_detection *boxes,uint32_t count,float ratio) {
    /* 独立scalar黄金框按与service相同的单精度除法/裁剪，再调用原画框函数。 */
    for(uint32_t i=0;i<count;i++) {
        boxes[i].x1=reference_clamp(boxes[i].x1/ratio,(float)(width-1u));
        boxes[i].x2=reference_clamp(boxes[i].x2/ratio,(float)(width-1u));
        boxes[i].y1=reference_clamp(boxes[i].y1/ratio,(float)(height-1u));
        boxes[i].y2=reference_clamp(boxes[i].y2/ratio,(float)(height-1u));
    }
    yolo_network_service_draw(rgb,width,height,boxes,count);
}
int yolo_demo_app_reference_begin(struct yolo_demo_app *app,const char *path) {
    if(!app||app->reference||observed_app||!path)return 1;
    app->reference=fopen(path,"rb");if(!app->reference)return 1;
    /* scalar文件先有8字节容器签名，随后才是逐层10-word header。 */
    if(compare_reference(app->reference,"YTRC1\0\0\0",8u)){
        fclose(app->reference);app->reference=NULL;return 1;
    }
    observed_app=app;return 0;
}
int yolo_demo_app_reference_finish(struct yolo_demo_app *app,uint64_t expected_outputs) {
    if(!app||!app->reference||app->state.reference_layers!=83u||
        app->state.reference_outputs!=expected_outputs||fgetc(app->reference)!=EOF)return 1;
    fclose(app->reference);app->reference=NULL;observed_app=NULL;return 0;
}
