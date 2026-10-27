// Module: npu_platform_test
// Description: CPU-issued signed convolutions using production DMA, DDR and the NPU AXI/CDC target.
#ifndef NPU_PLATFORM_TEST_H
#define NPU_PLATFORM_TEST_H
#define NPU_REG(offset) REG(0x20000000u + (offset))
static volatile uint32_t npu_result[20] __attribute__((aligned(32)));

static int npu_input(unsigned pixel, unsigned channel)
{
    return (int)((pixel * 3 + channel * 5) % 17) - 8;
}
static int npu_weight(unsigned tap, unsigned oc, unsigned ic)
{
    return (int)((tap * 7 + oc * 3 + ic) % 13) - 6;
}
static int npu_platform_test(void)
{
    if (NPU_REG(0) != 0x4e505531 || NPU_REG(4) != 0x00010000) return 40;
    if (REG(0x1004004c) != 65536) return 41;
    // DMA 没有动作寄存器权限，失败不得启动设备或计入已写字节。
    source[0] = 1;
    if (copy((uint32_t)(uintptr_t)source, 0x20000008, 4) != 1 ||
        REG(0x10030014) != 0 || (NPU_REG(0x0c) & 1)) return 42;
    if (copy((uint32_t)(uintptr_t)source + 1, 0x20000100, 4) != 1 ||
        REG(0x10030014) != 0) return 43;
    for (unsigned test = 0; test < 2; test++) {
        unsigned width = test ? 3 : 2, height = test ? 3 : 1;
        unsigned kernel = test ? 3 : 1, co = test ? 13 : 16;
        NPU_REG(8) = 2;
        volatile int8_t *weights = (volatile int8_t *)(uintptr_t)0x80018000;
        volatile int8_t *activation = (volatile int8_t *)(uintptr_t)0x80019000;
        for (unsigned tap = 0; tap < kernel * kernel; tap++)
            for (unsigned oc = 0; oc < 16; oc++)
                for (unsigned ic = 0; ic < 8; ic++)
                    weights[tap * 128 + oc * 8 + ic] = (int8_t)npu_weight(tap, oc, ic);
        for (unsigned p = 0; p < width * height; p++)
            for (unsigned ic = 0; ic < 8; ic++) activation[p * 8 + ic] = (int8_t)npu_input(p, ic);
        if (maintain(2)) return 44;
        for (unsigned tap = 0; tap < kernel * kernel; tap++) {
            NPU_REG(0x2c) = tap;
            if (copy(0x80018000 + tap * 128, 0x20000100, 128)) return 45;
            NPU_REG(0x3c) = 1;
        }
        for (unsigned p = 0; p < width * height; p++) {
            NPU_REG(0x28) = (test << 31) | p;
            if (copy(0x80019000 + p * 8, 0x20000060, 8)) return 46;
            NPU_REG(0x38) = 1;
        }
        for (unsigned oc = 0; oc < 16; oc++) NPU_REG(0x80 + oc * 4) = oc - 7;
        NPU_REG(0x20) = width | (height << 8) | (8u << 16);
        NPU_REG(0x24) = co | (test ? (1u << 5) | (1u << 7) | (1u << 10) : (1u << 8));
#if YOLO_DMA_OVERLAP
        // 提前准备下一批 DDR 数据；启动后让 DMA 和当前卷积同时前进。
        // DMA 完成只释放该搬运任务，卷积输出仍逐项检查并显式 POP。
        for (unsigned i=0;i<1024;i++) REG(0x80008000u+i*4)=0x13572468u^i;
        if (maintain(2)) return 55;
        REG(0x10030010)=6;
        REG(0x10030000)=0x80008000;
        REG(0x10030004)=0x80010000;
        REG(0x10030008)=4096;
        REG(0x1003000c)=1;
#endif
        NPU_REG(8) = 1;
#if YOLO_DMA_OVERLAP
        unsigned dma_status=0;
        for(unsigned wait=0;wait<50000;wait++) {
            dma_status=REG(0x10030010);
            if(dma_status&6) break;
        }
        if((dma_status&7)!=2 || REG(0x10030014)!=4096 || maintain(3)) return 56;
        for(unsigned i=0;i<1024;i++) if(REG(0x80010000u+i*4)!=(0x13572468u^i)) return 57;
#endif
        for (unsigned p = 0; p < width * height; p++) {
            unsigned status = 0;
            for (unsigned wait = 0; wait < 50000; wait++) {
                status = NPU_REG(0x0c);
                if (status & 10) break;
            }
            if ((status & 10) != 2 || NPU_REG(0x10)) return 47;
            unsigned flags = NPU_REG(0x5c), meta = NPU_REG(0x58);
            if ((meta & 65535) != (1u << co) - 1 || (meta >> 16) !=
                ((p % width) | ((p / width) << 8))) return 48;
            if (!!(flags & 4) != (p == width * height - 1)) return 49;
            if (copy(0x20000200, (uint32_t)(uintptr_t)npu_result, 80)) return 50;
            for (unsigned oc = 0; oc < 16; oc++) {
                int expected = oc < co ? (int)oc - 7 : 0;
                if (oc < co) for (unsigned ky = 0; ky < kernel; ky++)
                    for (unsigned kx = 0; kx < kernel; kx++) {
                        int x = (int)(p % width + kx) - (test ? 1 : 0);
                        int y = (int)(p / width + ky) - (test ? 1 : 0);
                        if (x >= 0 && y >= 0 && x < (int)width && y < (int)height)
                            for (unsigned ic = 0; ic < 8; ic++)
                                expected += npu_input((unsigned)y * width + (unsigned)x, ic) *
                                    npu_weight(ky * kernel + kx, oc, ic);
                    }
                if ((int32_t)npu_result[oc] != expected) return 51;
                if (!test) {
                    int clamped = expected < -128 ? -128 : expected > 127 ? 127 : expected;
                    if ((int8_t)(npu_result[16 + oc / 4] >> (8 * (oc % 4))) != clamped) return 52;
                }
            }
            NPU_REG(0x44) = 1;
        }
        if ((NPU_REG(0x0c) & 15) != 4 || NPU_REG(0x10) ||
            NPU_REG(0x1c) != width * height) return 53;
        NPU_REG(0x0c) = 4;
        if (NPU_REG(0x0c) & 4) return 54;
    }
    return 0;
}
#endif
