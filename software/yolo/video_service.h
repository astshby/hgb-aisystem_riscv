/* Module: yolo_video_service
 * Description: XRGB double-buffer publication after cache clean and a complete displayed frame.
 */
#ifndef YOLO_VIDEO_SERVICE_H
#define YOLO_VIDEO_SERVICE_H
#include <stdint.h>
#define YOLO_VIDEO_MMIO 0x10070000u
#define YOLO_VIDEO_A 0x83000000u
#define YOLO_VIDEO_B 0x83800000u
#define YOLO_VIDEO_WIDTH 1920u
#define YOLO_VIDEO_HEIGHT 1080u
#define YOLO_VIDEO_STRIDE 7680u
#define YOLO_VIDEO_BYTES (YOLO_VIDEO_STRIDE * YOLO_VIDEO_HEIGHT)
struct yolo_video_io {
    uint32_t (*read)(void *,uint32_t);
    void (*write)(void *,uint32_t,uint32_t);
    int (*clean)(void *);
    void *context;
};
struct yolo_video_display {
    struct yolo_video_io io;
    uint32_t *buffer[2];
    uint32_t available,last_error,published;
};
int yolo_video_configure(struct yolo_video_display *,uint32_t *,uint32_t *,struct yolo_video_io);
int yolo_video_publish_rgb(struct yolo_video_display *,const uint8_t *,uint32_t,uint32_t);
int yolo_video_healthy(struct yolo_video_display *);
#endif
