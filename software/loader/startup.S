    .option norvc
    .section .text.init,"ax"
    .global _start
_start:
    csrci mstatus, 8
    csrw mie, zero
    la sp, __stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la t0, loader_fault
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sb zero, 0(t0)
    addi t0, t0, 1
    j 1b
2:  call loader_main
    j loader_fault
