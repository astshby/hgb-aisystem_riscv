// Module: yolo_application
// Description: Bare-metal convolution validation and asynchronous DMA scheduling on the full SoC.
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
static volatile uint8_t source[512] __attribute__((aligned(32)));
static volatile uint8_t destination[512] __attribute__((aligned(32)));

static int copy(uint32_t src, uint32_t dst, unsigned bytes)
{
    REG(0x10030010) = 6;
    REG(0x10030000) = src;
    REG(0x10030004) = dst;
    REG(0x10030008) = bytes;
    REG(0x1003000c) = 1;
    for (unsigned i = 0; i < 50000; i++) {
        unsigned status = REG(0x10030010);
        if (status & 6) return (status & 7) == 2 && REG(0x10030014) == bytes ? 0 : 1;
    }
    return 2;
}

static int maintain(unsigned command)
{
    REG(0x10040020) = command;
    for (unsigned i = 0; i < 50000; i++) {
        unsigned status = REG(0x10040030);
        if (!(status & 1)) return (status & 0x1e) != 0;
    }
    return 1;
}

#define YOLO_DMA_OVERLAP 1
#include "npu_workload.h"
int main(void) { return npu_platform_test(); }
