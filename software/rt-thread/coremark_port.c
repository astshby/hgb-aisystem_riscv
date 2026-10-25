/* SPDX-License-Identifier: Apache-2.0 */
/* CoreMark port for the RT-Thread BSP; the vendor benchmark sources are unchanged. */
#include "board.h"
#include "coremark.h"
#include "benchmark_runtime.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#elif PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
#else
#error "Select a CoreMark run mode"
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
volatile unsigned hgb_coremark_validated;
volatile unsigned hgb_coremark_crc_mask;
static benchmark_cycle_t start_cycle, stop_cycle;
static unsigned matched, list_pos, matrix_pos, state_pos;

#if VALIDATION_RUN
static const char list_crc[] = "crclist       : 0xe3c1";
static const char matrix_crc[] = "crcmatrix     : 0x0747";
static const char state_crc[] = "crcstate      : 0x8d84";
#else
static const char list_crc[] = "crclist       : 0xe714";
static const char matrix_crc[] = "crcmatrix     : 0x1fd7";
static const char state_crc[] = "crcstate      : 0x8e3a";
#endif

static unsigned match_char(const char *pattern, unsigned index, char value)
{
    if (value == pattern[index]) index++;
    else index = (value == pattern[0]) ? 1u : 0u;
    return index;
}

benchmark_cycle_t benchmark_read_cycle(void)
{
#if __riscv_xlen == 64
    benchmark_cycle_t value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
#else
    rt_uint32_t hi, lo, check;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(check));
    } while (hi != check);
    return ((benchmark_cycle_t)hi << 32) | lo;
#endif
}

void benchmark_putchar(char value)
{
    static const char ok[] = "Correct operation validated.";
    char text[2] = { value, 0 };
    sim_console = (unsigned char)value;
    rt_hw_console_output(text);
    matched = match_char(ok, matched, value);
    list_pos = match_char(list_crc, list_pos, value);
    matrix_pos = match_char(matrix_crc, matrix_pos, value);
    state_pos = match_char(state_crc, state_pos, value);
    if (ok[matched] == 0) hgb_coremark_validated = 1;
    if (list_crc[list_pos] == 0) hgb_coremark_crc_mask |= 1u;
    if (matrix_crc[matrix_pos] == 0) hgb_coremark_crc_mask |= 2u;
    if (state_crc[state_pos] == 0) hgb_coremark_crc_mask |= 4u;
}

void start_time(void) { start_cycle = benchmark_read_cycle(); }
void stop_time(void) { stop_cycle = benchmark_read_cycle(); }
CORE_TICKS get_time(void) { return stop_cycle - start_cycle; }
secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / hgb_clocks.core_hz);
}
void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    /* 每次重测独立检查 CRC/时长，不能沿用上一轮 PASS。 */
    hgb_coremark_validated = hgb_coremark_crc_mask = 0;
    matched = list_pos = matrix_pos = state_pos = 0;
    seed4_volatile = ITERATIONS;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *) || sizeof(ee_u32) != 4)
        hgb_finish(151);
    portable->portable_id = 1;
}
void portable_fini(core_portable *portable) { portable->portable_id = 0; }

void hgb_coremark_report(void)
{
    char digits[21];
    unsigned count = 0;
    benchmark_cycle_t cycles = get_time();
    do {
        digits[count++] = '0' + cycles % 10;
        cycles /= 10;
    } while (cycles);
    ee_printf("INFO xlen=%u cpu_hz=%u mul=%u div=%u\n", __riscv_xlen,
              hgb_clocks.core_hz, HGB_MUL_IMPL, HGB_DIV_IMPL);
#if VALIDATION_RUN
    ee_printf("COREMARK mode=validation cycles=");
#else
    ee_printf("COREMARK mode=performance cycles=");
#endif
    while (count) benchmark_putchar(digits[--count]);
    ee_printf(" memory=DDR crc=PASS duration=%s\n", hgb_coremark_validated ? "valid" : "short");
}
