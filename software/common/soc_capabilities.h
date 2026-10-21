/* SPDX-License-Identifier: Apache-2.0 */
#ifndef HGB_SOC_CAPABILITIES_H
#define HGB_SOC_CAPABILITIES_H

#include <stdint.h>

/* 目标编号属于发现 ABI；设备是否存在只读取硬件，不在 BSP 复制 profile 位图。 */
enum hgb_soc_target {
    HGB_TARGET_ERROR = 0, HGB_TARGET_ROM, HGB_TARGET_ITCM, HGB_TARGET_DTCM,
    HGB_TARGET_MTIME, HGB_TARGET_IRQ, HGB_TARGET_UART0, HGB_TARGET_UART1,
    HGB_TARGET_TIMER, HGB_TARGET_GPIO0, HGB_TARGET_GPIO1, HGB_TARGET_GPIO2,
    HGB_TARGET_DMA, HGB_TARGET_SOC, HGB_TARGET_DDR, HGB_TARGET_COUNT
};
#define HGB_SOC_PRESENCE_OFFSET 0x038u
#define HGB_SOC_DISCOVERY_OFFSET 0x03cu
#define HGB_SOC_DISCOVERY_ABI 1u

static inline int hgb_soc_has(uint32_t presence, unsigned target)
{
    return target < HGB_TARGET_COUNT && (presence & (1u << target)) != 0;
}

static inline int hgb_soc_discovery_valid(uint32_t presence, uint32_t discovery)
{
    return (discovery >> 16) == HGB_SOC_DISCOVERY_ABI &&
           (discovery & 0xff00u) == 0 && (discovery & 0xffu) <= 1u &&
           (presence >> HGB_TARGET_COUNT) == 0;
}

static inline int hgb_soc_irq_present(uint32_t presence, unsigned id)
{
    if (id == 1 || id == 2) return hgb_soc_has(presence, HGB_TARGET_UART0 + id - 1);
    if (id == 3) return hgb_soc_has(presence, HGB_TARGET_TIMER);
    if (id >= 4 && id <= 6) return hgb_soc_has(presence, HGB_TARGET_GPIO0 + id - 4);
    if (id == 7) return hgb_soc_has(presence, HGB_TARGET_DMA);
    return 0;
}
#endif
