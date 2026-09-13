// Module: benchmark_crt0
// Description: Initializes the bare-metal C environment and reports exit through ECALL/tohost.
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
    la t0, trap_vector
    csrw mtvec, t0

    // DMem 镜像已放置 .data，启动时只需清零 NOBITS 的 .bss。
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, call_main
    sb zero, 0(t0)
    addi t0, t0, 1
    j clear_bss

call_main:
    call main
    li a7, 93
    ecall

    .align 2
trap_vector:
    csrr t0, mcause
    li t1, 11
    bne t0, t1, unexpected_trap
    li t1, 93
    bne a7, t1, unexpected_trap
    beqz a0, report_pass
    slli a0, a0, 1
    ori a0, a0, 1
    j write_result

report_pass:
    li a0, 1
write_result:
    la t0, tohost
    sw a0, 0(t0)
halt:
    j halt

unexpected_trap:
    addi t0, t0, 1
    slli a0, t0, 1
    ori a0, a0, 1
    j write_result
