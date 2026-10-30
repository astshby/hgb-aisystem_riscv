/* Module: coremark_board_api
 * Description: Bare-metal UART command and timing services for board CoreMark.
 */
#ifndef HGB_COREMARK_BOARD_H
#define HGB_COREMARK_BOARD_H

#include <stdint.h>
#include "soc_clocks.h"

#ifndef HGB_BOARD_BAUD
#define HGB_BOARD_BAUD 115200u
#endif
#ifndef HGB_BOARD_SIM_ITERATIONS
#define HGB_BOARD_SIM_ITERATIONS 0
#endif
#ifndef HGB_BOARD_BUILD_ID
#define HGB_BOARD_BUILD_ID "unidentified"
#endif
#ifndef HGB_OPT_LEVEL
#define HGB_OPT_LEVEL "-O3"
#endif

extern struct hgb_soc_clocks board_clocks;
int board_init(void);
int board_getchar(void);
void board_puts(const char *text);
void board_u64(uint64_t value);
void board_ready(void);
void board_fault(uintptr_t cause, uintptr_t pc);
void hgb_board_main(void);

#endif
