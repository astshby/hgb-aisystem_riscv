// Module: soc_irq_crt0
// Description: Starts the SoC interrupt smoke image and reports the C return code to tohost.
    .section .text.init
    .align 6
    .option norvc
    .globl _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    la t0, soc_trap
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, call_main
    sb zero, 0(t0)
    addi t0, t0, 1
    j clear_bss
call_main:
    call main
    // 本测试的 trap 入口用于真实设备 IRQ；返回值仍按 tohost 约定编码。
    slli a0, a0, 1
    ori a0, a0, 1
    la t0, tohost
    sw a0, 0(t0)
halt:
    j halt
