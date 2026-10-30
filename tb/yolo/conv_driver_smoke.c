/* Module: yolo_conv_driver_smoke
 * Description: Run the production tiled driver through the real integer Core and NPU MMIO.
 */
#include <stdint.h>
#include "benchmark_runtime.h"
#include "../../software/yolo/conv_schedule.h"
#include "../../software/yolo/network.h"

static int8_t input[2048], weight[4096];
static int32_t output[2048], bias[17];

static uint32_t device_read(void *context, uint32_t offset)
{
    return *(volatile uint32_t *)((uintptr_t)context + offset);
}

static void device_write(void *context, uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *)((uintptr_t)context + offset) = value;
}

static int exercise(uint32_t width, uint32_t height, uint32_t cin, uint32_t cout,
                    uint32_t kernel, uint32_t stride, uint32_t pad)
{
    uint32_t ow = (width + 2 * pad - kernel) / stride + 1;
    uint32_t oh = (height + 2 * pad - kernel) / stride + 1;
    for (uint32_t i = 0; i < width * height * cin; ++i)
        input[i] = (int8_t)((i * 13 + 3) % 31 - 15);
    for (uint32_t i = 0; i < kernel * kernel * cin * cout; ++i)
        weight[i] = (int8_t)((i * 7 + 1) % 17 - 8);
    for (uint32_t i = 0; i < cout; ++i) bias[i] = (int32_t)i - 8;
    for (uint32_t i = 0; i < ow * oh * cout; ++i) output[i] = 0x5a5a5a5a;
    struct yolo_conv convolution = { input, weight, bias, output,
        width, height, cin, cout, kernel, stride, pad };
    struct yolo_npu_io io = { device_read, device_write, (void *)(uintptr_t)0x20000000u };
    int error = yolo_conv_s8(&convolution, io);
    if (error) return error;
    /* 标量对照也由被测Core执行，覆盖通道尾、halo和空间分块的完整输出。 */
    for (uint32_t oc = 0; oc < cout; ++oc)
        for (uint32_t y = 0; y < oh; ++y)
            for (uint32_t x = 0; x < ow; ++x) {
                int32_t expected = bias[oc];
                for (uint32_t ic = 0; ic < cin; ++ic)
                    for (uint32_t ky = 0; ky < kernel; ++ky)
                        for (uint32_t kx = 0; kx < kernel; ++kx) {
                            int32_t sx = (int32_t)(x * stride + kx) - (int32_t)pad;
                            int32_t sy = (int32_t)(y * stride + ky) - (int32_t)pad;
                            if (sx >= 0 && sy >= 0 && sx < (int32_t)width && sy < (int32_t)height)
                                expected += input[(ic * height + (uint32_t)sy) * width + (uint32_t)sx] *
                                    weight[((oc * cin + ic) * kernel + ky) * kernel + kx];
                        }
                if (output[(oc * oh + y) * ow + x] != expected) return 100;
            }
    return 0;
}

int main(void)
{
    int error = exercise(5, 3, 9, 17, 3, 2, 1);
    if (error) return 1000 + error;
    error = exercise(17, 2, 3, 2, 1, 1, 0);
    if (error) return 2000 + error;
    error = exercise(1, 1, 768, 1, 1, 1, 0);
    if (error) return 3000 + error;
    volatile float values[5] = { -127.0f, 127.0f, 2.5f, 3.5f, 0.0f };
    float prepared[5], scale = 0;
    int8_t quantized[5];
    for (uint32_t i = 0; i < 5; ++i) prepared[i] = values[i];
    if (yolo_network_quantize(prepared, 5, quantized, &scale) || scale != 1.0f ||
        quantized[0] != -127 || quantized[1] != 127 || quantized[2] != 2 ||
        quantized[3] != 4 || quantized[4] != 0) return 4000;
    const char *text = "PASS yolo production driver cases=3 outputs=171 quantize=5 real-core real-NPU\n";
    while (*text) benchmark_putchar(*text++);
    return 0;
}
