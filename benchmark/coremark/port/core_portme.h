#ifndef RHBYV_CORE_PORTME_H
#define RHBYV_CORE_PORTME_H

#include <stddef.h>

#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#define COMPILER_VERSION "GCC " __VERSION__
#if __riscv_xlen == 32
#define COMPILER_FLAGS "-O2 -march=rv32i_zicsr -mabi=ilp32"
#else
#define COMPILER_FLAGS "-O2 -march=rv64i_zicsr -mabi=lp64"
#endif
#define MEM_LOCATION "Static data in one-cycle simulated DMem"

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef double ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef __UINTPTR_TYPE__ ee_ptr_int;
typedef size_t ee_size_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~(ee_ptr_int)3))

#define CORETIMETYPE unsigned long long
typedef unsigned long long CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *portable, int *argc, char *argv[]);
void portable_fini(core_portable *portable);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && \
    !defined(VALIDATION_RUN)
#error "CoreMark run mode must be selected explicitly"
#endif

int ee_printf(const char *format, ...);

#endif
