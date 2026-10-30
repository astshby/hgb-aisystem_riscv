// Module: yolo_conv_schedule
// Description: CHW/OIHW signed convolution scheduled into the production NPU1 CSR tile interface.
#ifndef YOLO_CONV_SCHEDULE_H
#define YOLO_CONV_SCHEDULE_H
#include <stdint.h>

struct yolo_conv {
    const int8_t *input;
    const int8_t *weight;
    const int32_t *bias;
    int32_t *output;
    uint32_t width, height, cin, cout, kernel, stride, pad;
};
struct yolo_npu_io {
    uint32_t (*read)(void *, uint32_t offset);
    void (*write)(void *, uint32_t offset, uint32_t value);
    void *context;
};
enum yolo_conv_error { YOLO_CONV_OK=0, YOLO_CONV_SHAPE=1, YOLO_CONV_DEVICE=2,
    YOLO_CONV_TIMEOUT=3, YOLO_CONV_RESULT=4 };
/* 输入空间<=416x416，Cin/Cout<=768，kernel=1/3，stride=1/2，pad<=kernel/2。
 * 调用者提供互不重叠的输入/权重/输出，输出空间容纳完整 CHW INT32。
 * 激活量化/SiLU/图层间调度由调用者明确处理；此接口不会自动执行整图。 */
int yolo_conv_s8(const struct yolo_conv *conv, struct yolo_npu_io io);
#endif
