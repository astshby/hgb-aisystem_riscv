/* Module: yolo_video_service
 * Description: The CPU writes the inactive XRGB bank, cleans it, then waits for vblank ownership transfer.
 */
#include "video_service.h"
#include <string.h>

#define VIDEO_ID 0x56494431u
#ifndef YOLO_VIDEO_POLLS
#define YOLO_VIDEO_POLLS 4000000u
#endif
#define POLLS YOLO_VIDEO_POLLS

int yolo_video_configure(struct yolo_video_display *display,uint32_t *a,uint32_t *b,struct yolo_video_io io)
{
    memset(display,0,sizeof(*display)); display->io=io;
    display->buffer[0]=a; display->buffer[1]=b;
    if (!a || !b || !io.read || !io.write || !io.clean) return 1;
    display->available=io.read(io.context,0)==VIDEO_ID;
    return display->available?0:1;
}

int yolo_video_healthy(struct yolo_video_display *display)
{
    if (!display->available || !display->published || display->last_error) return 0;
    uint32_t status=display->io.read(display->io.context,4);
    return (status&8u) && !(status&0x70u);
}

int yolo_video_publish_rgb(struct yolo_video_display *display,const uint8_t *rgb,uint32_t width,uint32_t height)
{
    if (!display->available || !rgb || !width || !height || width>YOLO_VIDEO_WIDTH || height>YOLO_VIDEO_HEIGHT)
        return display->last_error=1;
    struct yolo_video_io io=display->io;
    uint32_t status=0,poll;
    for (poll=0;poll<POLLS;poll++) {
        status=io.read(io.context,4);
        if (status&0x70u) return display->last_error=2;
        if ((status&8u) && !(status&2u)) break;
    }
    if (poll==POLLS) return display->last_error=3;
    uint32_t front=io.read(io.context,0x20);
    unsigned bank=front==YOLO_VIDEO_A?1u:0u;
    if (!(status&1u)) bank=0; // 首帧尚未启动扫描，先完整填好 A。
    uint32_t *frame=display->buffer[bank];
    memset(frame,0,YOLO_VIDEO_BYTES);
    uint32_t left=(YOLO_VIDEO_WIDTH-width)/2u,top=(YOLO_VIDEO_HEIGHT-height)/2u;
    for (uint32_t y=0;y<height;y++) for (uint32_t x=0;x<width;x++) {
        const uint8_t *pixel=rgb+((size_t)y*width+x)*3u;
        frame[(size_t)(top+y)*YOLO_VIDEO_WIDTH+left+x]=
            ((uint32_t)pixel[0]<<16)|((uint32_t)pixel[1]<<8)|pixel[2];
    }
    if (io.clean(io.context)) return display->last_error=4;
    uint32_t base=bank?YOLO_VIDEO_B:YOLO_VIDEO_A;
    io.write(io.context,8,base); io.write(io.context,0x0c,YOLO_VIDEO_WIDTH);
    io.write(io.context,0x10,YOLO_VIDEO_HEIGHT); io.write(io.context,0x14,YOLO_VIDEO_STRIDE);
    if (!(status&1u)) io.write(io.context,0x1c,1);
    io.write(io.context,0x18,1);
    for (poll=0;poll<POLLS;poll++) {
        status=io.read(io.context,4);
        if (status&0x70u) return display->last_error=5;
        if (!(status&2u) && io.read(io.context,0x20)==base) break;
    }
    if (poll==POLLS) return display->last_error=6;
    uint32_t first_frame=io.read(io.context,0x24);
    for (poll=0;poll<POLLS;poll++) {
        status=io.read(io.context,4);
        if (status&0x70u) return display->last_error=7;
        if (io.read(io.context,0x24)!=first_frame) {
            display->published++; display->last_error=0; return 0;
        }
    }
    return display->last_error=8;
}
