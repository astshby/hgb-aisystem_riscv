/* Module: dma_smoke
 * Description: Bare-metal DMA, interrupt and optional external-memory integration test.
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DMA 0x10030000u
#define IRQ 0x0c000000u
#define DDR 0x80000000u

static volatile uint8_t source[64], target[64];
static volatile uint32_t code[2];
static volatile unsigned long irq_seen, trap_failure;
static volatile uint32_t last_status, last_bytes, last_fault, last_code;

/* 完成状态是电平中断：先读结果并 W1C，再向中断控制器写完成。 */
void __attribute__((interrupt("machine"), aligned(4))) soc_trap(void)
{
    unsigned long cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause != ((1UL << (__riscv_xlen - 1)) | 11UL)) {
        trap_failure = 1;
        return;
    }
    uint32_t id = REG32(IRQ + 0x200004);
    if (id != 7) {
        trap_failure = 2;
        return;
    }
    last_status = REG32(DMA + 0x10);
    last_bytes = REG32(DMA + 0x14);
    last_fault = REG32(DMA + 0x18);
    last_code = REG32(DMA + 0x1c);
    REG32(DMA + 0x10) = 6;
    REG32(IRQ + 0x200004) = id;
    irq_seen++;
}

static int transfer(uint32_t src, uint32_t dst, uint32_t length,
                    uint32_t expected_bytes, uint32_t expected_code)
{
    unsigned long before = irq_seen;
    REG32(DMA) = src;
    REG32(DMA + 4) = dst;
    REG32(DMA + 8) = length;
    REG32(DMA + 12) = 3;
    for (unsigned int i = 0; i < 500000; i++) {
        if (irq_seen != before) break;
    }
    if (irq_seen != before + 1 || trap_failure) return 1;
    if (last_bytes != expected_bytes || last_code != expected_code) return 2;
    if (expected_code == 0 && !(last_status & 2)) return 3;
    if (expected_code != 0 && !(last_status & 4)) return 4;
    if (expected_code != 0 && last_fault != src) return 5;
    return 0;
}

int main(void)
{
    for (unsigned int i = 0; i < sizeof(source); i++) {
        source[i] = (uint8_t)(i * 3 + 11);
        target[i] = 0;
    }
    REG32(IRQ + 28) = 1;
    REG32(IRQ + 0x2000) = 1u << 7;
    REG32(IRQ + 0x200000) = 0;
    __asm__ volatile("csrw mie, %0" :: "r"(0x800UL));
    __asm__ volatile("csrsi mstatus, 8");

    int result = transfer((uint32_t)(uintptr_t)&source[1],
                          (uint32_t)(uintptr_t)&target[3], 35, 35, 0);
    if (result) return 10 + result;
    for (unsigned int i = 0; i < 35; i++)
        if (target[i + 3] != source[i + 1]) return 20;

#if SOC_DDR_BYTES != 0
    result = transfer((uint32_t)(uintptr_t)&source[2], DDR + 0x100, 35, 35, 0);
    if (result) return 30 + result;
    result = transfer(DDR + 0x101, (uint32_t)(uintptr_t)&target[4], 34, 34, 0);
    if (result) return 40 + result;
    for (unsigned int i = 0; i < 34; i++)
        if (target[i + 4] != source[i + 3]) return 50;

    /* 外存代码用普通 32 位 ADDI/JALR，DMA 写入后由 CPU 的 I 口读取。 */
    code[0] = 0x02500513u;
    code[1] = 0x00008067u;
    result = transfer((uint32_t)(uintptr_t)&code[0], DDR + 0x200, 8, 8, 0);
    if (result) return 60 + result;
    __asm__ volatile("fence.i" ::: "memory");
    if (((int (*)(void))(uintptr_t)(DDR + 0x200))() != 37) return 70;
#endif

    result = transfer(0x10000000u, (uint32_t)(uintptr_t)&target[0], 8, 0, 1);
    if (result) return 80 + result;
    __asm__ volatile("csrci mstatus, 8");
    return 0;
}
