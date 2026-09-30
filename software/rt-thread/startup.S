    .option norvc
    .section .text.init,"ax"
    .balign 64
    .global _start
_start:
    csrci mstatus, 8
    csrw mie, zero
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __rt_rvstack
    la t0, boot_fault
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sb zero, 0(t0)
    addi t0, t0, 1
    j 1b
2:  call hgb_boot
boot_fault:
    li a0, 127
    tail hgb_finish
