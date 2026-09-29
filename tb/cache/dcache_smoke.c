/* Module: dcache_smoke
 * Description: DDR loads/stores and explicit DMA ownership transfer with successful and partial-fault copies.
 */
#include <stdint.h>
#include "cache_maintenance.h"
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define REGXL(a) (*(volatile uintptr_t *)(uintptr_t)(a))
#define DDR 0x80000000u
#define DMA 0x10030000u
#define SOC 0x10040000u
static volatile uintptr_t source[4], destination[4];

static uint32_t transfer(uint32_t from, uint32_t to, uint32_t bytes)
{
    REG32(DMA) = from;
    REG32(DMA + 4) = to;
    REG32(DMA + 8) = bytes;
    REG32(DMA + 12) = 1;
    for (unsigned int i = 0; i < 10000; i++) {
        /* DMA 期间可访问不重叠的 CPU 私有区，首个冷读与 DMA 争用 DDR。 */
        if (REGXL(DDR + 0x300) != 0) return 0;
        uint32_t status = REG32(DMA + 16);
        if (status & 6u) return status;
    }
    return 0;
}
int main(void)
{
    if (REG32(SOC + 0x24) != (TEST_DCACHE_ENABLE ? 3u : 0u) || REG32(SOC + 0x28) != 4096 ||
        REG32(SOC + 0x2c) != 32) return 1;
    for (unsigned int i = 0; i < 4; i++) {
        source[i] = 0x432100u + i;
        REGXL(DDR + i*sizeof(uintptr_t)) = 0x765400u + i;
    }
    /* 预热后分别走字节/半字/全字写命中，检查 Load 符号扩展和 byte lane。 */
    for (unsigned int i = 0; i < 16; i++)
        if (REGXL(DDR) != 0x765400u) return 2;
    *(volatile uint8_t *)(uintptr_t)(DDR + 1) = 0x80;
    if (*(volatile int8_t *)(uintptr_t)(DDR + 1) != -128) return 3;
    *(volatile uint16_t *)(uintptr_t)(DDR + 2) = 0xabcd;
    if (*(volatile uint16_t *)(uintptr_t)(DDR + 2) != 0xabcd) return 4;
    REGXL(DDR) = 0x998877u;
    /* DMA 绕过 D$；测试先刻意观察尚未发布的旧 DDR，再 clean 发布脏数据。 */
    if ((transfer(DDR, (uint32_t)(uintptr_t)destination, sizeof(uintptr_t)) & 6u) != 2u) return 14;
    if (destination[0] != (TEST_DCACHE_ENABLE ? 0u : 0x998877u)) return 15;
    if (cache_maintain(CACHE_CLEAN)) return 16;
    if ((transfer(DDR, (uint32_t)(uintptr_t)destination, sizeof(uintptr_t)) & 6u) != 2u) return 5;
    if (destination[0] != 0x998877u) return 6;

    /* 转交目的区前 flush；随后只为测试陈旧读取而预热一份干净副本。 */
    if (cache_maintain(CACHE_FLUSH)) return 17;
    if (REGXL(DDR) != 0x998877u) return 18;
    if ((transfer((uint32_t)(uintptr_t)source, DDR, sizeof(source)) & 6u) != 2u) return 7;
    __asm__ volatile("fence rw, rw" ::: "memory");
    /* 仅在定向测试中观察陈旧值；正式软件应先维护，再取得 DMA 目的区所有权。 */
    if (REGXL(DDR) != (TEST_DCACHE_ENABLE ? 0x998877u : source[0])) return 8;
    if (cache_maintain(CACHE_INVALIDATE)) return 19;
    for (unsigned int i = 0; i < 4; i++)
        if (REGXL(DDR + i*sizeof(uintptr_t)) != source[i]) return 9;

    if (cache_maintain(CACHE_FLUSH)) return 20;
    /* TB 只在第二个目标字注入 AXI 写错；第一字已完成，不能把 ERROR 当成全回滚。 */
    if (REGXL(DDR + 0x100) != 0 || REGXL(DDR + 0x100 + sizeof(uintptr_t)) != 0) return 10;
    if ((transfer((uint32_t)(uintptr_t)source, DDR + 0x100, 2*sizeof(uintptr_t)) & 6u) != 4u) return 11;
    if (REG32(DMA + 20) != sizeof(uintptr_t) ||
        REG32(DMA + 24) != DDR + 0x100 + sizeof(uintptr_t)) return 12;
    if (cache_maintain(CACHE_INVALIDATE)) return 19;
    if (REGXL(DDR + 0x100) != source[0] || REGXL(DDR + 0x100 + sizeof(uintptr_t)) != 0) return 13;
    return 0;
}
