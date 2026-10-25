// Module: p2_timing_boundary
// Description: Runs cache preparation and timing hooks on a separate DTCM stack.
    .section .text.p2_control,"ax",@progbits
    .align 2
    .option norvc
#if __riscv_xlen == 32
#define REG_S sw
#define REG_L lw
#define REG_BYTES 4
#else
#define REG_S sd
#define REG_L ld
#define REG_BYTES 8
#endif
    .globl start_time
start_time:
    mv t0, sp
    la sp, __control_stack_top
    addi sp, sp, -16
    REG_S t0, 0(sp)
    REG_S ra, REG_BYTES(sp)
    call p2_start_time
    REG_L ra, REG_BYTES(sp)
    REG_L t0, 0(sp)
    mv sp, t0
    ret
    .globl stop_time
stop_time:
    mv t0, sp
    la sp, __control_stack_top
    addi sp, sp, -16
    REG_S t0, 0(sp)
    REG_S ra, REG_BYTES(sp)
    call p2_stop_time
    REG_L ra, REG_BYTES(sp)
    REG_L t0, 0(sp)
    mv sp, t0
    ret

    // 中断使用另一段 DTCM 栈。先保存全部 caller-saved 寄存器，C 函数保留 s 寄存器。
    .align 2
    .globl p2_timer_entry
p2_timer_entry:
    csrrw sp, mscratch, sp
    addi sp, sp, -(16 * REG_BYTES)
    REG_S ra, (0 * REG_BYTES)(sp)
    REG_S t0, (1 * REG_BYTES)(sp)
    REG_S t1, (2 * REG_BYTES)(sp)
    REG_S t2, (3 * REG_BYTES)(sp)
    REG_S a0, (4 * REG_BYTES)(sp)
    REG_S a1, (5 * REG_BYTES)(sp)
    REG_S a2, (6 * REG_BYTES)(sp)
    REG_S a3, (7 * REG_BYTES)(sp)
    REG_S a4, (8 * REG_BYTES)(sp)
    REG_S a5, (9 * REG_BYTES)(sp)
    REG_S a6, (10 * REG_BYTES)(sp)
    REG_S a7, (11 * REG_BYTES)(sp)
    REG_S t3, (12 * REG_BYTES)(sp)
    REG_S t4, (13 * REG_BYTES)(sp)
    REG_S t5, (14 * REG_BYTES)(sp)
    REG_S t6, (15 * REG_BYTES)(sp)
    call p2_timer_interrupt
    REG_L ra, (0 * REG_BYTES)(sp)
    REG_L t0, (1 * REG_BYTES)(sp)
    REG_L t1, (2 * REG_BYTES)(sp)
    REG_L t2, (3 * REG_BYTES)(sp)
    REG_L a0, (4 * REG_BYTES)(sp)
    REG_L a1, (5 * REG_BYTES)(sp)
    REG_L a2, (6 * REG_BYTES)(sp)
    REG_L a3, (7 * REG_BYTES)(sp)
    REG_L a4, (8 * REG_BYTES)(sp)
    REG_L a5, (9 * REG_BYTES)(sp)
    REG_L a6, (10 * REG_BYTES)(sp)
    REG_L a7, (11 * REG_BYTES)(sp)
    REG_L t3, (12 * REG_BYTES)(sp)
    REG_L t4, (13 * REG_BYTES)(sp)
    REG_L t5, (14 * REG_BYTES)(sp)
    REG_L t6, (15 * REG_BYTES)(sp)
    addi sp, sp, (16 * REG_BYTES)
    csrrw sp, mscratch, sp
    mret
