# DMA 搬运、进度与中断的完整路径

> 本文保留 S3 无 Cache 验证与后续设计背景。当前已实现 S5 WB/WA D$；
> DMA 交接前后必须按 [S5 维护协议](S5_CACHE_WRITEBACK.md) 执行，不能只等待 DONE。

## 谁是主端，谁是从端

CPU 向 `0x1003_0000` 写寄存器时，走的是 CPU D 主端 → 互连 → DMA MMIO 从端。
真正搬运时，`dma_engine` 才以第三个主端发起读写；CPU 不逐字搬运，也不通过
`tohost` 告诉硬件完成。见 [`dma_controller`](../../vsrc/soc/dma/dma_controller.sv)、
[`soc_top`](../../vsrc/soc/soc_top.sv)。DMA IRQ 接入中断控制器 ID 7，最终成为
Core 的机器外部中断。

## 一次命令的时间线

1. 软件写 `SRC`、`DST`、`LENGTH`，最后写 `CTRL.START=1`；`IRQ_EN` 是 CTRL bit 1。
   寄存器访问仍要等 MMIO 写响应，不能把写指令发出等同于启动已完成。
2. 引擎先验证完整 32 位物理范围：非零、两端均在 I/D-TCM 或已启用的外存范围、
   源/目的不重叠。MMIO/ROM 不作为普通复制源，避免读/写副作用。
3. 引擎发一笔读请求，`req_valid && req_ready` 后等待读响应；收到 `rsp_valid &&
   rsp_ready` 且无错误，锁存数据，再发一笔写请求。写的 B/本地响应成功后才增加
   `BYTES`。因此读完不等于已写完，`DONE` 不会早于最后一笔写完成。
4. 同时自然对齐且剩余长度足够时搬 XLEN 字节；任一端错位或剩余不足则逐字节搬。
   源、目的低位可不同，数据与写掩码由引擎按各自 byte lane 放置。
5. 完成产生持久 `DONE`，失败产生持久 `ERROR`；`IRQ_EN && (DONE || ERROR)`
   是电平中断。软件先读 `STATUS/BYTES/FAULT/CODE`，写 1 清 `STATUS` bit 1/2，
   最后向 IRQ 控制器写 ID 7 完成。若先 complete、未清原因，会重新挂起。

## 状态与失败不能混淆

`STATUS` bit 0/1/2 为 BUSY/DONE/ERROR。`BYTES` 只数**成功写响应**确认的字节，
不是发出请求或读回的字节；写错误时旧写入不回滚。`CODE=1` 是启动配置错误，
`2/3` 是读 DECERR/SLVERR，`4/5` 是写 DECERR/SLVERR，0 表示成功。
`FAULT` 给故障侧地址。配置错误在任何 DMA 总线请求之前发现；正在 busy 时配置寄存器
写入返回 SLVERR。DMA 只允许一笔事务在途，硬件不做链表、scatter-gather、外设 DMA
或 AXI burst。

## 从软件验证回看硬件

[`dma_smoke.c`](../../tb/soc/dma_smoke.c) 的 C 程序由 ROM 进入 I-TCM，配置 DMA，
用机器中断 handler 读取结果；运行器 [`run_dma_software.sh`](../../scripts/verilator/run_dma_software.sh)
分别测试无外存与 64 KiB 仿真外存。外存配置还把两条指令由 D-TCM 搬到外存，执行
`FENCE.I` 后由 CPU I 口取回执行。`FENCE.I` 负责取指同步；未来若加入 D$/I$，
还需明确 DMA 与 Cache 的清理/失效协议，不能把这次无 Cache 的成功当成一致性证明。

定向 TB [`tb_dma_fabric.sv`](../../tb/soc/tb_dma_fabric.sv) 另外检查反压、持续 CPU D
竞争、读写错误、零长/重叠拒绝、IRQ claim/complete 和协调复位。复位同时作用于
DMA、互连、AXI 桥及模型；它清控制状态，不承诺撤回复位前已接受的外存写入。
