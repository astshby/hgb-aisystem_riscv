/* Module: yolo_demo_app_api
 * Description: The original C application modules run on a native CPU adapter around real I/O RTL.
 */
#ifndef YOLO_DEMO_APP_H
#define YOLO_DEMO_APP_H
#include "yolo_demo_io.h"
#include "network.h"
struct yolo_demo_app;
struct yolo_demo_app_state {
    uint64_t requests,model_publications,cacheless_clean_calls,frame_id,frame_bytes;
    uint64_t model_valid,frame_valid,pool_live,pool_peak,convolutions,nodes;
    uint64_t detections,display_publications,display_error,tiles,io_error;
    uint64_t reference_layers,reference_outputs;
};
struct yolo_demo_app *yolo_demo_app_create(struct yolo_demo_io *,const uint8_t *preloaded_model,
    size_t model_bytes,uint32_t baud,const char *progress_path);
void yolo_demo_app_destroy(struct yolo_demo_app *);
int yolo_demo_app_exchange(struct yolo_demo_app *,const uint8_t *packet,size_t bytes);
void yolo_demo_app_get_state(struct yolo_demo_app *,struct yolo_demo_app_state *);
int yolo_demo_app_preprocess(struct yolo_demo_app *,uint8_t *rgb,size_t capacity,float *ratio);
/* 仅作显示链定向测试：直接调用原video_service，不伪造DETECT或检测结果。 */
int yolo_demo_app_publish_current(struct yolo_demo_app *);
void yolo_demo_app_reference_rgb(uint8_t *,uint32_t width,uint32_t height,
    struct yolo_detection *,uint32_t count,float ratio);
int yolo_demo_app_reference_begin(struct yolo_demo_app *,const char *path);
int yolo_demo_app_reference_finish(struct yolo_demo_app *,uint64_t expected_outputs);
#endif
