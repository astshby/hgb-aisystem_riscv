# Cache 接入前的 CPU 整体审核

> 2026-09-28（Asia/Shanghai）。用户指定 Astra 审核；本轮是只读 RTL 审核与设计，
> 不代表已修复，也不是形式化验证或 FPGA 时序签核。
>
> 后续状态（2026-09-29）：三项缺陷已按用户确认修复并完成六分支双位宽回归，
> 见 [修复与验证记录](CPU_IRQ_COUNTER_FIX.md)。下文保留 09-28 审核时的历史证据。

## 审核边界与版本

历史对照为 rhbyv `3936a52`（加入 SoC 前的最后提交），实际审核、测试对象为当前
`s4/cache` 的 `b30d8bc`；hgb 对应 `f714fba`。不回退后来新增的错误响应、FENCE
和中断支持。这样既检查原来的 CPU，也能识别新接口对 Cache 接入的约束。

范围包括 `vsrc/core/`、CPU 使用的 packages、`vsrc/sim_cpu/`、`vsrc/cpu/`，
以及相关 unit/directed/ISA 测试。SoC 仅作为 Cache 接口边界复核，不宣称再次
完整审核全部 UART、Timer、GPIO、DMA 和 AXI 实现。

| 路径 | 主要审核内容 | 对 Cache 的结论 |
|---|---|---|
| IF、BTB、GShare、预测更新仲裁 | 请求归属、缓冲、kill、保存的预测索引、训练时机 | 保留旧响应排空，不用 invalidate 代替响应 |
| D1/D2、decoder、异常检查、GPR | 非法编码、XLEN/W、源寄存器、异常优先级 | 无需提前 Load 或移动 load-use 检测 |
| EX、ALU/BRU、前递 | 实际操作数、分支重定向、保持期间旁路消失 | 保留 HOLD 时保存 WB 新值的逻辑 |
| MDU 及乘除后端 | 请求接受、跨 EX/MEM 所有权、结果保持、WB 取消 | 保留已验证的 EX 发射/MEM 拼包结构 |
| MEM/WB、流水控制、序列化 | 请求和完成分离、精确错误、年轻副作用禁止 | D$ 延迟由现有 WB 等待机制承接 |
| CSR、Trap、中断 | 普通 CSR 前递、动态计数、排空与恢复 PC | 两类正确性问题需先处理，见下文 |
| 仿真/FPGA wrapper | 存储模型边界、错误输入、可运行性 | Core-only 仿真不是统一 DDR/Cache 验证；cpu_top 仍是占位边界 |

## P1：IRQ 撤销后可能丢失指令（S2 新增路径）

位置：[`core.sv`](../../vsrc/core/core.sv) 184–186 行将实时 `irq_pending` 同时用于
停取指和清 IF；[`interrupt_entry.sv`](../../vsrc/core/control/interrupt_entry.sv)
16 行只在 pending 仍有效且流水为空时进入中断；
[`if_stage.sv`](../../vsrc/core/frontend/if_stage.sv) 的请求握手已推进 PC，flush 不恢复 PC。

触发过程：旧 Load 在 WB 等待，IF 已有请求或缓冲；拉高中断一拍，清掉这些年轻取指；
在排空前撤销中断。此后既没有 Trap 重定向，也没有取消排空后的重新取指地址，
CPU 可能从已经推进的 PC 继续运行，跳过被清掉的指令。

Astra 使用现有 `tb_core_interrupt` 的独立退休 PC 参考模型，在 `/tmp` 构造
IRQ 撤销诊断：Load 位于 PC `0x18`，等待期间拉高 timer IRQ 一拍后撤销；
后续应退休 `0x2c`，实际退休 `0x30`。RV32/RV64 均复现失败。
现有正式 TB 将 IRQ 保持至进入中断，所以原有七个场景通过并不能排除本问题。

建议把“开始排空”和实时 pending 分开管理。可选择停止新请求但保留待交付的 IF 包，
仅在真正 Trap 重定向时丢弃；或保留当前清 IF 策略，但登记排空状态，在取消时
从正确的架构后继 PC 恢复。不能简单锁存旧 pending 后无条件制造已撤销的中断。
具体实现还须覆盖较老 CSR 关闭 MIE、较老分支/Trap/MRET 和在途错误响应。

这是 Cache 接入前必须关闭的问题：miss 拉长等待窗口，不能要求 Cache 为 Core
补救丢失的 PC。修复后验证每条有效指令恰好退休一次，以及无错误路径 Store。

## P2：MINSTRET 读取遗漏前序退休增量（原 CPU 路径）

最小程序：

```asm
csrrwi x0, minstret, 0
nop
csrrs  x5, minstret, x0  # 应读到 1
```

RV32/RV64 当前实现均读到 0。[`ex_stage.sv`](../../vsrc/core/execute/ex_stage.sv) 184–185 行
在 EX 保存 CSR 旧值/新值；[`csr_bypass.sv`](../../vsrc/core/csr/csr_bypass.sv)
15–18 行前递显式写入值，但不计入中间指令的退休增量；
[`csr_file.sv`](../../vsrc/core/csr/csr_file.sv) 129–157 行则在 WB 退休时更新计数。
普通 `mscratch` 不会自行变化，这套旁路适用；动态计数器不能直接照搬。
相关计数与执行逻辑在 `3936a52` 已存在，不是 Cache 或 S3 引入。

这不是“读 CSR 恰好差几个周期也正常”：退休计数需要体现本条指令之前的指令序列，
且显式写入应替代本条指令的隐式更新。依据官方
[Zicsr 的 CSR 访问顺序](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)。

建议先仅对 `MINSTRET/MINSTRETH` 访问加入 interlock，等待较老 MEM/WB 指令排空再读；
也可评估动态计数器的独立按序处理边界：对此类访问排空较老指令并
阻止年轻越过，或在 WB 原子完成读改写和 GPR 返回。不要对结果固定加 1/2，也不要
把所有普通 CSR 都改为慢速访问。需覆盖间隔 0/1/多条指令、Load/MDU 等待、连续读写、
异常不计数和 RV32 高低半回绕；先修正后再用其评估 IPC。

## P2：RV32 计数器半宽显式写没有抑制整体退休增量

`csr_file.sv` 134–157 行先对整个 MINSTRET 加一，再覆盖显式写入的半字。
因此写低半时可能保留不应发生的高半进位，写高半时仍保留低半加一。
这是原 CPU 已有的另一项计数器缺陷，不能只修 EX 读取就视为全部解决。

Astra 在 CSR 单元直接复现两种 `write_valid && retire_valid` 情况：

- 原值为 `0x00000000_ffffffff`，写 MINSTRET 低半为 0，得到
  `0x00000001_00000000`，应为 `0x00000000_00000000`。
- 原低半为 0，写 MINSTRETH 时低半变成 1，应保持 0。

修复应先按显式写意图区分“整个计数器不自增”和“正常退休自增”，再合并选中的半字；
不是给高、低两半各自独立做写优先。相应 RV32 高低半与进位测试必须成为正式 unit。
临时源 `/tmp/tb_review_minstret_halves.sv` 捕获两条 `%Error`；即便诊断工具配置使
进程退出码为 0，仍按失败记录。

## 非阻塞整理项与保留的设计

- `core_config_pkg.sv:30` 将 CSR 地址宽度设为 32，但指令 CSR 字段及编码常量是 12 位。
  当前零扩展未构成已复现的运行错误，却扩大 packet 并产生大量 WIDTHEXPAND。
  建议另行统一为 12 位，不与 Cache 功能改动混成一笔大重构。
- `ex_mdu.sv:37` 的注释把 `advance` 描述成结果已消费；实际是 EX 元数据已进入 MEM。
  `sim_imem.sv` 的一处注释颠倒 valid/ready 所属方向；GShare 所称“已提交历史”实际
  是执行解析后的训练，不是 WB 退休历史。后续修改保留说明内容、修正事实，不删除注释。
- 不删除 `mdu_operands_ready`、`issued_q`、MEM/WB 等待和 HOLD 操作数保存。
  它们分别解决操作数就绪、发射去重、结果/访存完成以及旁路消失，不是同一件事。
- 保留六级流水、EX 地址生成、MEM 发请求、WB 接响应。Cache miss 是接口延迟变化，
  不是本轮增加流水级、乱序或 non-blocking LSU 的理由。

## 本轮测试与证据边界

在 rhbyv 当前基线重新执行，默认 `MUL_IMPL=0 DIV_IMPL=0`：

| 命令 | RV32 | RV64 |
|---|---|---|
| `make test XLEN=…` | 42 unit PASS、16 directed PASS、1 SKIP | 42 unit PASS、16 directed PASS、1 SKIP |
| `make riscv-tests XLEN=…` | 58/58 PASS、2 SKIP | 78/78 PASS、2 SKIP |

directed SKIP 是另一位宽的专用测试；Core-only ISA 跳过 `fence_i` 和 `ma_data`。
正式回归输出中的 `PASS … SKIP` 不重复计入有效 PASS。lint 命令成功但仍有 warning，
包括 CSR 宽度扩展、未用信号及由 TB 装载的仿真 IMEM；不称为零告警。

审核新增的 `/tmp` 诊断不是正式回归：IRQ 撤销和 MINSTRET 最小序列分别在两种
XLEN 失败；RV32 半宽显式写有两项失败检查。合计 5 次诊断仿真、6 项失败检查，
没有修复后 PASS。失败用于证实待修缺陷，不以正式套件全绿掩盖。
日志位于 `/tmp/cache-review-core-rv{32,64}.log`、`/tmp/cache-review-isa-rv{32,64}.log`；
临时诊断源为 `/tmp/tb_review_irq_withdraw.sv`、`/tmp/tb_review_minstret.sv`。

本轮未重新运行 SoC 全套、C smoke、CoreMark、完整 MDU ISA 后端矩阵，也未进行形式化、
综合或上板。unit 中包含后端检查，但不等于全 Core 软件已重跑所有后端组合。
未发现其它已复现缺陷不等于证明所有输入序列正确。

## 与 Cache 设计的交接

完整方案见 [S4 Cache 设计](S4_CACHE_DESIGN.md)。推荐顺序是先独立修复并验收上述
CPU 正确性问题，再做 I$ 单元和 SoC 接入，最后加 WT/NWA D$ 与明确的 DMA 契约。
Cache 接入要保持接受一次请求、完成一次响应、原始故障地址和被杀请求排空的约定。

本轮仅记录问题、设计与测试结果，没有修改 RTL/TB/脚本，没有执行修复或提交。
