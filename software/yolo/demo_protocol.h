// Module: yolo_demo_protocol
// Description: Bounded UART image transport, framebuffer ownership and explicit model readiness.
#ifndef YOLO_DEMO_PROTOCOL_H
#define YOLO_DEMO_PROTOCOL_H
#include <stdint.h>

#define YDM_MAGIC 0x314d4459u /* little-endian "YDM1" */
#define YDM_VERSION 1u
#define YDM_CHUNK_BYTES 1024u
#define YDM_MAX_PAYLOAD (YDM_CHUNK_BYTES + 4u)
#define YDM_MAX_WIDTH 1920u
#define YDM_MAX_HEIGHT 1080u
#define YDM_FRAME_BYTES (YDM_MAX_WIDTH * YDM_MAX_HEIGHT * 3u)
#define YDM_FRAME_ADDRESS 0x81000000u
#define YDM_MODEL_ADDRESS 0x82000000u
#define YDM_MODEL_BYTES (16u * 1024u * 1024u)
#define YDM_READY 0x9000u
#define YDM_RGB888 1u

enum ydm_command { YDM_STATUS=1, YDM_BEGIN, YDM_CHUNK, YDM_END,
    YDM_DETECT, YDM_READ, YDM_SELFTEST, YDM_CANCEL,
    YDM_MODEL_BEGIN, YDM_MODEL_CHUNK, YDM_MODEL_END };
enum ydm_error { YDM_OK=0, YDM_HEADER=1, YDM_CRC=2, YDM_LENGTH=3,
    YDM_STATE=4, YDM_RANGE=5, YDM_NOT_READY=6, YDM_MEMORY=7,
    YDM_OPERATOR=8, YDM_UNKNOWN=9, YDM_MODEL_ERROR=10 };
enum ydm_capability { YDM_CAP_RGB=1u, YDM_CAP_READ=2u,
    YDM_CAP_SELFTEST=4u, YDM_CAP_DETECT=8u, YDM_CAP_HDMI=16u, YDM_CAP_MODEL=32u };

/* get 返回 1 表示收到字节；0 表示超时/链路错误。每块 ACK 后主机再发下一块。 */
struct ydm_io {
    int (*get)(void *, uint8_t *);
    void (*put)(void *, uint8_t);
    void (*store)(void *, uint32_t, uint8_t);
    uint8_t (*load)(void *, uint32_t);
    int (*flush)(void *);
    int (*selftest)(void *);
    void *context;
};
/* 模型存储和整图执行独立于图像收发；未安装后端时保持旧 SELFTEST 接口。 */
struct ydm_network {
    void (*invalidate)(void *);
    void (*store)(void *, uint32_t, uint8_t);
    int (*publish)(void *, uint32_t);
    int (*ready)(void *);
    int (*detect)(void *, uint32_t, uint32_t, uint8_t *, uint32_t *);
    void *context;
    uint32_t (*capabilities)(void *);
};
struct ydm_demo {
    struct ydm_io io;
    uint32_t width, height, bytes, received, expected_crc, running_crc;
    uint32_t valid, receiving, frame_id;
    uint8_t payload[YDM_MAX_PAYLOAD];
    const struct ydm_network *network;
    uint32_t model_receiving, model_bytes, model_received, model_crc, model_running_crc;
};
uint32_t ydm_crc_update(uint32_t crc, const uint8_t *data, uint32_t bytes);
void ydm_init(struct ydm_demo *demo, struct ydm_io io);
void ydm_set_network(struct ydm_demo *demo, const struct ydm_network *network);
void ydm_abort(struct ydm_demo *demo);
void ydm_ready(struct ydm_demo *demo);
int ydm_receive_one(struct ydm_demo *demo);
#endif
