// Module: p2_load_diagnostic
// Description: Separate timer-only or continuous software-driven DMA workload; never a CoreMark score.
#include <stdint.h>
#include "benchmark_runtime.h"
#include "../../software/common/soc_clocks.h"
#ifndef P2_DIAGNOSTIC_IRQ_ONLY
#define P2_DIAGNOSTIC_IRQ_ONLY 0
#endif
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DMA_SOURCE 0x80000000u
#define DMA_DESTINATION 0x80008000u
#define DMA_BYTES 16384u
volatile uint32_t p2_diag_roi;
static volatile uint32_t interrupts, late_events, skipped, error_code;
static volatile uint64_t late_ticks, isr_cycles;
static uint64_t deadline;
static uint32_t interval_ticks;
static uint64_t timer_now(void)
{
    uint32_t hi, lo, again;
    do { hi=REG(0x0200bffc); lo=REG(0x0200bff8); again=REG(0x0200bffc); } while(hi!=again);
    return ((uint64_t)hi<<32)|lo;
}
static void timer_set(uint64_t value)
{
    REG(0x02004004)=~0u; REG(0x02004000)=(uint32_t)value; REG(0x02004004)=(uint32_t)(value>>32);
}
static void __attribute__((interrupt("machine"),aligned(4))) timer_handler(void)
{
    uint64_t begin=benchmark_read_cycle();
    uintptr_t cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if(cause!=(((uintptr_t)1<<(__riscv_xlen-1))|7)) { error_code=80; timer_set(~(uint64_t)0); return; }
    uint64_t now=timer_now();
    if(now>deadline) { late_events++; late_ticks+=now-deadline; }
    interrupts++;
    deadline+=interval_ticks;
    while(deadline<=now) { deadline+=interval_ticks; skipped++; }
    timer_set(interrupts>=16 ? ~(uint64_t)0 : deadline);
    isr_cycles+=benchmark_read_cycle()-begin;
}
static int maintain(void)
{
    REG(0x10040020)=3;
    for(unsigned i=0;i<100000;i++) {
        uint32_t status=REG(0x10040030);
        if(!(status&1)) return (status&0x1e)!=0;
    }
    return 1;
}
static int dma_copy(void)
{
    REG(0x10030000)=DMA_SOURCE; REG(0x10030004)=DMA_DESTINATION;
    REG(0x10030008)=DMA_BYTES; REG(0x1003000c)=1;
    for(unsigned i=0;i<100000;i++) {
        uint32_t status=REG(0x10030010);
        if(status&6) {
            if((status&7)!=2||REG(0x10030014)!=DMA_BYTES) return 1;
            REG(0x10030010)=6;
            return 0;
        }
    }
    return 1;
}
static void text(const char *s) { while(*s) benchmark_putchar(*s++); }
static void number(uint64_t value)
{
    char out[24]; unsigned n=0;
    do { out[n++]=(char)('0'+value%10); value/=10; } while(value);
    while(n) benchmark_putchar(out[--n]);
}
static void field(const char *name,uint64_t value) { text(name); number(value); }
int main(void)
{
    struct hgb_soc_clocks clocks;
    if(hgb_soc_read_clocks(0x10040000u,REG(0x1004003c),&clocks)) return 70;
    interval_ticks=(clocks.timer_hz+9999u)/10000u;
    if(!interval_ticks) return 71;
    uintptr_t saved_mtvec, saved_mie, saved_mstatus;
    __asm__ volatile("csrr %0, mtvec" : "=r"(saved_mtvec));
    __asm__ volatile("csrr %0, mie" : "=r"(saved_mie));
    __asm__ volatile("csrr %0, mstatus" : "=r"(saved_mstatus));
    __asm__ volatile("csrci mstatus, 8; csrw mie, zero" ::: "memory");
    if(!P2_DIAGNOSTIC_IRQ_ONLY) {
        for(unsigned i=0;i<DMA_BYTES/4;i++) REG(DMA_SOURCE+4*i)=0x87390000u^(i*0x1021u);
        if(maintain()) return 72;
    } else {
        __asm__ volatile("csrw mtvec, %0" :: "r"((uintptr_t)timer_handler));
        deadline=timer_now()+interval_ticks;
        timer_set(deadline);
        __asm__ volatile("csrw mie, %0" :: "r"((uintptr_t)128));
    }
    unsigned copies=0;
    p2_diag_roi=1;
    uint64_t begin=benchmark_read_cycle();
    if(P2_DIAGNOSTIC_IRQ_ONLY) {
        __asm__ volatile("csrsi mstatus, 8" ::: "memory");
        while(interrupts<16&&!error_code) __asm__ volatile("nop");
        __asm__ volatile("csrci mstatus, 8" ::: "memory");
    } else {
        // 命令完成后立即提交下一条；CPU轮询/写寄存器开销保留为单独的软件诊断。
        for(copies=0;copies<8;copies++) if(dma_copy()) { error_code=73; break; }
    }
    uint64_t elapsed=benchmark_read_cycle()-begin;
    p2_diag_roi=2;
    timer_set(~(uint64_t)0);
    __asm__ volatile("csrw mtvec, %0" :: "r"(saved_mtvec));
    __asm__ volatile("csrw mie, %0" :: "r"(saved_mie));
    __asm__ volatile("csrw mstatus, %0" :: "r"(saved_mstatus) : "memory");
    if(error_code) return (int)error_code;
    if(!P2_DIAGNOSTIC_IRQ_ONLY) {
        if(maintain()) return 74;
        for(unsigned i=0;i<DMA_BYTES/4;i++)
            if(REG(DMA_DESTINATION+4*i)!=(0x87390000u^(i*0x1021u))) return 75;
        if(interrupts||copies!=8) return 76;
    } else if(interrupts!=16||copies) return 77;
    text("P2_LOAD_DIAGNOSTIC mode="); text(P2_DIAGNOSTIC_IRQ_ONLY?"irq_only":"dma_only");
    field(" core_cycles=",elapsed); field(" core_hz=",clocks.core_hz); field(" timer_hz=",clocks.timer_hz);
    field(" interval_ticks=",interval_ticks); field(" irq=",interrupts); field(" dma_completed=",copies);
    field(" dma_bytes=",(uint64_t)copies*DMA_BYTES); field(" late_events=",late_events);
    field(" late_ticks=",late_ticks); field(" skipped=",skipped); field(" isr_body_cycles=",isr_cycles);
    text(" errors=0\n");
    return 0;
}
