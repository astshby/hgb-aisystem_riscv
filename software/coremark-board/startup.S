// Module: coremark_board_startup
// Description: Starts the persistent UART application from initialized TCM.
    .section .text.init
    .align 6
    .option norvc
    .global _start
_start:
    csrci mstatus, 8
    csrw mie, zero
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    la t0, board_trap
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, start_application
    sb zero, 0(t0)
    addi t0, t0, 1
    j clear_bss
start_application:
    call hgb_board_main
halt:
    j halt

    .align 2
board_trap:
    csrr a0, mcause
    csrr a1, mepc
    // 故障独立使用已知栈顶；不回到正在执行的 benchmark。
    la sp, __stack_top
    call board_fault
    j halt
