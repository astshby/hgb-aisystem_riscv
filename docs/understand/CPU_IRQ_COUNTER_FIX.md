# IRQ 撤销与 MINSTRET 顺序修复

> 2026-09-29（Asia/Shanghai）。本轮按用户确认修复审核中的三个问题。
> 非对齐访问仍在 EX 检测、WB 精确触发异常；不增加透明完成支持，ma_data 继续跳过。

## 同步范围

| 阶段 | rhbyv 分支 | hgb 分支 |
|---|---|---|
| TCM/MMIO | SOC/tmc-mmio | SOC/tmc-mmio |
| 完整 AXI/DMA | soc/s3-axi-dma | soc/s3-dma-validation |
| Cache 准备 | s4/cache | s4/cache |

只同步本轮的 Core、TB 和对应硬件文档补丁，不把 S3 的 DMA/AXI 功能带回 S2。
main 及 hgb 较早的 soc/s3-axi-dma 分支不动。Cache RTL 尚未实现。

## IRQ：停止新请求不等于丢弃已接受的取指

旧实现将实时 irq_pending 同时用于停取指和清 IF。如果 IRQ 在流水排空前撤销，
已经清掉的请求/缓冲不再执行，而 PC 已经前进；没有 Trap 重定向补救，就可能跳过指令。

现在 pending 只关闭新请求。已接受的 IF 请求、返回缓冲和流水指令继续按原握手推进；
只有真正的 Trap/其它重定向才使用原有 kill 和旧响应排空机制。IRQ 撤销或在途 CSR
关闭 MIE 时，原指令流可以继续，不需要锁存一个已经失效的中断。

中断仍须等流水排空才进入，架构恢复 PC 来自最后退休指令的实际后继。此改动允许
此前已接受的少量年轻取指正常执行，可能改变中断进入的具体拍数，不承诺固定延迟。
未返回且尚未进入流水的取指可在真正 Trap 时被杀死，但仍必须排空其响应。

修改位置：core.sv 的 IF flush 连接，以及 interrupt_entry.sv 的契约注释。
tb_core_interrupt 保留原七场景，增加 Load/Store/MDU 等待时 IRQ 撤销，以及 CSR 关闭
MIE 四场景。新增路径按直线 PC 检查退休顺序，避免跳转恰好掩盖丢指令；同时检查
中断/异常次数和 Store 去重。

## MINSTRET：普通写旁路不能代表隐式退休增量

mscratch 一类普通 CSR 仅由显式写修改，原有 MEM/WB 写前递适用；MINSTRET 则会被
每条正常退休指令隐式修改。比如“清零、NOP、读取”不能只前递清零值。

Core 将 EX/MEM、MEM/WB 是否有效传给 EX。合法 MINSTRET/H 访问在较老指令存在时
产生 counter_wait，与原 MDU 请求等待合成 execution_stall；复用已有 EX_WAIT 动作，
保持本条及年轻指令，同时允许较老指令排空。较老指令全部退休后，EX 才保存计数器值。
不添加固定的计数补偿，不改变普通 CSR 前递，不移动提交点或 MDU 融合边界。

这会给退休计数器访问增加按序等待，而不会让普通 ALU、CSR 或每条退休都额外停顿。
已有异常不进入此等待；较老异常仍可通过 WB 重定向取消年轻访问。RV64 MINSTRETH
仍按原权限规则非法，不因为这个 interlock 而变为受支持的 CSR。

新 tb_core_minstret 只依据提交指令流维护独立 64 位参考计数，不读取 DUT 内部计数器，
覆盖 0–5 条 NOP 间隔、连续读改写、长 Load/Store/MDU、ECALL 不计数与 handler/MRET
正常计数，以及 RV32 高低半访问/回绕。tb_ex_stage 另检查普通 CSR 和已有异常不误停顿。

## RV32 半宽写：先决定是否自增，再更新目标半字

旧逻辑先给整个 MINSTRET 加一，再只覆盖写入的半部。写低半会残留高半进位，
写高半会残留低半加一。现在显式写 MINSTRET 或 RV32 MINSTRETH 时，整个计数器
不执行该指令的退休增量，再更新目标半字；未写半部保持原值。

tb_csr_file 在同一时钟沿施加 write_valid 与 retire_valid，验证低半 ffffffff 时
写零不导致高半进位，以及写高半不增加低半。MCYCLE 的行为不在本次修复范围内。

## 验证结果

六个目标分支分别执行双位宽测试，默认 MUL_IMPL=0、DIV_IMPL=0；不是仅复制代码后
复用另一个仓库的 PASS。每个分支的结果如下：

| 验证入口 | RV32 | RV64 |
|---|---|---|
| make test（含 Core lint） | 42 unit + 17 directed PASS，1 SKIP | 42 unit + 17 directed PASS，1 SKIP |
| make riscv-tests | 58/58 PASS，2 SKIP | 78/78 PASS，2 SKIP |
| make soc-riscv-tests | 59/59 PASS，1 SKIP | 79/79 PASS，1 SKIP |
| benchmark-smoke / soc-smoke | 各 1 PASS | 各 1 PASS |
| coremark / soc-coremark | 各 performance、validation PASS | 各 performance、validation PASS |
| soc-software | 1 PASS | 1 PASS |
| soc-test：TCM/MMIO 分支 | 3 PASS | 3 PASS |
| soc-test：完整 AXI/DMA、Cache 分支 | 5 PASS | 5 PASS |
| soc-dma-software：完整 AXI/DMA、Cache 分支 | DDR 关闭/64 KiB 各 1 PASS | DDR 关闭/64 KiB 各 1 PASS |

directed SKIP 是另一 XLEN 的专用用例。Core-only ISA 跳过 fence_i、ma_data；SoC 的
统一地址路径通过 fence_i，只跳过 ma_data。S2 没有 DMA，不把尚未存在的目标记作 PASS。
新增中断用例每位宽 11 场景；计数器读值检查 RV32 为 24 次、RV64 为 20 次。

新计数器 TB 初次运行出现“PASS 后仍超时”的结束流程错误，已改为先跳出循环再统一
finish；这次初始结果不计通过。表中是修正后重新执行并扫描错误标记的结果，不能仅凭
进程退出码或出现 PASS 判断成功。

本轮未运行完整 MDU 软件后端矩阵、随机 ISS 差分、形式化或 FPGA 综合/上板；unit 中
的后端检查不能代替这些验证。现有非致命 lint 告警仍存在，不声称零告警。
本轮只作本地分支提交，不推送、不创建 PR、不合并 main。
