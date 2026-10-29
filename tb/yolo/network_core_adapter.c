/* Module: yolo_network_core_adapter
 * Description: Bare-metal console, assertion and allocator adapters for the unchanged graph operator checks.
 */
#include <stddef.h>
#include <stdint.h>
#include "benchmark_runtime.h"
#include "../../software/yolo/network_pool.h"

extern volatile unsigned int tohost;
static uint8_t arena[8192] __attribute__((aligned(16)));
static struct yolo_network_pool pool;
static unsigned initialized;

void *malloc(size_t bytes)
{
    if (!initialized) {
        if (yolo_network_pool_init(&pool, arena, sizeof(arena))) return NULL;
        initialized = 1;
    }
    return yolo_network_pool_allocate(&pool, bytes);
}

void free(void *memory)
{
    yolo_network_pool_release(&pool, memory);
}

int puts(const char *text)
{
    while (*text) benchmark_putchar(*text++);
    benchmark_putchar('\n');
    return 0;
}

__attribute__((noreturn)) void __assert_func(const char *file, int line,
                                            const char *function, const char *expression)
{
    (void)file;
    (void)function;
    (void)expression;
    puts("FAIL YOLO graph operator assertion");
    tohost = ((uint32_t)line << 1) | 1u;
    for (;;) __asm__ volatile("wfi");
}
