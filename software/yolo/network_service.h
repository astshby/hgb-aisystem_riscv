/* Module: yolo_network_service
 * Description: UART model publication, reusable DDR inference storage and the real NPU1 convolution backend.
 */
#ifndef YOLO_NETWORK_SERVICE_H
#define YOLO_NETWORK_SERVICE_H
#include "demo_protocol.h"
#include "network.h"
#include "network_pool.h"
#include "video_service.h"
#define YOLO_SERVICE_ARENA_ADDRESS 0x84000000u
#define YOLO_SERVICE_ARENA_BYTES (64u*1024u*1024u)
#define YOLO_SERVICE_BOXES 32u
#define YOLO_SERVICE_RESULT_BYTES (4u+YOLO_SERVICE_BOXES*24u)

struct yolo_network_service {
    struct ydm_network endpoint;
    struct yolo_network model;
    struct yolo_network_pool pool;
    struct yolo_npu_io npu;
    struct yolo_network_plan plan;
    struct yolo_network_stats stats;
    uint8_t *model_memory, *frame, *arena;
    size_t model_capacity, arena_capacity;
    uint32_t model_valid, cached, annotated, cached_width, cached_height, cached_bytes;
    uint8_t result[YOLO_SERVICE_RESULT_BYTES];
    struct yolo_detection boxes[YOLO_SERVICE_BOXES];
    struct yolo_video_display display;
};
void yolo_network_service_init(struct yolo_network_service *);
const struct ydm_network *yolo_network_service_endpoint(struct yolo_network_service *);
void yolo_network_service_frame_changed(struct yolo_network_service *);
int yolo_network_service_set_video(struct yolo_network_service *,uint32_t *,uint32_t *,struct yolo_video_io);
/* 启动装载者已把真实资产放在模型DDR区时复用同一验证；0无资产，1已发布，-1损坏。 */
int yolo_network_service_try_preloaded(struct yolo_network_service *);
/* 显式配置地址/CSR仅用于软件移植与定向测试，不会安装标量卷积回退。 */
int yolo_network_service_configure(struct yolo_network_service *,uint8_t *model,size_t model_bytes,
    uint8_t *frame,void *arena,size_t arena_bytes,struct yolo_npu_io);
/* 双线性采用16位定点系数，top-left放置、其余填114；目标尺寸相同则原样复制RGB。 */
int yolo_network_service_preprocess(const uint8_t *,uint32_t width,uint32_t height,
    uint8_t *,uint32_t side,float *ratio);
void yolo_network_service_draw(uint8_t *,uint32_t width,uint32_t height,
    const struct yolo_detection *,uint32_t count);
#endif
