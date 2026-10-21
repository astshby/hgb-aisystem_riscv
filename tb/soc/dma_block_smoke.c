/* Module: dma_block_smoke
 * Description: Exercises real CPU-driven DMA block copies and explicit cache ownership.
 */
#include <stdint.h>
#include "benchmark_runtime.h"
#include "../cache/cache_maintenance.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DMA 0x10030000u
#define DDR 0x80000000u
#define GUARD 32u
#define TCM_BYTES 448u

static volatile uint8_t tcm_source[TCM_BYTES] __attribute__((aligned(32)));
static volatile uint8_t tcm_target[TCM_BYTES] __attribute__((aligned(32)));

static uint8_t pattern(unsigned int index, unsigned int seed)
{
    return (uint8_t)((index * 13u) ^ (index >> 3) ^ seed);
}

static void report(const char *text)
{
    while (*text) benchmark_putchar(*text++);
}

/* 软件不根据启动写响应判断完成；只在 BUSY 退去后读取保留的 DONE/ERROR。 */
static int transfer(uint32_t source, uint32_t target, uint32_t length,
                    uint32_t expected_code)
{
    REG32(DMA + 0x10) = 6;
    if (REG32(DMA + 0x10) != 0) return 1;
    REG32(DMA + 0x00) = source;
    REG32(DMA + 0x04) = target;
    REG32(DMA + 0x08) = length;
    __asm__ volatile("fence rw, rw" ::: "memory");
    REG32(DMA + 0x0c) = 1;  /* 本专项轮询，真实 IRQ 由已有 dma_smoke 覆盖。 */
    uint32_t status = 0;
    for (unsigned int i = 0; i < 100000; i++) {
        status = REG32(DMA + 0x10);
        if (!(status & 1u) && (status & 6u)) break;
    }
    if ((status & 7u) != (expected_code ? 4u : 2u)) return 2;
    if (REG32(DMA + 0x14) != (expected_code ? 0u : length)) return 3;
    if (REG32(DMA + 0x1c) != expected_code) return 4;
    if (expected_code == 0 && REG32(DMA + 0x18) != 0) return 5;
    if (expected_code != 0 && REG32(DMA + 0x18) != source) return 6;
    /* DONE 不应是脉冲；再次读取仍有效，W1C 后才允许下一笔命令。 */
    if (REG32(DMA + 0x10) != status) return 7;
    REG32(DMA + 0x10) = 6;
    if (REG32(DMA + 0x10) != 0) return 8;
    __asm__ volatile("fence rw, rw" ::: "memory");
    return 0;
}

/* 源/目的不重叠；两侧 GUARD 包括目标共享缓存行中不属于 DMA 的字节。 */
static int ddr_copy(uint32_t source_address, uint32_t target_address,
                    unsigned int length, unsigned int seed, uint32_t maintenance)
{
    volatile uint8_t *source = (volatile uint8_t *)(uintptr_t)(source_address - GUARD);
    volatile uint8_t *target = (volatile uint8_t *)(uintptr_t)(target_address - GUARD);
    for (unsigned int i = 0; i < length + 2 * GUARD; i++) {
        source[i] = pattern(i, seed);
        target[i] = pattern(i, seed ^ 0xa5u);
    }
    /* CLEAN 发布脏源和目标哨兵但保留干净副本；FLUSH 同时失效。
     * DMA 拥有这两个范围时 CPU 不访问它们，禁止脏行后写回覆盖 DMA 结果。 */
    if (cache_maintain(maintenance)) return 10;
    int result = transfer(source_address, target_address, length, 0);
    if (result) return result;
    /* 完成状态保证 DMA 写响应结束，不代表 CPU 缓存自动一致。 */
    if (cache_maintain(CACHE_INVALIDATE)) return 11;
    for (unsigned int i = 0; i < length + 2 * GUARD; i++) {
        uint8_t expected = pattern(i, (i >= GUARD && i < length + GUARD) ?
                                      seed : (seed ^ 0xa5u));
        if (source[i] != pattern(i, seed)) return 12;
        if (target[i] != expected) return 13;
    }
    return 0;
}

static int tcm_fallback(void)
{
    volatile uint8_t *external = (volatile uint8_t *)(uintptr_t)(DDR + 0xa000);
    for (unsigned int i = 0; i < TCM_BYTES; i++) {
        tcm_source[i] = pattern(i, 0x47);
        tcm_target[i] = pattern(i, 0x92);
        external[i] = pattern(i, 0xc6);
    }
    /* TCM 不经 D-cache；只需要发布 DDR 目标的旧脏行与同线哨兵。 */
    if (cache_maintain(CACHE_FLUSH)) return 10;
    int result = transfer((uint32_t)(uintptr_t)&tcm_source[5], DDR + 0xa023, 353, 0);
    if (result) return result;
    if (cache_maintain(CACHE_INVALIDATE)) return 11;
    for (unsigned int i = 0; i < TCM_BYTES; i++) {
        uint8_t expected = i >= 35 && i < 388 ? pattern(i - 30, 0x47) : pattern(i, 0xc6);
        if (external[i] != expected || tcm_source[i] != pattern(i, 0x47)) return 12;
    }
    /* 上一步只读 DDR，行已干净；CLEAN 明确将所有权交回 DMA。 */
    if (cache_maintain(CACHE_CLEAN)) return 13;
    result = transfer(DDR + 0xa023, (uint32_t)(uintptr_t)&tcm_target[7], 353, 0);
    if (result) return result;
    if (cache_maintain(CACHE_INVALIDATE)) return 14;
    for (unsigned int i = 0; i < TCM_BYTES; i++) {
        uint8_t expected = i >= 7 && i < 360 ? pattern(i - 2, 0x47) : pattern(i, 0x92);
        uint8_t external_expected = i >= 35 && i < 388 ? pattern(i - 30, 0x47) : pattern(i, 0xc6);
        if (tcm_target[i] != expected || external[i] != external_expected) return 15;
    }
    return 0;
}

int main(void)
{
    int result = ddr_copy(DDR + 0x0800, DDR + 0x2800, 1024, 0x19, CACHE_CLEAN);
    if (result) return 10 + result;
    report("DMA BLOCK aligned-1024 OK\n");

    /* 两端均跨 4 KiB，离页尾距离不同；合法突发必须在各自页内切分。 */
    result = ddr_copy(DDR + 0x3fc0, DDR + 0x5fe0, 640, 0x37, CACHE_FLUSH);
    if (result) return 30 + result;
    report("DMA BLOCK page-crossing-640 OK\n");

    result = ddr_copy(DDR + 0x7803, DDR + 0x8803, 611, 0x58, CACHE_CLEAN);
    if (result) return 50 + result;
    report("DMA BLOCK head-body-tail-611 OK\n");

    /* 不同字节偏移不能共同对齐到 32B，不得为了宽传输扩写邻居。 */
    result = ddr_copy(DDR + 0xb005, DDR + 0xc00b, 137, 0x6d, CACHE_FLUSH);
    if (result) return 70 + result;
    report("DMA BLOCK unequal-offset-137 OK\n");

    result = tcm_fallback();
    if (result) return 90 + result;
    report("DMA BLOCK TCM-DDR-TCM-353 OK\n");

    /* 非存储器源必须整笔拒绝；失败不会覆盖目的，也不能污染下一笔命令。 */
    result = transfer(0x10000000u, (uint32_t)(uintptr_t)tcm_target, 16, 1);
    if (result) return 110 + result;
    for (unsigned int i = 0; i < 16; i++) {
        uint8_t expected = i >= 7 ? pattern(i - 2, 0x47) : pattern(i, 0x92);
        if (tcm_target[i] != expected) return 119;
    }
    result = ddr_copy(DDR + 0x0800, DDR + 0x2800, 1024, 0xf2, CACHE_FLUSH);
    if (result) return 120 + result;
    report("DMA BLOCK reject-restart-1024 OK\n");
    return 0;
}
