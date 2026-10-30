/* Module: coremark_board_port
 * Description: Runtime-selected seeds and real Core-clock timing without changing vendor code.
 */
#include "coremark.h"
#include "benchmark_runtime.h"
#include "board.h"

volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 1;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

static CORE_TICKS start_cycle;
static CORE_TICKS stop_cycle;

void start_time(void)
{
    __asm__ volatile("" ::: "memory");
    start_cycle = benchmark_read_cycle();
    __asm__ volatile("" ::: "memory");
}

void stop_time(void)
{
    __asm__ volatile("" ::: "memory");
    stop_cycle = benchmark_read_cycle();
    __asm__ volatile("" ::: "memory");
}

CORE_TICKS get_time(void)
{
    return stop_cycle - start_cycle;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    // vendor 的整数秒用于检查时长；PC 使用独立 u64 周期求精确小数。
    return (secs_ret)(ticks / board_clocks.core_hz);
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    portable->portable_id = 1;
}

void portable_fini(core_portable *portable)
{
    portable->portable_id = 0;
}
