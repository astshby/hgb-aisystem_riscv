/* SPDX-License-Identifier: Apache-2.0 */
/* 异步抢占探针：两个线程使用不同模式，检查高位、参数和临时寄存器。 */
#define __ASSEMBLY__
#include "cpuport.h"
    .option norvc
    .text
    .balign 4
    .global hgb_context_probe
hgb_context_probe:
    addi sp, sp, -32 * REGBYTES
    .irp reg,1,4,8,9,18,19,20,21,22,23,24,25,26,27
    STORE x\reg, \reg * REGBYTES(sp)
    .endr
    STORE a0, 10 * REGBYTES(sp)
    STORE a1, 11 * REGBYTES(sp)
    slli a2, a2, 12
#if __riscv_xlen == 64
    li t1, 0x1234567800000000
#else
    li t1, 0x12340000
#endif
    add t1, t1, a2
    STORE t1, 6 * REGBYTES(sp)
    .irp reg,1,4,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    addi x\reg, t1, \reg
    .endr
1:
    andi t0, sp, 15
    bnez t0, 3f
    LOAD t0, 6 * REGBYTES(sp)
    bne t0, t1, 3f
    LOAD t0, 10 * REGBYTES(sp)
    bne t0, a0, 3f
    LOAD t0, 11 * REGBYTES(sp)
    bne t0, a1, 3f
    .irp reg,1,4,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    addi t0, t1, \reg
    bne t0, x\reg, 3f
    .endr
    lw t0, 0(a1)
    addi t0, t0, 1
    sw t0, 0(a1)
    lw t0, 0(a0)
    beqz t0, 1b
    li a0, 0
    j 4f
3:  li a0, 1
4:
    .irp reg,1,4,8,9,18,19,20,21,22,23,24,25,26,27
    LOAD x\reg, \reg * REGBYTES(sp)
    .endr
    addi sp, sp, 32 * REGBYTES
    ret
