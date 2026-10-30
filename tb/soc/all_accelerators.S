/* Both real accelerator windows, native status IRQs, PLIC IDs and MiniMind DDR traffic. */
.section .text
.globl _start
_start:
    li s0, 0x20000000
    li s1, 0x20010000
    li s2, 0x0c000000
    li s3, 0x0c002000
    li s4, 0x0c200000
    li s5, 0x01100000
    li a0, 1
    lw t0, 0(s0)
    li t1, 0x4e505531
    bne t0, t1, fail
    li a0, 2
    lw t0, 0(s1)
    li t1, 0x4d330001
    bne t0, t1, fail
    li t0, 1
    sw t0, 32(s2)
    sw t0, 36(s2)
    li t0, 0x300
    sw t0, 0(s3)
    /* Start without a shape/descriptor: both original devices report sticky error. */
    li t0, 1
    sw t0, 8(s0)
    sw t0, 8(s1)
    li a0, 3
    li t2, 2000
irq_wait:
irq_pending:
    li t3, 0x0c001000
    lw t0, 0(t3)
    li t1, 0x300
    and t0, t0, t1
    beq t0, t1, irq_ready
    addi t2, t2, -1
    bnez t2, irq_pending
    j fail
irq_ready:
    lw t0, 4(s4)
    li t1, 8
    bne t0, t1, fail
    li t0, 4
    sw t0, 12(s0)
    li t0, 31
    sw t0, 16(s0)
    li t0, 6
    sw t0, 12(s1)
    li t2, 40
clear_wait:
    addi t2, t2, -1
    bnez t2, clear_wait
    li t0, 8
    sw t0, 4(s4)
    lw t0, 4(s4)
    li t1, 9
    bne t0, t1, fail
    sw t0, 4(s4)
    lw t0, 4(s4)
    bnez t0, fail
    /* One-row, one-column legacy GEMV uses the real independent MiniMind DDR master. */
    li a0, 4
    li t0, 1
    sw t0, 20(s1)
    sw t0, 24(s1)
    li t0, 0x80000000
    sw t0, 28(s1)
    addi t0, t0, 64
    sw t0, 32(s1)
    addi t0, t0, 64
    sw t0, 36(s1)
    addi t0, t0, 64
    sw t0, 40(s1)
    addi t0, t0, 64
    sw t0, 44(s1)
    li t0, 0x40000000
    sw t0, 48(s1)
    sw zero, 52(s1)
    sw zero, 56(s1)
    li t0, 1
    sw t0, 8(s1)
    li t2, 20000
gemv_wait:
    lw t0, 12(s1)
    andi t1, t0, 4
    bnez t1, fail
    andi t1, t0, 2
    bnez t1, gemv_done
    addi t2, t2, -1
    bnez t2, gemv_wait
    j fail
gemv_done:
    li t0, 0x800000c0
    lh t1, 0(t0)
    beqz t1, fail
    li t0, 6
    sw t0, 12(s1)
    li t0, 0x600d0001
    sw t0, 0(s5)
passed:
    j passed
fail:
    sw a0, 0(s5)
    j fail
