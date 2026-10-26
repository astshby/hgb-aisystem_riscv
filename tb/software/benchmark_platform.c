// Module: benchmark_platform_test
// Description: CPU-driven DMA and cache checks for the actual paired on-chip/DDR benchmark configurations.
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

#if BENCH_NPU
#include "npu_platform.h"
#endif

int main(void)
{
    if (REG(0x10040000) != __riscv_xlen) return 10;
    for (unsigned i = 0; i < 512; i++) source[i] = (uint8_t)(i * 7 + 3);
    if (copy((uint32_t)(uintptr_t)source + 3, (uint32_t)(uintptr_t)destination + 5, 157)) return 11;
    for (unsigned i = 0; i < 157; i++) if (destination[i + 5] != source[i + 3]) return 12;
#if BENCH_DDR
    if (copy((uint32_t)(uintptr_t)source, 0x80004000, 512)) return 20;
    for (unsigned i = 0; i < 512; i++) if (*(volatile uint8_t *)(uintptr_t)(0x80004000 + i) != source[i]) return 21;
    REG(0x80004000) = 0x12345678;
    if (maintain(2) || copy(0x80004000, (uint32_t)(uintptr_t)destination, 512)) return 22;
    if (*(volatile uint32_t *)destination != 0x12345678) return 23;
    REG(0x80008000) = 0x02a00513; // addi a0,zero,42
    REG(0x80008004) = 0x00008067; // ret
    if (maintain(3)) return 24;
    __asm__ volatile(".word 0x0000100f" ::: "memory");
    if (((int (*)(void))(uintptr_t)0x80008000)() != 42) return 25;
#else
    // 无 DDR 配置的非法目的命令应返回错误和零字节，不能等待不存在的 DDR 时钟。
    if (copy((uint32_t)(uintptr_t)source, 0x80004000, 32) != 1 || REG(0x10030014) != 0) return 30;
#endif
#if BENCH_NPU
    return npu_platform_test();
#else
    return 0;
#endif
}
