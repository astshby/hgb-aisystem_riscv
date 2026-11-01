// Module: benchmark_crt0
// Description: Initializes the bare-metal C environment and reports exit through ECALL/tohost.
// YOLO诊断不使用栈、GP或数据段；每字节有界轮询，非YOLO构建不生成这些指令。
#ifdef YOLO_DEMO_BAUD
    .macro yolo_trace_byte value
    li t4, 10000
.Lyolo_uart_wait\@:
    lw t5, 8(t3)
    andi t5, t5, 1
    bnez t5, .Lyolo_uart_send\@
    addi t4, t4, -1
    bnez t4, .Lyolo_uart_wait\@
    j .Lyolo_uart_done\@
.Lyolo_uart_send\@:
    li t6, \value
    sw t6, 0(t3)
.Lyolo_uart_done\@:
    .endm
    .macro yolo_trace_stage stage
    li t3, 0x10000000
    yolo_trace_byte 83
    yolo_trace_byte 58
    yolo_trace_byte \stage
    yolo_trace_byte 13
    yolo_trace_byte 10
    .endm
#endif
    .section .text.init
    .align 6
    .option norvc
    .globl _start
_start:
#ifdef YOLO_DEMO_BAUD
    yolo_trace_stage 48 // S:0，进入ITCM，尚未使用GP/SP。
#endif
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    la t0, trap_vector
    csrw mtvec, t0

#ifdef YOLO_DEMO_BAUD
    yolo_trace_stage 49 // S:1，GP/SP和异常入口设置完成。
#endif

    // DMem 镜像已放置 .data，启动时只需清零 NOBITS 的 .bss。
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, call_main
    sb zero, 0(t0)
    addi t0, t0, 1
    j clear_bss

call_main:
#ifdef YOLO_DEMO_BAUD
    yolo_trace_stage 50 // S:2，BSS清零完成，尚未调用C。
#endif
    call main
    li a7, 93
    ecall

    .align 2
trap_vector:
    csrr t0, mcause
#ifdef YOLO_DEMO_BAUD
    li t3, 0x10000000
    yolo_trace_byte 84 // T: 表示已进入原有异常入口，原报告路径继续。
    yolo_trace_byte 58
    yolo_trace_byte 13
    yolo_trace_byte 10
#endif
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
