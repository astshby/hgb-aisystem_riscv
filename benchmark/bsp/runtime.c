#include "benchmark_runtime.h"

volatile unsigned int tohost __attribute__((section(".tohost"), aligned(8))) = 0;
volatile unsigned int fromhost __attribute__((section(".tohost"), aligned(8))) = 0;
volatile unsigned char sim_console __attribute__((section(".sim_console"))) = 0;

benchmark_cycle_t benchmark_read_cycle(void)
{
#if __riscv_xlen == 32
    unsigned int high_before;
    unsigned int low;
    unsigned int high_after;

    do
    {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(high_before));
        __asm__ volatile("csrr %0, mcycle" : "=r"(low));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(high_after));
    } while (high_before != high_after);
    return ((benchmark_cycle_t)high_after << 32) | low;
#else
    benchmark_cycle_t value;

    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
#endif
}

void benchmark_putchar(char value)
{
    sim_console = (unsigned char)value;
}

void *memcpy(void *destination, const void *source, unsigned long count)
{
    unsigned char *dst = (unsigned char *)destination;
    const unsigned char *src = (const unsigned char *)source;

    while (count-- != 0)
        *dst++ = *src++;
    return destination;
}

void *memset(void *destination, int value, unsigned long count)
{
    unsigned char *dst = (unsigned char *)destination;

    while (count-- != 0)
        *dst++ = (unsigned char)value;
    return destination;
}
