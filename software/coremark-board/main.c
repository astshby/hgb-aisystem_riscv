/* Module: coremark_board_main
 * Description: Repeated UART-triggered performance/validation runs with real-duration qualification.
 */
#include "coremark.h"
#include "board.h"

extern volatile ee_s32 seed1_volatile, seed2_volatile, seed3_volatile;
extern volatile ee_s32 seed4_volatile, seed5_volatile;
int coremark_run(void);

static const char *mode_name(int validation)
{
    return validation ? "validation" : "performance";
}

static void select_seeds(int validation, uint32_t iterations)
{
    seed1_volatile = validation ? 0x3415 : 0;
    seed2_volatile = seed1_volatile;
    seed3_volatile = 0x66;
    seed4_volatile = (ee_s32)iterations;
    seed5_volatile = 0;
}

static void run_header(const char *prefix, int validation, uint32_t iterations)
{
    board_puts(prefix);
    board_puts(" mode=");
    board_puts(mode_name(validation));
    board_puts(" iterations=");
    board_u64(iterations);
    board_puts("\n");
}

static void result(int validation, uint32_t iterations, uint64_t cycles, int formal)
{
    board_puts("CM_RESULT mode=");
    board_puts(mode_name(validation));
    board_puts(" iterations=");
    board_u64(iterations);
    board_puts(" roi_cycles=");
    board_u64(cycles);
    board_puts(" core_hz=");
    board_u64(board_clocks.core_hz);
    board_puts(formal ? " formal=1\n" : " formal=0\n");
}

static void execute(int validation)
{
    uint32_t iterations;
    uint64_t cycles;
    const uint64_t minimum = (uint64_t)board_clocks.core_hz * 10u;

    if (HGB_BOARD_SIM_ITERATIONS != 0) {
        // 短仿真保持真实时基，无论实际周期如何都不发布正式标志。
        iterations = HGB_BOARD_SIM_ITERATIONS;
    } else {
        const uint32_t calibration_iterations = 32;
        select_seeds(validation, calibration_iterations);
        run_header("CAL_BEGIN", validation, calibration_iterations);
        coremark_run();
        cycles = get_time();
        board_puts("CAL_END roi_cycles=");
        board_u64(cycles);
        board_puts("\n");
        if (!cycles) {
            board_puts("DONE status=timer_error\n");
            return;
        }
        // 目标 12 秒留出校准误差；正式运行仍以实测达到 10 秒为准。
        uint64_t count = ((uint64_t)board_clocks.core_hz * 12u *
                          calibration_iterations + cycles - 1u) / cycles;
        if (!count) count = 1;
        if (count > INT32_MAX) {
            board_puts("DONE status=iteration_overflow\n");
            return;
        }
        iterations = (uint32_t)count;
    }

    for (unsigned attempt = 0; attempt < 3; attempt++) {
        select_seeds(validation, iterations);
        run_header("CM_BEGIN", validation, iterations);
        coremark_run();
        cycles = get_time();
        int formal = HGB_BOARD_SIM_ITERATIONS == 0 && cycles >= minimum;
        result(validation, iterations, cycles, formal);
        if (HGB_BOARD_SIM_ITERATIONS != 0) {
            board_puts("DONE status=short\n");
            return;
        }
        if (formal) {
            // completed 表示计时完成；PC 还须核对 vendor 的 CRC 和错误行。
            board_puts("DONE status=completed\n");
            return;
        }
        if (!cycles || iterations > INT32_MAX / 2u) break;
        iterations *= 2u;
        if (attempt != 2) board_puts("CM_RETRY reason=duration\n");
    }
    board_puts("DONE status=too_short\n");
}

void hgb_board_main(void)
{
    int swallow_lf = 0;
    if (board_init()) {
        board_puts("BOOT_ERROR reason=platform\n");
        for (;;) { }
    }
    for (;;) {
        int validation = 0, have_command = 0, bad_command = 0;
        board_ready();
        for (;;) {
            int byte = board_getchar();
            if (byte < 0) {
                bad_command = 1;
                continue;
            }
            if (swallow_lf && byte == '\n') {
                swallow_lf = 0;
                continue;
            }
            swallow_lf = 0;
            if (byte == '\r' || byte == '\n') {
                swallow_lf = byte == '\r';
                break;
            }
            if ((byte == 'p' || byte == 'P' || byte == 'v' || byte == 'V') && !have_command) {
                validation = byte == 'v' || byte == 'V';
                have_command = 1;
            } else {
                bad_command = 1;
            }
        }
        if (bad_command) board_puts("DONE status=bad_command\n");
        else execute(validation);
    }
}
