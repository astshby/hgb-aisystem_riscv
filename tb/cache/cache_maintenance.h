/* Module: cache_maintenance
 * Description: Test-only helpers for the asynchronous platform cache-maintenance ABI.
 */
#ifndef TB_CACHE_MAINTENANCE_H
#define TB_CACHE_MAINTENANCE_H
#include <stdint.h>
#define CACHE_INVALIDATE 1u
#define CACHE_CLEAN 2u
#define CACHE_FLUSH 3u
static int cache_maintain(uint32_t operation)
{
    volatile uint32_t *const registers = (volatile uint32_t *)(uintptr_t)0x10040000u;
    /* 项目 MMIO 命令，不是标准 CMO；写响应仅表示入队，状态不忙才表示完成。 */
    __asm__ volatile("fence rw, rw" ::: "memory");
    registers[0x20 / 4] = operation;
    for (unsigned int i = 0; i < 100000; i++) {
        uint32_t status = registers[0x30 / 4];
        if (!(status & 1u)) {
            __asm__ volatile("fence rw, rw" ::: "memory");
            return (status & 6u) ? -1 : 0;
        }
    }
    return -1;
}
#endif
