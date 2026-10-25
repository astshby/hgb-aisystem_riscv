/* SPDX-License-Identifier: Apache-2.0 */
#ifndef HGB_SOC_CLOCKS_H
#define HGB_SOC_CLOCKS_H
#include <stdint.h>
#include "soc_capabilities.h"

#define HGB_SOC_LEGACY_CLOCK_OFFSET 0x004u
#define HGB_SOC_CLOCK_INFO_OFFSET 0x050u
#define HGB_SOC_CORE_CLOCK_OFFSET 0x054u
#define HGB_SOC_SYS_CLOCK_OFFSET 0x058u
#define HGB_SOC_DDR_CLOCK_OFFSET 0x05cu
#define HGB_SOC_PERIPH_CLOCK_OFFSET 0x060u
#define HGB_SOC_TIMER_CLOCK_OFFSET 0x064u
#define HGB_SOC_CLOCK_INFO_V1 0x0001001fu

struct hgb_soc_clocks {
    uint32_t core_hz, sys_hz, ddr_hz, periph_hz, timer_hz;
};

#ifndef HGB_SOC_CLOCK_READ32
#define HGB_SOC_CLOCK_READ32(address) (*(volatile uint32_t *)(uintptr_t)(address))
#endif

/* 发现位未置位时绝不探测扩展窗口，兼容原硬件的未映射地址异常。 */
static inline int hgb_soc_read_clocks(uintptr_t base, uint32_t discovery,
                                     struct hgb_soc_clocks *clocks)
{
    uint32_t legacy = HGB_SOC_CLOCK_READ32(base + HGB_SOC_LEGACY_CLOCK_OFFSET);
    if (!(discovery & HGB_SOC_CLOCK_INFO_PRESENT)) {
        clocks->core_hz = clocks->sys_hz = clocks->ddr_hz = legacy;
        clocks->periph_hz = clocks->timer_hz = legacy;
        return legacy ? 0 : -1;
    }
    if (HGB_SOC_CLOCK_READ32(base + HGB_SOC_CLOCK_INFO_OFFSET) != HGB_SOC_CLOCK_INFO_V1)
        return -1;
    clocks->core_hz = HGB_SOC_CLOCK_READ32(base + HGB_SOC_CORE_CLOCK_OFFSET);
    clocks->sys_hz = HGB_SOC_CLOCK_READ32(base + HGB_SOC_SYS_CLOCK_OFFSET);
    clocks->ddr_hz = HGB_SOC_CLOCK_READ32(base + HGB_SOC_DDR_CLOCK_OFFSET);
    clocks->periph_hz = HGB_SOC_CLOCK_READ32(base + HGB_SOC_PERIPH_CLOCK_OFFSET);
    clocks->timer_hz = HGB_SOC_CLOCK_READ32(base + HGB_SOC_TIMER_CLOCK_OFFSET);
    return clocks->core_hz && clocks->sys_hz && clocks->ddr_hz && clocks->periph_hz &&
           clocks->timer_hz == clocks->periph_hz ? 0 : -1;
}

/* UART 每 divisor 个外设时钟发送一位；保留原软件的向下取整策略。 */
static inline uint32_t hgb_soc_uart_divisor(uint32_t periph_hz, uint32_t baud)
{
    return baud && baud <= periph_hz / 4u ? periph_hz / baud : 0;
}

/* SPI 每 divider 个系统时钟翻转 SCK；向上取整以不超过请求的最高 SCK。 */
static inline uint32_t hgb_soc_spi_divider(uint32_t sys_hz, uint32_t maximum_sck_hz)
{
    if (!sys_hz || !maximum_sck_hz) return 0;
    uint64_t denominator = (uint64_t)maximum_sck_hz * 2u;
    uint64_t divider = ((uint64_t)sys_hz + denominator - 1u) / denominator;
    return divider && divider <= 65535u ? (uint32_t)divider : 0;
}
#endif
