/* Module: dcache_smoke
 * Description: DDR loads/stores and explicit DMA ownership transfer with successful and partial-fault copies.
 */
#include <stdint.h>
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define REGXL(a) (*(volatile uintptr_t *)(uintptr_t)(a))
#define DDR 0x80000000u
#define DMA 0x10030000u
#define SOC 0x10040000u
static volatile uintptr_t source[4], destination[4];

static void invalidate_data(void)
{
    /* 项目专用 MMIO 命令，不是标准 CMO；编译器也不能把缓冲区访问跨过维护操作。 */
    __asm__ volatile("fence rw, rw" ::: "memory");
    REG32(SOC + 0x20) = 1;
    __asm__ volatile("fence rw, rw" ::: "memory");
}
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
    if (REG32(SOC + 0x24) != TEST_DCACHE_ENABLE || REG32(SOC + 0x28) != 4096 ||
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
    /* CPU 写命中仍需写穿透；DMA 不经过 D$，应看到同一个最新值。 */
    if ((transfer(DDR, (uint32_t)(uintptr_t)destination, sizeof(uintptr_t)) & 6u) != 2u) return 5;
    if (destination[0] != 0x998877u) return 6;

    if ((transfer((uint32_t)(uintptr_t)source, DDR, sizeof(source)) & 6u) != 2u) return 7;
    __asm__ volatile("fence rw, rw" ::: "memory");
    /* 仅在定向测试中观察陈旧值；正式软件应先维护，再取得 DMA 目的区所有权。 */
    if (REGXL(DDR) != (TEST_DCACHE_ENABLE ? 0x998877u : source[0])) return 8;
    invalidate_data();
    for (unsigned int i = 0; i < 4; i++)
        if (REGXL(DDR + i*sizeof(uintptr_t)) != source[i]) return 9;

    /* TB 只在第二个目标字注入 AXI 写错；第一字已完成，不能把 ERROR 当成全回滚。 */
    if (REGXL(DDR + 0x100) != 0 || REGXL(DDR + 0x100 + sizeof(uintptr_t)) != 0) return 10;
    if ((transfer((uint32_t)(uintptr_t)source, DDR + 0x100, 2*sizeof(uintptr_t)) & 6u) != 4u) return 11;
    if (REG32(DMA + 20) != sizeof(uintptr_t) ||
        REG32(DMA + 24) != DDR + 0x100 + sizeof(uintptr_t)) return 12;
    invalidate_data();
    if (REGXL(DDR + 0x100) != source[0] || REGXL(DDR + 0x100 + sizeof(uintptr_t)) != 0) return 13;
    return 0;
}
