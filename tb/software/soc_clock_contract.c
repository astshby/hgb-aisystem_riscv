// Module: soc_clock_contract_software_test
// Description: CPU-visible clock discovery, timer/cycle ratio and UART/SPI divider contract.
#include <stdint.h>
#include "../../software/common/soc_clocks.h"
#ifndef EXPECT_LEGACY_CLOCK_HZ
#define EXPECT_LEGACY_CLOCK_HZ 100000000u
#endif
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
static uint64_t cycles(void)
{
#if __riscv_xlen == 64
    uint64_t value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
#else
    uint32_t hi, lo, again;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(again));
    } while (hi != again);
    return ((uint64_t)hi << 32) | lo;
#endif
}
static uint64_t timer(void)
{
    uint32_t hi, lo, again;
    do {
        hi = REG(0x0200bffc); lo = REG(0x0200bff8); again = REG(0x0200bffc);
    } while (hi != again);
    return ((uint64_t)hi << 32) | lo;
}
int main(void)
{
    struct hgb_soc_clocks clocks;
    uint32_t presence = REG(0x10040038), discovery = REG(0x1004003c);
    if (!hgb_soc_discovery_valid(presence, discovery)) return 70;
    if (!(discovery & HGB_SOC_CLOCK_INFO_PRESENT)) return 71;
    if (hgb_soc_read_clocks(0x10040000u, discovery, &clocks)) return 72;
    if (REG(0x10040004) != EXPECT_LEGACY_CLOCK_HZ) return 73; /* 旧字段保持独立 ABI。 */
    uint32_t divisor = hgb_soc_uart_divisor(clocks.periph_hz, 1000000u);
    if (!divisor || hgb_soc_uart_divisor(clocks.periph_hz, clocks.periph_hz)) return 74;
    REG(0x1000000c) = divisor;
    if (REG(0x1000000c) != divisor) return 75;
    uint32_t spi = hgb_soc_spi_divider(clocks.sys_hz, 12000000u);
    if (!spi || (uint64_t)spi * 24000000u < clocks.sys_hz) return 76;
    /* 配置邮箱由 sys 域应答；此测试不发起 Flash 读取。 */
    REG(0x1005000c) = spi;
    unsigned attempts;
    for (attempts = 0; attempts < 10000; ++attempts)
        if (!(REG(0x10050010) & 1)) break;
    if (attempts == 10000 || REG(0x1005000c) != spi) return 77;
    uint64_t c0 = cycles(), t0 = timer(), t1;
    do { t1 = timer(); } while (t1 - t0 < clocks.timer_hz / 1000u);
    uint64_t dc = cycles() - c0, dt = t1 - t0;
    uint64_t expected = dt * clocks.core_hz / clocks.timer_hz;
    /* 1ms 窗口允许 MMIO/CSR 采样偏差；错误地把 core 当 timer 会远超容差。 */
    if (dc < expected * 95u / 100u || dc > expected * 105u / 100u + 1000u) return 78;
    return 0;
}
