// Module: p2_coremark_port
// Description: DDR CoreMark placement, deterministic cache preparation and real DMA/timer load.
#include "coremark.h"
#include "benchmark_runtime.h"
#include <stdint.h>
#include <stddef.h>

#define CONTROL __attribute__((section(".p2_control")))
#define TCM_FN __attribute__((section(".text.p2_control"), noinline))
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#ifndef DMA_SOURCE
#define DMA_SOURCE 0x80020000u
#endif
#ifndef DMA_DESTINATION
#define DMA_DESTINATION 0x80030000u
#endif
#define DMA_BYTES 16384u
#define LEGACY_TIMER_TICKS 2048u
#ifndef P2_TIMER_MODE
#define P2_TIMER_MODE 0
#endif
#ifndef P2_INTERVAL_PS
#define P2_INTERVAL_PS 100000000u
#endif
#ifndef P2_WARM
#define P2_WARM 0
#endif
#ifndef P2_BACKGROUND
#define P2_BACKGROUND 0
#endif
#ifndef P2_NPU
#define P2_NPU 0
#endif
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
volatile uint32_t p2_roi_state __attribute__((section(".p2_roi"))) = 0;
// 仅专用 TB 在复位释放前写入；普通 M1 镜像不使用或覆盖此窗口。
volatile uint32_t p2_platform[4] __attribute__((section(".p2_platform"))) = {0, 0, 0, 0};
static CORETIMETYPE start_cycle CONTROL;
static CORETIMETYPE stop_cycle CONTROL;
static core_results *work CONTROL;
static core_results saved_work CONTROL;
static unsigned char saved_block[TOTAL_DATA_SIZE] CONTROL;
static uintptr_t saved_mtvec CONTROL;
static uintptr_t saved_mie CONTROL;
static uintptr_t saved_mstatus CONTROL;
static uintptr_t saved_mscratch CONTROL;
extern void p2_timer_entry(void);
extern unsigned char __interrupt_stack_top[];
static volatile uint32_t irq_count CONTROL;
static uint32_t irq_begin CONTROL;
static uint32_t irq_end CONTROL;
static volatile uint32_t dma_completed CONTROL;
static volatile uint32_t dma_bytes CONTROL;
static volatile uint32_t errors CONTROL;
static volatile uint32_t background_active CONTROL;
static uint32_t cold_prepared CONTROL;
// 配置只改 DTCM 数据镜像，三种场景使用相同的 DDR 指令布局。
static volatile uint32_t warm_mode CONTROL = P2_WARM;
static volatile uint32_t background_mode CONTROL = P2_BACKGROUND;
static volatile uint32_t timer_mode CONTROL = P2_TIMER_MODE;
static volatile uint32_t requested_interval_ps CONTROL = P2_INTERVAL_PS;
static uint32_t timer_ticks CONTROL;
static uint32_t actual_interval_ps CONTROL;
static uint64_t timer_deadline CONTROL;
static volatile uint32_t late_events CONTROL;
static volatile uint32_t late_max_ticks CONTROL;
static volatile uint64_t late_total_ticks CONTROL;
static volatile uint32_t skipped_periods CONTROL;

static inline __attribute__((always_inline)) CORETIMETYPE read_cycle(void)
{
#if __riscv_xlen == 32
    uint32_t high, low, again;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(high));
        __asm__ volatile("csrr %0, mcycle" : "=r"(low));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(again));
    } while (high != again);
    return ((uint64_t)high << 32) | low;
#else
    uint64_t value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
#endif
}

static TCM_FN void copy_bytes(void *dst, const void *src, unsigned bytes)
{
    volatile unsigned char *out = dst;
    const volatile unsigned char *in = src;
    for (unsigned i = 0; i < bytes; i++) out[i] = in[i];
}

static TCM_FN void fail(unsigned code)
{
    extern volatile unsigned int tohost;
    tohost = (code << 1) | 1;
    for (;;) __asm__ volatile("nop");
}

static TCM_FN void maintain(unsigned command)
{
    REG(0x10040020) = command;
    for (unsigned i = 0; i < 100000; i++) {
        unsigned status = REG(0x10040030);
        if (!(status & 1)) {
            if (status & 0x1e) fail(80 + status);
            return;
        }
    }
    fail(81);
}

static TCM_FN uint64_t timer_now(void)
{
    uint32_t hi, lo, again;
    do {
        hi = REG(0x0200bffc); lo = REG(0x0200bff8); again = REG(0x0200bffc);
    } while (hi != again);
    return ((uint64_t)hi << 32) | lo;
}

static TCM_FN void timer_set(uint64_t value)
{
    REG(0x02004004) = ~0u;
    REG(0x02004000) = (uint32_t)value;
    REG(0x02004004) = (uint32_t)(value >> 32);
}

static TCM_FN void dma_start(void)
{
    REG(0x10030000) = DMA_SOURCE;
    REG(0x10030004) = DMA_DESTINATION;
    REG(0x10030008) = DMA_BYTES;
    REG(0x1003000c) = 1;
}

static TCM_FN void dma_collect(unsigned restart)
{
    unsigned status = REG(0x10030010);
    if (status & 6) {
        if ((status & 7) != 2 || REG(0x10030014) != DMA_BYTES) errors++;
        else { dma_completed++; dma_bytes += DMA_BYTES; }
        REG(0x10030010) = 6;
        if (restart && !errors) dma_start();
    }
}

#if P2_NPU
#include "npu_background.h"
#endif

void TCM_FN p2_timer_interrupt(void)
{
    uintptr_t cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause != (((uintptr_t)1 << (__riscv_xlen - 1)) | 7)) fail(82);
    uint64_t entered = timer_now();
    uint64_t lateness = entered > timer_deadline ? entered - timer_deadline : 0;
    irq_count++;
    if (lateness) late_events++;
    late_total_ticks += lateness;
    if (lateness > late_max_ticks) late_max_ticks = (uint32_t)lateness;
    dma_collect(background_active);
#if P2_NPU
    npu_collect(background_active);
#endif
    if (timer_mode == 1) {
        // 显式旧对照：处理完成后按固定 peripheral tick 相对重设。
        timer_deadline = timer_now() + LEGACY_TIMER_TICKS;
    } else {
        // 固定实际周期：延续原绝对 deadline；错过的周期单独计数，不累积处理漂移。
        uint64_t now = timer_now();
        timer_deadline += timer_ticks;
        while (timer_deadline <= now) {
            timer_deadline += timer_ticks;
            skipped_periods++;
        }
    }
    timer_set(timer_deadline);
}

void TCM_FN p2_start_time(void)
{
    if (warm_mode) {
        // 只预热原版 iterate；恢复全部输入/结果，计时运行仍从相同算法状态开始。
        copy_bytes(&saved_work, work, sizeof(*work));
        copy_bytes(saved_block, work->memblock[0], TOTAL_DATA_SIZE);
        work->iterations = 1;
        iterate(work);
        copy_bytes(saved_work.memblock[0], saved_block, TOTAL_DATA_SIZE);
        copy_bytes(work, &saved_work, sizeof(*work));
    } else {
        // 当前栈已切至 DTCM，flush 后没有 DDR 数据访问；FENCE.I 清空取指 Cache。
        maintain(3);
        __asm__ volatile(".word 0x0000100f" ::: "memory");
        cold_prepared = 1;
    }
    if (background_mode) {
        __asm__ volatile("csrr %0, mtvec" : "=r"(saved_mtvec));
        __asm__ volatile("csrr %0, mie" : "=r"(saved_mie));
        __asm__ volatile("csrr %0, mstatus" : "=r"(saved_mstatus));
        __asm__ volatile("csrr %0, mscratch" : "=r"(saved_mscratch));
        __asm__ volatile("csrw mscratch, %0" :: "r"((uintptr_t)__interrupt_stack_top));
        __asm__ volatile("csrw mtvec, %0" :: "r"((uintptr_t)p2_timer_entry));
        background_active = 1;
        dma_start();
        timer_deadline = timer_now() + timer_ticks;
        timer_set(timer_deadline);
        __asm__ volatile("csrw mie, %0" :: "r"((uintptr_t)128));
    }
#if P2_NPU
    npu_start();
#endif
    p2_roi_state = 1;
    irq_begin = irq_count;
    start_cycle = read_cycle();
    if (background_mode) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
}

void TCM_FN p2_stop_time(void)
{
    if (background_mode) __asm__ volatile("csrci mstatus, 8" ::: "memory");
    stop_cycle = read_cycle();
    irq_end = irq_count;
    p2_roi_state = 2;
#if P2_NPU
    npu_roi_tasks = npu_tasks;
    npu_roi_vectors = npu_vectors;
    for (unsigned i = 0; npu_running && i < 10000; i++) npu_collect(0);
    if (npu_running || !npu_roi_tasks || !npu_roi_vectors) fail(95);
#endif
    if (background_mode) {
        background_active = 0;
        timer_set(~(uint64_t)0);
        for (unsigned i = 0; (REG(0x10030010) & 1) && i < 100000; i++) {
            if (i == 99999) fail(83);
        }
        dma_collect(0);
        // 回收 DMA 目的区所有权后验证；维护与比较均位于计时区之外。
        maintain(3);
        for (unsigned i = 0; i < DMA_BYTES / 4; i++) {
            uint32_t got = REG(DMA_DESTINATION + 4*i);
            if (got != (0x5a780000u ^ (i * 0x1021u))) errors++;
        }
        __asm__ volatile("csrw mscratch, %0" :: "r"(saved_mscratch));
        __asm__ volatile("csrw mtvec, %0" :: "r"(saved_mtvec));
        __asm__ volatile("csrw mie, %0" :: "r"(saved_mie));
        __asm__ volatile("csrw mstatus, %0" :: "r"(saved_mstatus) : "memory");
        if (irq_end == irq_begin || !dma_completed || errors) fail(84);
    }
}

CORE_TICKS get_time(void) { return stop_cycle - start_cycle; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / 1000000ull); }

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    work = (core_results *)((unsigned char *)portable - offsetof(core_results, port));
    portable->portable_id = 1;
#if P2_NPU
    npu_prepare();
#endif
    if (p2_platform[0] != 0x50324346u || p2_platform[1] != 1 ||
        p2_platform[2] == 0 || p2_platform[2] > 1000000u || p2_platform[3] > 4) fail(86);
    if (timer_mode > 1 || requested_interval_ps == 0) fail(87);
    timer_ticks = timer_mode == 1 ? LEGACY_TIMER_TICKS :
        (uint32_t)(((uint64_t)requested_interval_ps + p2_platform[2] - 1) / p2_platform[2]);
    actual_interval_ps = timer_ticks * p2_platform[2];
    if (sizeof(ee_ptr_int) != sizeof(void *) || sizeof(ee_u32) != 4) fail(85);
    if (background_mode) {
        for (unsigned i = 0; i < DMA_BYTES / 4; i++)
            REG(DMA_SOURCE + 4*i) = 0x5a780000u ^ (i * 0x1021u);
        maintain(3);
    }
}

void portable_fini(core_portable *portable)
{
    ee_printf("P2_PLATFORM_SW magic=%lu version=%lu periph_period_ps=%lu clock=%lu\n",
              p2_platform[0], p2_platform[1], p2_platform[2], p2_platform[3]);
    ee_printf("P2_TIMER mode=%lu requested_ps=%lu interval_ticks=%lu actual_ps=%lu quantum_ps=%lu late_events=%lu late_max_ticks=%lu skipped=%lu\n",
              timer_mode, requested_interval_ps, timer_ticks, actual_interval_ps,
              timer_mode == 1 ? 0u : actual_interval_ps - requested_interval_ps,
              late_events, late_max_ticks, skipped_periods);
    ee_printf("P2_TIMER_TOTAL late_hi=%lu late_lo=%lu\n",
              (uint32_t)(late_total_ticks >> 32), (uint32_t)late_total_ticks);
    ee_printf("P2_CONFIG warm=%lu background=%lu cold_prepared=%lu iterations=%lu\n",
              warm_mode, background_mode, cold_prepared, (ee_u32)ITERATIONS);
    ee_printf("P2_BACKGROUND irq=%lu dma_completed=%lu dma_bytes=%lu errors=%lu\n",
              irq_count, dma_completed, dma_bytes, errors);
    ee_printf("P2_IRQ start=%lu stop=%lu roi=%lu\n", irq_begin, irq_end, irq_end - irq_begin);
    ee_printf("P2_TICKS high=%lu low=%lu\n", (ee_u32)(get_time() >> 32), (ee_u32)get_time());
    portable->portable_id = 0;
#if P2_NPU
    ee_printf("NPU_BACKGROUND tasks=%lu vectors=%lu roi_tasks=%lu roi_vectors=%lu errors=%lu\n",
        npu_tasks, npu_vectors, npu_roi_tasks, npu_roi_vectors, errors);
#endif
}
