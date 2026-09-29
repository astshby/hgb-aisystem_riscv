/* Module: icache_smoke
 * Description: Real DDR execution, CPU/DMA self-modifying code and FENCE.I integration.
 */
#include <stdint.h>
#include "cache_maintenance.h"

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define CODE 0x80000200u
#define DMA 0x10030000u
static volatile uint32_t replacement[2];

int main(void)
{
    int (*volatile function)(void) = (int (*)(void))(uintptr_t)CODE;
    REG32(CODE) = 0x02500513u;     /* ADDI a0, zero, 37 */
    REG32(CODE + 4) = 0x00008067u; /* JALR zero, ra, 0 */
    __asm__ volatile("fence.i" ::: "memory");
    for (unsigned int i = 0; i < 16; i++)
        if (function() != 37) return 1;

    /* 分支循环本身也位于 DDR；不只重复从 TCM 调用两条直线指令。 */
    REG32(CODE + 0x100) = 0x00000513u; /* ADDI a0, zero, 0 */
    REG32(CODE + 0x104) = 0x01000293u; /* ADDI t0, zero, 16 */
    REG32(CODE + 0x108) = 0x00150513u; /* ADDI a0, a0, 1 */
    REG32(CODE + 0x10c) = 0xfff28293u; /* ADDI t0, t0, -1 */
    REG32(CODE + 0x110) = 0xfe029ce3u; /* BNE t0, zero, -8 */
    REG32(CODE + 0x114) = 0x00008067u;
    __asm__ volatile("fence.i" ::: "memory");
    if (((int (*)(void))(uintptr_t)(CODE + 0x100))() != 16) return 8;
    if (function() != 37) return 9; /* 重新预热，即将由 CPU 改写的行。 */

    /* 写命中只更新 D$；普通 FENCE 不发布脏行，也不使 I$ 失效。 */
    REG32(CODE) = 0x02b00513u;
    __asm__ volatile("fence rw, rw" ::: "memory");
    if (REG32(CODE) != 0x02b00513u) return 2;
    if (function() != 37) return 3;
    __asm__ volatile("fence.i" ::: "memory");
    if (function() != 43) return 4;

    /* 必须预热目的代码，再由 DMA 改写；首次执行新地址不能证明失效有效。 */
    if (cache_maintain(CACHE_FLUSH)) return 10;
    replacement[0] = 0x03b00513u;
    replacement[1] = 0x00008067u;
    REG32(DMA) = (uint32_t)(uintptr_t)&replacement[0];
    REG32(DMA + 4) = CODE;
    REG32(DMA + 8) = sizeof(replacement);
    REG32(DMA + 12) = 1;
    unsigned int timeout = 0;
    while (!(REG32(DMA + 16) & 6u) && timeout < 10000) timeout++;
    if (timeout == 10000 || (REG32(DMA + 16) & 6u) != 2u) return 5;
    if (REG32(DMA + 20) != sizeof(replacement)) return 6;
    __asm__ volatile("fence.i" ::: "memory");
    if (function() != 59) return 7;
    if (cache_maintain(CACHE_INVALIDATE)) return 11;
    if (REG32(CODE) != replacement[0]) return 12;
    return 0;
}
