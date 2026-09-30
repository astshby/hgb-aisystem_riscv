/* SPDX-License-Identifier: Apache-2.0 */
/* 与上游 common/rt_hw_stack_frame.h、context_gcc.S 共用帧布局。 */
#define __ASSEMBLY__
#include "cpuport.h"
    .option norvc
    .section .hot.entry,"ax"
    .balign 64
    .global hgb_trap
hgb_trap:
    addi sp, sp, -32 * REGBYTES
    STORE x1, 1 * REGBYTES(sp)
    .irp reg,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    STORE x\reg, \reg * REGBYTES(sp)
    .endr
    csrr t0, mepc
    STORE t0, 0 * REGBYTES(sp)
    csrr t0, mstatus
    STORE t0, 2 * REGBYTES(sp)
    mv s0, sp
    la sp, __rt_rvstack
    call rt_interrupt_enter
    csrr a0, mcause
    mv a1, s0
    call hgb_dispatch
    call rt_interrupt_leave
    mv sp, s0
    la t0, rt_thread_switch_interrupt_flag
    lw t1, 0(t0)
    beqz t1, 1f
    sw zero, 0(t0)
    la t0, rt_interrupt_from_thread
    LOAD t1, 0(t0)
    STORE sp, 0(t1)
    la t0, rt_interrupt_to_thread
    LOAD t1, 0(t0)
    LOAD sp, 0(t1)
1:  tail rt_hw_context_switch_exit
