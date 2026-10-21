# 项目介绍

> 写作约束：[skills/regulation.md](../../skills/regulation.md)。本文给项目目录、参数、环境、仿真和 FPGA 的当前状态，不把规划写成已实现。

## 1. 项目是什么

这是一个面向 RV32 文本 AI 演示的 RISC-V Core/SoC。目标应用是 RT-Thread 上的
文本输入、板上模型推理、文本输出。电脑只提供终端和下载。近期不把 Linux、MMU、
F/V、图像链路作为交付前提。

主要指标：

- 新 P0 先完成 scoreboard 双发射 Core，RV32 完整 SoC 标准 PDS 不低于 85 MHz。
- RV32 统一承担性能优化与标准 PDS；RV64 只验收功能、ISA 和 SoC 仿真，不设独立性能门槛、不做 P&R；本次发布保存 P0，后续优化另开分支。
- 新 P0 已冻结于 r15，主流水 ALU 8 级、Load/DSP 乘法 10 级；标准 PDS 85 MHz 已通过，CMP 作为 7 级 ALU 诊断对照。
- CoreMark/MHz、Fmax 和 CoreMark/LUT 同时记录，后续再继续整体提频。
- 资源效率、外设和 AI 接口单独验收。

## 2. 目录

| 路径 | 内容 |
|---|---|
| `vsrc/core/` | 可移植 Core：frontend、decode、execute、lsu、writeback、csr |
| `vsrc/pkg/` | 类型、地址、配置、总线包 |
| `vsrc/soc/` | Cache、总线、TCM、ROM、DMA、UART/Timer/GPIO |
| `vsrc/cpu/` | FPGA wrapper、Pango DDR 桥 |
| `vsrc/sim_cpu/` | 仿真存储模型 |
| `tb/unit/` | 单元测试 |
| `tb/core/` | Core 定向测试 |
| `tb/soc/` | SoC 定向、Cache、DMA、benchmark |
| `tb/riscv_tests/` | 上游 ISA 测试适配 |
| `scripts/verilator/` | 仿真 runner、模型构建、镜像生成 |
| `scripts/pango/` | PDS 工程准备、校验、时序摘要 |
| `benchmark/` | CoreMark port、裸机 runtime、链接脚本 |
| `ip/pango/` | 板级 DDR IP 配置 |
| `docs/` | 项目介绍、学习、FPGA 适配 |

## 3. 参数

| 参数 | 默认 | 可选 | 含义 |
|---|---|---|---|
| `XLEN` | 32 | 32、64 | 整数宽度 |
| `MUL_IMPL` | 0 | 0、1、2 | DSP、Booth/Wallace、移位乘法 |
| `DIV_IMPL` | 0 | 0、1 | 移位、SRT4 除法 |
| `PREDICTOR_MODE` | 0 | 0、1 | GShare、GShare+Local+chooser |
| `RAS_ENABLE` | 0 | 0、1 | 4 深 RAS 与年龄恢复 |
| `RETIRE_ENTRIES` | 4 | 2、4、8、16 | 唯一退休队列容量 |
| `ISSUE_WIDTH` | 1 | 1、2 | 单发射或对应后端的双发射 |
| `CORE_BACKEND` | legacy | legacy、scoreboard | 旧控制组或新 RAT/scoreboard 双发射 |

新 P0 候选使用 `CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16`，
IQ8、LQ4/SQ4、checkpoint4、p0/r0、DSP/SRT4；C6 已完成双宽功能与固定镜像回归，
RV32 标准 PDS 的 85 MHz 门槛待验证。旧正式性能对照使用 `MUL_IMPL=0 DIV_IMPL=1 PREDICTOR_MODE=1 RAS_ENABLE=1`，
双发射加 `ISSUE_WIDTH=2 RETIRE_ENTRIES=8`。普通 `make` 的 DIV 默认 0，不能把
默认构建写成 DSP/SRT 结果。

SoC 开关：

| 变量 | 默认 | 含义 |
|---|---|---|
| `SOC_CACHE_BLOCK_ENABLE` | 0 | I/D 行走 256 位块通道 |
| `SOC_DMA_WIDE_ENABLE` | 0 | 允许对齐 DDR 段宽搬运 |
| `SOC_DMA_BLOCK_ENABLE` | 0 | 双槽 DMA |
| `SOC_LOCAL_TCM_ENABLE` | 0 | TCM 走局部 hot 路 |

旧板级控制组固定 i1、full、local0、cache_block1、dma_wide1、dma_block1。
新后端按原 RV32 模板保留外围与块口，Core 改为 i2/q16，TCM 固定走原生 bank 路由；
`SOC_LOCAL_TCM_ENABLE` 仅对 legacy 路径有效。

## 4. 环境

- Verilator 5.052。
- RISC-V 工具链 16.1.0，路径由 `RISCV_TOOL_ROOT` 指定。
- Windows PDS 2025.2：`$PDS_HOME\bin\pds_shell.exe`。
- PDS 工程放 `$PDS_WORK_ROOT\work\` 新目录，`reference/` 只读。
- RT-Thread v5.2.2 提交 `ddf52e2cdd977f14fc04035c88672ac204aec713`。

常用命令：

```bash
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make coremark XLEN=32
SOC=1 make soc-coremark XLEN=32
```

RT-Thread 和 UART loader 需要先恢复依赖或用 `RTTHREAD_ROOT` 指向已核验副本。
固定镜像回放用 `COREMARK_REPLAY_DIR=<snapshot>`。

## 5. 仿真性能

当前实测源码为 `core/pipe-lsu-forward-format@dffb8a2`，RV32 四次重放与 ISS
`85ab1ca`、完成预选 `180f6fc` 的 ROI/TB、CRC 和全部计数相同；CMP `2b49c77`
作为联合阶段父对照。p0/r0、DSP/SRT、双发射、ROB16，固定 64 次迭代：

| 分类 | RV32 performance CoreMark/MHz | RV32 validation CoreMark/MHz |
| --- | ---: | ---: |
| M0：Core + 仿真双口存储 | 2.859463363 | 2.843557507 |
| M1：完整 SoC，TCM 执行，DDR 空闲 | 2.494327354 | 2.481332240 |

RV32 228 PASS/5 SKIP（含四次固定重放），RV64 功能 264 PASS/5 SKIP。
RV64 不设置性能验收；M0 两次重放在取消前完成，作附加记录，M1 按用户范围取消。
M1 含 512 MiB DDR 译码、Cache、MMIO、块 DMA 和外设，DDR 模型只为低 64 KiB
分配存储。精确命令、镜像哈希、ROI/TB 周期与日志见工作区 `ITERATIONS.md`，
本轮结果索引为 `logs/pipeline/forward-format-dffb8a2-20261021/summary.json`。
以下双宽数据保留为历史检查点参考：
同镜像对照 `b98f714` 的 M0 为 2.387318/2.099647、M1 为 2.371599/2.087406。
`555453f` 增加 SoC 请求缓冲后，M1 降为 2.142396/1.911813，M0 不变。
ROB 完成到退休分拍的历史检查点 `fdb3ffb`，RV32 综合最差路径为 19 级、13.177 ns。
父检查点 CMP 使用五源两项寄存完成队列和七路操作数广播，完整双宽功能/ISA 及两模式
重放均通过；对 head 的 M0/M1 提升，RV32 为 8.75%/7.45%，RV64 为 16.99%/14.85%。
该版本标准 PDS 为 87.8837 MHz，85 MHz 内部域 STA 通过。CMP 复用 ALU 原结果寄存，LSU/MDU 增加
实际完成边界。`core/pipe-issue-stage` 已加入独立 ISS，并以当前广播捕获、提前分支
解析和 Load 返回提示补偿停顿，完整双宽回归及八次重放通过。相对 CMP 的 M0/M1
提升，RV32 为 9.84%/8.61%，RV64 为 8.59%/7.75%；r13 完整标准 PDS 为 82.8726 MHz、WNS −0.302 ns、86 个 slow setup 失败端点、零未布通，频率验收失败。

DDR 执行与外设并发负载的 CoreMark/MHz 尚未测量。

历史旧后端使用另一组固定镜像，RV32 24 迭代、RV64 22 迭代：

| 检查点 | RV32 CoreMark/MHz | RV64 CoreMark/MHz |
|---|---:|---:|
| `19562a9` 时序基线 | 2.118203 | 1.944208 |
| I1 最终 1/1/4 | 1.710011 | 1.549205 |
| I2 i2/q8 | 1.811039 | 1.627599 |

SoC TCM：

| 阶段 | RV32 | RV64 |
|---|---:|---:|
| 第三轮 ddrreq03 | 2.897145 | 2.579496 |
| 第四轮 fabric04 | 0.844686 | 0.735054 |
| 第十轮 branch10 | 0.839793 | 0.731472 |

这些是仿真周期归一化值，不是板上成绩。Core-only、SoC TCM、DDR/RT 不能混用。

## 6. FPGA 性能

十三轮 PDS 把同域 Fmax 从 39.02/31.16 MHz 提到 84.73/81.85 MHz
（RV32/RV64），最后检查点 `19562a9`。125 MHz 约束下 setup 仍未收敛，
实际 wrapper 仍用 125 MHz。

I2 的 RV32 i1 PDS（2026-10-20）：

| 指标 | 结果 |
|---|---:|
| 同域 Fmax | 65.4279 MHz |
| 125 MHz WNS | −7.284 ns |
| 物理 LUT/FF | 24888 / 20140 |
| DRM36K / APM | 34 / 4 |
| 未布通网络 | 0 |

该轮前 100 条 SoC setup 路径全部从 `reset_sync_q[1]` 出发。后续旧 i1 标准布局
在 85 MHz 约束下得到 92.3306 MHz、WNS +0.934 ns、0 未布通。

新 scoreboard 后端多次标准布局在 EP_DL 内存分配失败，包含默认配置和独立
关闭 LUT 拼合、单元复制、宏优先的尝试。RV32 r8 `fdb3ffb` 综合为 41,793 LUT、
31,682 FF、36 DRM、4 APM、0 latch；源输入与 TCM 初值匹配，r8-route4 已中断。
RV64 已测 r7 `555453f` 综合为 61,614 LUT、44,319 FF、38 DRM、12 APM、
0 latch。r10 `4da04b6` 的 RV32 为 41,824 LUT/31,682 FF，标准 place 完成；
route 第 16 轮 19,459 未布通后停止，没有最终 STA。r10 RV64 只综合，暂停 P&R。
head `14897f1` 的 r11b 标准 PDS 已完成：81.5878 MHz、85 MHz WNS −0.492 ns、
TNS −83.386 ns、644 个 slow setup 失败端点，零未布通；物理 LUT/FF 为
44,082/31,820，其余已报告 STA 无失败。当前 CMP 的 r12 综合为 44,087 LUT、
31,952 FF、36 DRM、4 APM、0 latch；225 项输入及 I/D-TCM 全量初值通过。完整
标准 PDS 得到 87.8837 MHz、85 MHz WNS +0.386 ns、TNS 0、零未布通；slow/fast
setup、hold、recovery、removal、MPW、skew 均零失败。物理 LUT/FF 为
46,457/32,096，最差路径已变为 IQ 读指针到 DSP 乘法，7 级、10.015 ns。
35 个输入与 73 个输出缺 I/O 延迟约束，板级覆盖仍需补齐。
原始命令、报告与内存采样在工作区迭代记录。
完成预选 `180f6fc` 的 r14b 标准 PDS 为 82.7423 MHz、WNS −0.321 ns、TNS −0.759 ns，
5 个 slow setup 失败端点，其余 11 类 STA 零失败，零未布通。物理为 40,954 LUT、
32,318 FF、36 DRM、4 APM。最差路径转为 LSQ Store 覆盖/请求选择，经 Load 格式化、
IQ 旁路到分支接纳，18 级、11.675 ns；该轮频率未通过。
本轮 `dffb8a2` 的 r15 标准 PDS 已完成：**85.2464 MHz、85 MHz WNS +0.034 ns、
TNS 0、零未布通**，12 类 STA 均无失败，57,382 条网络全部布通。物理为
40,154 LUT、32,318 FF、36 DRM、4 APM、77 IO；比 r14b 少 800 LUT，FF 不变。
相对 r14b，Fmax 提高 3.03%；比 CMP 的 87.8837 MHz 低 3.00%。
用户已确认按 8–10 级结构、CoreMark/MHz 不回退和标准 PDS ≥85 MHz 冻结 r15 为新 P0。
CMP 是 7 级 ALU 诊断点，不作为本次冻结门槛。原 `p0-acceptance.json` 保留当时
与 CMP 比频率的失败记录，原始数值和判据没有改写。发布基线为 `publish/p0-r15`，
发布仅含当前 P0 文件的一次提交，不带开发历史；原开发和历史阶段分支全部在
本地保留。后续 RTL 优化从独立分支开展。
r15 最差路径转为 LSQ 地址比较/转发资格/请求选择，经提示标签和 IQ 匹配到分支
下一 PC，19 级、11.183 ns；逻辑/布线 3.588/7.595 ns，最高扇出 76。

综合报告不能作为布线 Fmax，旧 i1 结果不能替代新 P0。Core/SoC/TCM/Cache/MMIO
当前共用 DDR IP 用户时钟，实际 IP 仍为 125 MHz；85 MHz 是这轮 STA 的约束。
没有 bitstream、没有烧板、没有真实 DDR/UART/ILA。

## 7. 功能

Core：

- RV32/RV64 I/M/Zicsr，scoreboard 后端支持顺序前缀双发射、独立完成和按序双退休。
- DSP/Booth-Wallace/移位乘法，SRT/移位除法。
- ROB16、RAT 标签重命名、IQ8；精确异常、机器中断、CSR。
- 分支预测、BTB、GShare/Local/chooser、RAS。
- 双 ALU/AGU、LQ4/SQ4、两个带标签数据口、Store 到 Load 的逐字节转发。
- Store/MMIO 只在队头发起，D$ 同 bank 冲突串行，共享 DDR 填充/写回带宽。

SoC：

- 64 KiB I/D-TCM、Boot ROM、MMIO、错误从机。
- UART0/1、Timer0/1、GPIO0/1/2、IRQ controller。
- DMA legacy 和双槽 block engine。
- 2 路 I$/D$、WB/WA D$、FENCE.I、维护命令。
- 标准 AXI 和 Pango 原生 DDR 桥。
- RT-Thread BSP、UART loader、CoreMark。

AI：

- 目标接口是文本输入、模型推理、文本输出。
- 加速器尚未交付；DMA 和 MMIO 接口先准备。
- 当前先完成顺序双发射 Core 的联合性能验收；C 扩展和乱序发射暂缓，AI 接口单独规划。

## 8. 未来

1. 按 CMP、ISS 完成 8–10 级，每级测 M0/M1 和标准 PDS；CMT 仅在合并已有边界后评估；
   RV32 完整 SoC 达到 85 MHz 且两个指标通过后，再冻结新 P0。
2. 按工作区 `OPTIMIZATION_PLAN.md` 的 P1 至 P6 分阶段优化，每轮复测
   CoreMark/MHz 与 Fmax；保持同域，整体提频受阻后再评估多域时钟。
3. 补 DDR 执行、外设背景负载和资源效率成绩，保留 M0/M1 分项。
4. 恢复 RT-Thread 依赖并完成真实 DDR/UART/ILA、十秒 CoreMark、功耗和 AI 接口。

## 9. 文档

- [学习文档](understand/README.md)
- [FPGA 适配](fpga/FPGA_ADAPTATION.md)
- 工作区根目录：`ITERATIONS.md`、`OPTIMIZATION_PLAN.md`、`HANDOVER.md`
