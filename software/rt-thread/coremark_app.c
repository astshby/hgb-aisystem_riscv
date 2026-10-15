/* SPDX-License-Identifier: Apache-2.0 */
/* Run CoreMark in an RT-Thread worker with a DDR-resident static workspace. */
#include "board.h"

extern int coremark_main(void);
extern int ee_printf(const char *format, ...);
extern volatile unsigned hgb_coremark_validated;
extern volatile unsigned hgb_coremark_crc_mask;
extern void hgb_coremark_report(void);
extern unsigned char static_memblk[2000];
extern char __ddr_start[], __ddr_end[];
static struct rt_thread coremark_thread;
static rt_uint8_t coremark_stack[8192] __attribute__((aligned(16)));

static unsigned workspace_hash(void)
{
    volatile unsigned char *workspace = static_memblk;
    unsigned hash = 0x13579bdfu;
    for (unsigned i = 0; i < sizeof(static_memblk); i++)
        hash = (hash << 5) ^ (hash >> 27) ^ workspace[i];
    return hash;
}

static void run_coremark(void)
{
#ifdef HGB_COREMARK_DDR
    const rt_ubase_t workspace_base = 0x80020000u;
    volatile rt_uint32_t *probe = (volatile rt_uint32_t *)0x8003f000u;
#else
    const rt_ubase_t workspace_base = 0x80000000u;
    volatile rt_uint32_t *probe = (volatile rt_uint32_t *)0x8000f000u;
#endif
    if ((rt_ubase_t)static_memblk < workspace_base ||
        (rt_ubase_t)static_memblk >= workspace_base + 0x10000u ||
        __ddr_end <= __ddr_start || hgb_dma_bytes == 0)
        hgb_finish(152);

    /* 强制经过 DDR 写回、失效和重新读取，不能只靠 D$ 命中证明外存可用。 */
    *probe = 0x5a35c69du;
    REG32(INFO_BASE + 0x20) = 3;
    while (REG32(INFO_BASE + 0x30) & 1) { }
    if (REG32(INFO_BASE + 0x30) & 6) hgb_finish(153);
    if (*probe != 0x5a35c69du) hgb_finish(154);

    ee_printf("RT-Thread CoreMark DDR workspace=0x%08x\n", (unsigned)(rt_ubase_t)static_memblk);
    if (coremark_main() != 0 || hgb_coremark_crc_mask != 7u) hgb_finish(155);
    unsigned before = workspace_hash();
    REG32(INFO_BASE + 0x20) = 3;
    while (REG32(INFO_BASE + 0x30) & 1) { }
    if (REG32(INFO_BASE + 0x30) & 6) hgb_finish(159);
    if (workspace_hash() != before) hgb_finish(160);
#if ITERATIONS == 0
    if (!hgb_coremark_validated) hgb_finish(158);
    ee_printf("PASS rt-thread CoreMark DDR valid-duration CRC\n");
#else
    ee_printf("PASS rt-thread CoreMark DDR functional CRC (short run)\n");
#endif
    hgb_coremark_report();
}

static void coremark_entry(void *arg)
{
    (void)arg;
#ifdef HGB_COREMARK_RESIDENT
    unsigned run = 0;
#endif
    for (;;) {
        run_coremark();
#ifdef HGB_COREMARK_RESIDENT
        run++;
        ee_printf("COREMARK READY run=%u r=repeat\n", run);
        /* 当前 console 未打开 RX IRQ，重复命令直接轮询 UART0；等待时保持调度。 */
        for (;;) {
            unsigned status = REG32(UART_BASE(0) + 8);
            if (status & 12u) {
                REG32(UART_BASE(0) + 8) = status & 12u;
                ee_printf("COREMARK RX error; retry command\n");
            }
            if ((status & 2u) && (REG32(UART_BASE(0) + 4) & 255u) == 'r') break;
            rt_thread_mdelay(1);
        }
#else
        hgb_finish(0);
#endif
    }
}

void hgb_app_init(void)
{
    REG32(UART_BASE(0) + 12) = REG32(INFO_BASE + 4) / HGB_COREMARK_BAUD;
    if (rt_thread_init(&coremark_thread, "coremark", coremark_entry, RT_NULL,
                       coremark_stack, sizeof(coremark_stack), 8, 2) != RT_EOK)
        hgb_finish(156);
    if (rt_thread_startup(&coremark_thread) != RT_EOK) hgb_finish(157);
}
