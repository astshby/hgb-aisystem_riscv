/* Module: peripheral_smoke
 * Description: Bare-metal MMIO, synchronous fault, and machine-interrupt integration test.
 */
#include <stdint.h>
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define MTIME 0x02000000u
#define IRQ 0x0c000000u
#define UART 0x10000000u
#define TIMER 0x10010000u
#define GPIO 0x10020000u
#define INFO 0x10040000u

static volatile unsigned long seen[16], external_seen[7], received[2];
static volatile unsigned long fault_count, expected_cause, expected_tval, failure;

static void set_compare(uint64_t value)
{
#if __riscv_xlen == 64
    *(volatile uint64_t *)(uintptr_t)(MTIME + 0x4000) = value;
#else
    /* 先屏蔽比较高半字，避免分两次写时产生临时过小的比较值。 */
    REG32(MTIME + 0x4004) = UINT32_MAX;
    REG32(MTIME + 0x4000) = (uint32_t)value;
    REG32(MTIME + 0x4004) = (uint32_t)(value >> 32);
#endif
}
static uint64_t read_time(void)
{
#if __riscv_xlen == 64
    return *(volatile uint64_t *)(uintptr_t)(MTIME + 0xbff8);
#else
    uint32_t high, low, check;
    do {
        high = REG32(MTIME + 0xbffc);
        low = REG32(MTIME + 0xbff8);
        check = REG32(MTIME + 0xbffc);
    } while (high != check);
    return ((uint64_t)high << 32) | low;
#endif
}

/* GCC 保存实际使用的寄存器并生成 MRET；不在普通 C 函数末尾手写 MRET。 */
void __attribute__((interrupt("machine"), aligned(4))) soc_trap(void)
{
    unsigned long cause, epc, tval;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile("csrr %0, mepc" : "=r"(epc));
    __asm__ volatile("csrr %0, mtval" : "=r"(tval));
    if (cause >> (__riscv_xlen - 1)) {
        unsigned int code = (unsigned int)(cause & 15);
        seen[code]++;
        if (code == 3) {
            REG32(MTIME) = 0;
        } else if (code == 7) {
            set_compare(UINT64_MAX);
        } else if (code == 11) {
            unsigned int id = REG32(IRQ + 0x200004);
            if (id == 1 || id == 2)
                received[id - 1] = REG32(UART + (id - 1) * 4096 + 4);
            else if (id == 3)
                REG32(TIMER + 12) = 1;
            else if (id >= 4 && id <= 6)
                REG32(GPIO + (id - 4) * 4096 + 24) = UINT32_MAX;
            else
                failure = 80;
            if (id >= 1 && id <= 6) external_seen[id]++;
            REG32(IRQ + 0x200004) = id;
        } else {
            failure = 81;
        }
    } else {
        if (cause != expected_cause || tval != expected_tval) failure = 82;
        fault_count++;
        epc += 4;
        __asm__ volatile("csrw mepc, %0" :: "r"(epc));
    }
}
static int wait_event(volatile unsigned long *value)
{
    for (unsigned int i = 0; i < 20000; i++)
        if (*value) return 1;
    return 0;
}
int main(void)
{
    if (REG32(INFO) != __riscv_xlen || REG32(INFO + 8) != 65536 || REG32(INFO + 12) != 65536)
        return 1;
    for (unsigned int g = 0; g < 3; g++) {
        REG32(GPIO + g * 4096 + 4) = 0;
        REG32(GPIO + g * 4096 + 8) = UINT32_MAX;
        if (REG32(GPIO + g * 4096 + 8) != UINT32_MAX) return 2;
    }

    expected_cause = 5;
    expected_tval = GPIO + 32;
    __asm__ volatile("lw zero, 0(%0)" :: "r"((uintptr_t)(GPIO + 32)) : "memory");
    expected_cause = 7;
    expected_tval = GPIO;
    __asm__ volatile("sw zero, 0(%0)" :: "r"((uintptr_t)GPIO) : "memory");
#if __riscv_xlen == 64
    expected_cause = 5;
    expected_tval = UART;
    __asm__ volatile("ld zero, 0(%0)" :: "r"((uintptr_t)UART) : "memory");
    if (fault_count != 3) return 3;
#else
    if (fault_count != 2) return 3;
#endif
    if (failure) return (int)failure;
    expected_cause = 0;

    for (unsigned int i = 1; i <= 6; i++) REG32(IRQ + i * 4) = 1;
    REG32(IRQ + 0x2000) = 0x7e;
    REG32(IRQ + 0x200000) = 0;
    __asm__ volatile("csrw mie, %0" :: "r"(0x888UL));
    __asm__ volatile("csrsi mstatus, 8");

    REG32(MTIME) = 1;
    if (!wait_event(&seen[3])) return 4;
    set_compare(read_time() + 1000);
    if (!wait_event(&seen[7])) return 5;

    for (unsigned int u = 0; u < 2; u++) {
        REG32(UART + u * 4096 + 12) = 8;
        REG32(UART + u * 4096 + 16) = 1;
        REG32(UART + u * 4096) = 0x61 + u;
        if (!wait_event(&external_seen[u + 1]) || received[u] != 0x61 + u) return 6 + (int)u;
    }

    REG32(TIMER) = 0;
    REG32(TIMER + 4) = 1000;
    REG32(TIMER + 8) = 5;
    if (!wait_event(&external_seen[3])) return 8;

    for (unsigned int g = 0; g < 3; g++) {
        REG32(GPIO + g * 4096 + 12) = 1;
        REG32(GPIO + g * 4096 + 16) = 1;
        REG32(GPIO + g * 4096 + 4) = 1;
        if (!wait_event(&external_seen[g + 4])) return 9 + (int)g;
    }
    __asm__ volatile("csrci mstatus, 8");
    return (int)failure;
}
