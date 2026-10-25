/* SPDX-License-Identifier: Apache-2.0 */
#include "board.h"
extern char __hot_start[], __hot_end[], __hot_load[];
extern char __heap_start[], __heap_end[];
extern void hgb_trap(void);
volatile unsigned int tohost __attribute__((section(".tohost"), aligned(8)));
volatile unsigned char sim_console __attribute__((section(".sim_console")));
volatile rt_uint32_t hgb_irq_count[8], hgb_tick_irqs, hgb_dma_bytes;
volatile rt_ubase_t hgb_fault_cause, hgb_fault_pc, hgb_fault_value;
rt_uint32_t hgb_soc_presence, hgb_soc_profile;
struct hgb_soc_clocks hgb_clocks;
static rt_uint64_t next_tick;
static rt_uint32_t tick_cycles;

/* 编译器生成的结构清零/拷贝可引用这两个 freestanding ABI 符号。 */
void *memset(void *dst, int value, __SIZE_TYPE__ count)
{
    return rt_memset(dst, value, count);
}
void *memcpy(void *dst, const void *src, __SIZE_TYPE__ count)
{
    return rt_memcpy(dst, src, count);
}

void hgb_finish(unsigned code)
{
    __asm__ volatile("csrci mstatus, 8" ::: "memory");
    tohost = (code << 1) | 1u;
    for (;;) __asm__ volatile("nop");
}

rt_uint64_t hgb_mtime(void)
{
    rt_uint32_t hi, lo, check;
    do {
        hi = REG32(0x0200bffc);
        lo = REG32(0x0200bff8);
        check = REG32(0x0200bffc);
    } while (hi != check);
    return ((rt_uint64_t)hi << 32) | lo;
}

static void set_compare(rt_uint64_t value)
{
    REG32(0x02004004) = 0xffffffffu;
    REG32(0x02004000) = (rt_uint32_t)value;
    REG32(0x02004004) = (rt_uint32_t)(value >> 32);
}

/* 调用方在 Flash 配置空闲时写入该除数；本接口不发出读写/擦除命令。 */
rt_uint32_t hgb_spi_divider(rt_uint32_t maximum_sck_hz)
{
    return hgb_soc_spi_divider(hgb_clocks.sys_hz, maximum_sck_hz);
}

rt_err_t hgb_irq_enable(unsigned id)
{
    /* 拒绝不存在的源，不能先写 priority/enable 再报告错误。 */
    if (!hgb_soc_irq_present(hgb_soc_presence, id)) return -RT_EINVAL;
    rt_base_t level = rt_hw_interrupt_disable();
    REG32(IRQ_BASE + 4 * id) = 1;
    REG32(IRQ_BASE + 0x2000) |= 1u << id;
    rt_hw_interrupt_enable(level);
    return RT_EOK;
}

HOT_CODE void hgb_dispatch(rt_ubase_t cause, rt_ubase_t *frame)
{
    rt_ubase_t interrupt = (rt_ubase_t)1 << (__riscv_xlen - 1);
    if (!(cause & interrupt)) {
        hgb_fault_cause = cause;
        hgb_fault_pc = frame[0];
        __asm__ volatile("csrr %0, mtval" : "=r"(hgb_fault_value));
        hgb_finish(128 + (unsigned)cause);
    }
    switch (cause & ~interrupt) {
    case 7:
        hgb_tick_irqs++;
        /* 延迟服务时补齐 tick，使用绝对比较值避免累计漂移。 */
        do {
            next_tick += tick_cycles;
            rt_tick_increase();
        } while (next_tick <= hgb_mtime());
        set_compare(next_tick);
        break;
    case 11: {
        unsigned id = REG32(IRQ_BASE + 0x200004);
        if (id == 0) break;
        if (!hgb_soc_irq_present(hgb_soc_presence, id)) hgb_finish(140);
        hgb_irq_count[id]++;
        if (id <= 2) hgb_uart_irq(id - 1);
        else if (id >= 4 && id <= 6) hgb_gpio_irq(id - 4);
        else hgb_finish(141);
        REG32(IRQ_BASE + 0x200004) = id;
        break;
    }
    case 3: REG32(0x02000000) = 0; break;
    default: hgb_finish(142);
    }
}

static void load_hot_code(void)
{
    unsigned length = (unsigned)(__hot_end - __hot_start);
    /* 两端均为不缓存的 TCM；不能在此调用尚未装载的关中断函数。 */
    REG32(DMA_BASE + 0x10) = 6;
    REG32(DMA_BASE) = (rt_uint32_t)(rt_ubase_t)__hot_load;
    REG32(DMA_BASE + 4) = (rt_uint32_t)(rt_ubase_t)__hot_start;
    REG32(DMA_BASE + 8) = length;
    REG32(DMA_BASE + 12) = 1;
    rt_uint64_t deadline = hgb_mtime() + hgb_clocks.timer_hz;
    while (REG32(DMA_BASE + 0x10) & 1) {
        if (hgb_mtime() > deadline) hgb_finish(120);
    }
    hgb_dma_bytes = REG32(DMA_BASE + 0x14);
    if (REG32(DMA_BASE + 0x10) != 2 || hgb_dma_bytes != length)
        hgb_finish(121);
    for (unsigned i = 0; i < length; i++)
        if (((volatile unsigned char *)__hot_start)[i] !=
            ((volatile unsigned char *)__hot_load)[i]) hgb_finish(122);
    REG32(DMA_BASE + 0x10) = 6;
    __asm__ volatile("fence.i" ::: "memory");
    __asm__ volatile("csrw mtvec, %0" :: "r"(hgb_trap) : "memory");
}

void rt_hw_console_output(const char *s)
{
    /* 早期/故障输出不依赖设备框架；TX-ready 检查后仍须原子提交。 */
    while (*s) {
        rt_base_t level = rt_hw_interrupt_disable();
        if (REG32(UART_BASE(0) + 8) & 1) {
            REG32(UART_BASE(0)) = (unsigned char)*s++;
        }
        rt_hw_interrupt_enable(level);
    }
}

void rt_hw_cpu_shutdown(void) { hgb_finish(143); }
static void assert_failed(const char *ex, const char *func, rt_size_t line)
{
    (void)ex; (void)func; (void)line;
    hgb_finish(144);
}

void hgb_boot(void)
{
    /* 新 BSP 要求发现 ABI；不探测缺失窗口，也不假设旧硬件等同 full。 */
    hgb_soc_presence = REG32(INFO_BASE + HGB_SOC_PRESENCE_OFFSET);
    rt_uint32_t discovery = REG32(INFO_BASE + HGB_SOC_DISCOVERY_OFFSET);
    if (!hgb_soc_discovery_valid(hgb_soc_presence, discovery)) hgb_finish(149);
    hgb_soc_profile = discovery & 0xffu;
    if (hgb_soc_read_clocks(INFO_BASE, discovery, &hgb_clocks)) hgb_finish(161);
    const unsigned required[] = {HGB_TARGET_ITCM, HGB_TARGET_DTCM, HGB_TARGET_MTIME,
                                HGB_TARGET_IRQ, HGB_TARGET_UART0, HGB_TARGET_GPIO0, HGB_TARGET_DMA,
                                HGB_TARGET_SOC};
    for (unsigned n = 0; n < sizeof(required) / sizeof(required[0]); n++)
        if (!hgb_soc_has(hgb_soc_presence, required[n])) hgb_finish(150);
    load_hot_code();
    rt_assert_set_hook(assert_failed);
    rt_system_timer_init();
    rt_system_scheduler_init();
    rt_system_heap_init(__heap_start, __heap_end);
    hgb_drivers_init();
    hgb_app_init();
    rt_thread_idle_init();
    tick_cycles = hgb_clocks.timer_hz / RT_TICK_PER_SECOND;
    if (tick_cycles == 0) hgb_finish(145);
    next_tick = hgb_mtime() + tick_cycles;
    set_compare(next_tick);
    __asm__ volatile("csrw mie, %0" :: "r"(0x880) : "memory");
    rt_system_scheduler_start();
    hgb_finish(146);
}
