#include "coremark.h"
#include "core_portme.h"
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
#error "Only CoreMark performance and validation runs are supported"
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

static CORETIMETYPE start_cycle;
static CORETIMETYPE stop_cycle;

void start_time(void)
{
    start_cycle = benchmark_read_cycle();
}

void stop_time(void)
{
    stop_cycle = benchmark_read_cycle();
}

CORE_TICKS get_time(void)
{
    return stop_cycle - start_cycle;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    // 仿真以 1 MHz 对周期归一化，CoreMark/MHz 因此可直接由 iterations/cycles 计算。
    return (secs_ret)(ticks / 1000000ull);
}

void portable_init(core_portable *portable, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int cannot hold a pointer.\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 is not 32 bits.\n");
    portable->portable_id = 1;
}

void portable_fini(core_portable *portable)
{
    portable->portable_id = 0;
}
