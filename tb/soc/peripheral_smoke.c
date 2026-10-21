/* Module: peripheral_smoke
 * Description: Bare-metal MMIO, synchronous fault, and machine-interrupt integration test.
 */
#include <stdint.h>
#include "../../software/common/soc_capabilities.h"
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define MTIME 0x02000000u
#define IRQ 0x0c000000u
#define UART 0x10000000u
#define TIMER 0x10010000u
#define GPIO 0x10020000u
#define INFO 0x10040000u

static volatile unsigned long seen[16], external_seen[7], received[2];
static volatile unsigned long fault_count, expected_cause, expected_tval, failure;
static uint32_t presence;
extern volatile unsigned char sim_console;

static void report(const char *text)
{
    while (*text) sim_console = (unsigned char)*text++;
}
static void report_number(unsigned value, unsigned radix)
{
    char digits[11];
    unsigned count = 0;
    do {
        digits[count++] = "0123456789abcdef"[value % radix];
        value /= radix;
    } while (value);
    while (count) sim_console = (unsigned char)digits[--count];
}

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
            /* 未发现的 IRQ 源不得触发对应设备 MMIO，即使 claim 值异常。 */
            if (!hgb_soc_irq_present(presence, id))
                failure = 83;
            else if (id == 1 || id == 2)
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

static int check_missing_window(uintptr_t address)
{
    unsigned long before = fault_count;
    /* 每个缺失窗口都验证读、写异常；不把不存在设备的零返回当成成功。 */
    expected_cause = 5;
    expected_tval = address;
    __asm__ volatile("lw zero, 0(%0)" :: "r"(address) : "memory");
    if (failure || fault_count != before + 1) return 0;
    expected_cause = 7;
    __asm__ volatile("sw zero, 0(%0)" :: "r"(address) : "memory");
    return !failure && fault_count == before + 2;
}

int main(void)
{
    unsigned uart_count = 0, gpio_count = 0, timer_count = 0, missing_count = 0;
    presence = REG32(INFO + HGB_SOC_PRESENCE_OFFSET);
    uint32_t discovery = REG32(INFO + HGB_SOC_DISCOVERY_OFFSET);
    if (!hgb_soc_discovery_valid(presence, discovery)) return 84;
    const unsigned required[] = {HGB_TARGET_MTIME, HGB_TARGET_IRQ, HGB_TARGET_UART0,
                                HGB_TARGET_GPIO0, HGB_TARGET_SOC};
    for (unsigned n = 0; n < sizeof(required) / sizeof(required[0]); n++)
        if (!hgb_soc_has(presence, required[n])) return 85;
    if (REG32(INFO) != __riscv_xlen || REG32(INFO + 8) != 65536 || REG32(INFO + 12) != 65536)
        return 1;
    for (unsigned int g = 0; g < 3; g++) {
        if (!hgb_soc_has(presence, HGB_TARGET_GPIO0 + g)) continue;
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

    for (unsigned u = 0; u < 2; u++) {
        if (hgb_soc_has(presence, HGB_TARGET_UART0 + u)) continue;
        if (!check_missing_window(UART + u * 4096)) return 86;
        missing_count++;
    }
    for (unsigned g = 0; g < 3; g++) {
        if (hgb_soc_has(presence, HGB_TARGET_GPIO0 + g)) continue;
        if (!check_missing_window(GPIO + g * 4096)) return 87;
        missing_count++;
    }
    if (!hgb_soc_has(presence, HGB_TARGET_TIMER)) {
        if (!check_missing_window(TIMER)) return 88;
        missing_count++;
    }
    expected_cause = 0;

    unsigned irq_mask = 0;
    for (unsigned int i = 1; i <= 6; i++) {
        if (!hgb_soc_irq_present(presence, i)) continue;
        REG32(IRQ + i * 4) = 1;
        irq_mask |= 1u << i;
    }
    REG32(IRQ + 0x2000) = irq_mask;
    REG32(IRQ + 0x200000) = 0;
    __asm__ volatile("csrw mie, %0" :: "r"(0x888UL));
    __asm__ volatile("csrsi mstatus, 8");

    REG32(MTIME) = 1;
    if (!wait_event(&seen[3])) return 4;
    set_compare(read_time() + 1000);
    if (!wait_event(&seen[7])) return 5;

    for (unsigned int u = 0; u < 2; u++) {
        if (!hgb_soc_has(presence, HGB_TARGET_UART0 + u)) continue;
        uart_count++;
        REG32(UART + u * 4096 + 12) = 8;
        REG32(UART + u * 4096 + 16) = 1;
        REG32(UART + u * 4096) = 0x61 + u;
        if (!wait_event(&external_seen[u + 1]) || received[u] != 0x61 + u) return 6 + (int)u;
    }

    if (hgb_soc_has(presence, HGB_TARGET_TIMER)) {
        REG32(TIMER) = 0;
        REG32(TIMER + 4) = 1000;
        REG32(TIMER + 8) = 5;
        if (!wait_event(&external_seen[3])) return 8;
        timer_count++;
    }

    for (unsigned int g = 0; g < 3; g++) {
        if (!hgb_soc_has(presence, HGB_TARGET_GPIO0 + g)) continue;
        gpio_count++;
        REG32(GPIO + g * 4096 + 12) = 1;
        REG32(GPIO + g * 4096 + 16) = 1;
        REG32(GPIO + g * 4096 + 4) = 1;
        if (!wait_event(&external_seen[g + 4])) return 9 + (int)g;
    }
    __asm__ volatile("csrci mstatus, 8");
    if (failure) return (int)failure;
    report("PASS peripheral capabilities ABI="); report_number(discovery >> 16, 10);
    report(" profile="); report_number(discovery & 0xffu, 10);
    report(" presence=0x"); report_number(presence, 16);
    report(" UART_count="); report_number(uart_count, 10);
    report(" GPIO_count="); report_number(gpio_count, 10);
    report(" TIMER_count="); report_number(timer_count, 10);
    report(" missing_windows="); report_number(missing_count, 10);
    report(" faults="); report_number((unsigned)fault_count, 10);
    report("\n");
    return (int)failure;
}
