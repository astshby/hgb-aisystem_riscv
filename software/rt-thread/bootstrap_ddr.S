    .option norvc
    .section .loader.init,"ax"
    .balign 64
    .global model_bootstrap
model_bootstrap:
    /* 仅供预装外存模型验证；真实板级版本须替换为 UART loader。 */
    csrci mstatus, 8
    csrw mie, zero
    la t0, _start
    jr t0
