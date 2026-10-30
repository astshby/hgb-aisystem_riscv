/* Module: coremark_board_platform
 * Description: Polling UART, clock discovery, DDR scratch check and u64 report output.
 */
#include "board.h"
#include "benchmark_runtime.h"

#define REG32(address) (*(volatile uint32_t *)(uintptr_t)(address))
#define UART_BASE 0x10000000u
#define INFO_BASE 0x10040000u

struct hgb_soc_clocks board_clocks;
static int uart_initialized;

void benchmark_putchar(char value)
{
    if (!uart_initialized) return;
    while (!(REG32(UART_BASE + 8u) & 1u)) { }
    REG32(UART_BASE) = (unsigned char)value;
}

void board_puts(const char *text)
{
    while (*text) benchmark_putchar(*text++);
}

void board_u64(uint64_t value)
{
    char digits[20];
    unsigned count = 0;
    do {
        digits[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value);
    while (count) benchmark_putchar(digits[--count]);
}

int board_getchar(void)
{
    for (;;) {
        uint32_t status = REG32(UART_BASE + 8u);
        if (status & 12u) {
            if (status & 2u) (void)REG32(UART_BASE + 4u);
            REG32(UART_BASE + 8u) = 12u;
            return -1;
        }
        if (status & 2u) return (unsigned char)REG32(UART_BASE + 4u);
    }
}

int board_init(void)
{
    uint32_t discovery = REG32(INFO_BASE + HGB_SOC_DISCOVERY_OFFSET);
    uint32_t presence = REG32(INFO_BASE + HGB_SOC_PRESENCE_OFFSET);
    if (hgb_soc_read_clocks(INFO_BASE, discovery, &board_clocks)) return -1;
    uint32_t divisor = hgb_soc_uart_divisor(board_clocks.periph_hz, HGB_BOARD_BAUD);
    if (!divisor) return -1;
    REG32(UART_BASE + 16u) = 0;
    REG32(UART_BASE + 12u) = divisor;
    REG32(UART_BASE + 8u) = 12u;
    uart_initialized = 1;
    if (!hgb_soc_discovery_valid(presence, discovery) ||
        !hgb_soc_has(presence, HGB_TARGET_UART0) ||
        !hgb_soc_has(presence, HGB_TARGET_DDR)) return -1;

    // 当前固件代码/数据在 TCM；此保留地址只作 DDR 启动小检查。
    volatile uint32_t *scratch = (volatile uint32_t *)(uintptr_t)0x8003f000u;
    for (unsigned i = 0; i < 16; i++) scratch[i] = 0x5a690000u ^ i;
    REG32(INFO_BASE + 0x20u) = 3u;
    uint64_t start = benchmark_read_cycle();
    while (REG32(INFO_BASE + 0x30u) & 1u) {
        if (benchmark_read_cycle() - start >= board_clocks.core_hz) return -1;
    }
    if (REG32(INFO_BASE + 0x30u) & 6u) return -1;
    for (unsigned i = 0; i < 16; i++)
        if (scratch[i] != (0x5a690000u ^ i)) return -1;
    return 0;
}

void board_ready(void)
{
    board_puts("READY app=coremark version=1 firmware=" HGB_BOARD_BUILD_ID);
    board_puts(" core_hz="); board_u64(board_clocks.core_hz);
    board_puts(" sys_hz="); board_u64(board_clocks.sys_hz);
    board_puts(" ddr_hz="); board_u64(board_clocks.ddr_hz);
    board_puts(" periph_hz="); board_u64(board_clocks.periph_hz);
    board_puts(" memory=tcm opt=" HGB_OPT_LEVEL " baud="); board_u64(HGB_BOARD_BAUD);
    board_puts(HGB_BOARD_SIM_ITERATIONS ? " test_only=1\n" : " test_only=0\n");
}

void board_fault(uintptr_t cause, uintptr_t pc)
{
    board_puts("FAULT cause="); board_u64(cause);
    board_puts(" pc="); board_u64(pc);
    board_puts("\nDONE status=trap\n");
    for (;;) { }
}
