# hgb-aisystem

RV32 优先的 RISC-V Core/SoC 协作仓库。目标是 RT-Thread 上的文本输入、板上模型
推理、文本输出；RV64 跟随共享架构验证。近期不把 Linux、MMU、F/V、图像链路作为
交付前提。

`CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16` 选择冻结 P0：
RAT 绑定 ROB 标签、IQ8 顺序双发射、两个完整 ALU、共享分支/MDU、LQ4/SQ4 双 AGU，
两个完成口与按序双退休。原生 IF64 和双数据口已接入 SoC；MMIO/Store 受队头许可。
默认 `CORE_BACKEND=legacy` 保留旧 IF→D1→D2→EX→MEM→WB 控制组。

## 当前能力

- RV32/RV64 I/M/Zicsr，精确同步异常、机器中断、CSR、MRET。
- DSP/Booth-Wallace/移位乘法，SRT/移位除法。
- BTB、GShare/Local/chooser、4 深 RAS，正常退休训练。
- 唯一退休队列、tagged 完成、逐源捕获；新后端支持 ROB 标签重命名、双 LSU 与字节转发。
- 64 KiB I/D-TCM、Boot ROM、MMIO、UART0/1、Timer0/1、GPIO0/1/2、IRQ。
- 2 路 I$/D$，WB/WA D$，FENCE.I、维护命令、DMA 所有权交接。
- DMA legacy 和两块 128B 双槽引擎，256 位 DDR 口，读写可重叠。
- 标准 AXI 与 Pango 原生 DDR 桥；RT-Thread BSP、UART loader、CoreMark。

## 当前状态

P1.1a 候选位于 `core/p1-1a-split-lq-sq`，起点为已合入的 `main@094443e`。
`load_queue.sv` 和 `store_queue.sv` 分别持有描述符、状态和完成数据，
`load_store_queue.sv` 负责外部双端口仲裁与锁定。保持 ROB16/IQ8、按序发射、
Store/MMIO 队头许可和 8/10/10 级边界；新增与 P0 LSU 原实现的逐周期比较入口
`bash scripts/verilator/run_lsq_equivalence.sh 32`，RV64 同入口替换位宽。
完整仿真已完成：RV32 231 PASS/5 SKIP，RV64 267 PASS/5 SKIP，包含双宽各五项
P0 LSU 差分；RV32 四次 M0/M1 同镜像比较的周期、CRC 和全部统计保持。
同镜像入口为 `scripts/verilator/compare_coremark.py`，新镜像使用 GCC 11.4，
M0/M1 为 2.633659/2.317931 CoreMark/MHz，不能与下文 GCC 16.1 历史镜像混算。
DDR IP 已生成，32/32 DQ 元数据匹配；完整 SoC 的 228 项暂存输入已校验。
P1.1a 标准 PDS 已完成：86.1721 MHz、85 MHz WNS +0.160 ns、TNS 0，12 类 STA
零失败，57,149 条网络全部布通；物理为 40,181 LUT、32,188 FF、36 DRM、4 APM。
最差路径仍经 Store 地址、转发和 IQ 到分支，20 级、11.135 ns；结果绑定源码 `a23b65c`，
记录为 `logs/p1/p1-1a/pds-result.json`。85 MHz 为内部 STA，未上板。
`core/p1-1b-rob32-split-iq@f547da3` 使用 ROB32 和 int8/mem4 IQ，保持按序发射；
显式选择为 `RETIRE_ENTRIES=32 SPLIT_ISSUE_QUEUE=1`。完整回归为 RV32 228 PASS/5 SKIP、
RV64 264 PASS/5 SKIP，M0/M1 同镜像 performance 为 2.635803/2.335916 CoreMark/MHz。
标准 PDS 尚未完成，原始命令和逐项哈希在 `logs/p1/p1-1b-drain/regression/summary.json`。
P1.2 在 `core/p1-2-limited-integer-ooo` 开发。增加 `LIMITED_INTEGER_OOO=1` 时，
整数 IQ 按完整标签保存操作数、选择最老就绪项；访存保持 FIFO，CSR/系统指令保留屏障。
忙 MDU 留在 IQ，独立 ALU 可继续推进；ROB 仍按序退休。双宽各三项定向通过，
Core 各观察到 30 次越过阻塞整数项。
精确顺序修正后仅 ALU/MDU 可越过等待项，访存/分支保持接纳顺序及合法同拍配对。
精确事件增至十场景，原未对齐超时已解决，Core ISA 为 RV32 58 PASS/2 SKIP、RV64 78 PASS/2 SKIP。
`5963d72` 完整回归为 RV32 229 PASS/5 SKIP、RV64 265 PASS/5 SKIP，四次同镜像比较通过。
M0/M1 为 2.670535/2.378539 CoreMark/MHz，较重建 P0 提高 1.4002%/2.6147%；
参数、命令、源码及镜像哈希为 `logs/p1/p1-2-precise/regression/summary.json`。
P1.3 开发分支为 `core/p1-3-iq-forward-timing`，正在比较并行年龄选择及四种
`SCHEDULER_FORWARD_MODE`，四模式双宽定向各 17 PASS/0 SKIP，完整测量待完成；
模式说明见 [双发射](docs/understand/DUAL_ISSUE.md)。P1.1b 中间布线严重拥塞，已主动终止，未记作时序通过。
以下 r15 数值为历史 P0 记录。

新 P0 发布基线为 `publish/p0-r15`，实测 RTL 为 `dffb8a2`；原开发分支
`core/pipe-lsu-forward-format@5fa11fb` 和本地发布准备分支 `baseline/p0-r15@6d92659`
保留。冻结依据与后续计划见工作区三个交接文档。
四个 Load 槽先格式化转发值，再选择两个输出；提示有效位与载荷分离，原资格、
取消、返回优先级和请求/完成时点保持。主流水 ALU 为 8 级，Load/DSP 乘法为 10 级。
RV32 为 228 PASS/5 SKIP，M0/M1 为 **2.859463/2.494327 CoreMark/MHz**；四次
固定重放的周期、CRC 和全部计数与 r13/r14b 一致。比 CMP 分别高 9.84%/8.61%，
比拆分起点高 19.45%/16.70%。RV64 功能为 264 PASS/5 SKIP，跟随共享 RTL，
不设置独立性能门槛、不做 P&R；取消前完成的 M0 两次重放只作附加记录，M1 已取消。

本轮 `dffb8a2` 的 r15 标准 PDS 已完成：**85.2464 MHz、85 MHz WNS +0.034 ns、
TNS 0、零未布通**，12 类 STA 均无失败，57,382 条网络全部布通。物理为
40,154 LUT、32,318 FF、36 DRM、4 APM、77 IO；比 r14b 少 800 LUT，FF 不变。
相对 r14b，Fmax 提高 3.03%；比 CMP 的 87.8837 MHz 低 3.00%。
用户已确认按 8–10 级结构、CoreMark/MHz 不回退和标准 PDS ≥85 MHz 冻结 r15 为新 P0。
CMP 是 7 级 ALU 诊断点，不作为本次冻结门槛。原 `p0-acceptance.json` 保留当时
与 CMP 比频率的失败记录，原始数值和判据没有改写。发布基线为 `publish/p0-r15`，
发布仅含当前 P0 文件的一次提交，不带开发历史；原开发和历史阶段分支全部在
本地保留。后续 RTL 优化从独立分支开展。
源码、固定镜像和同源结果索引为 `logs/pipeline/forward-format-dffb8a2-20261021/`；
详细分类、周期、跳过项与物理证据见双发射和 FPGA 文档。Core/SoC 用户侧共用时钟，
IP 仍为 125 MHz，本轮为 85 MHz 内部 STA 约束检查；35/73 项 I/O 延迟缺失，未上板。
旧控制组为 `perf/coremark-baseline@53b7ee9`，端口默认值问题已在 `c04c588` 修复。

历史 RV32 PDS（i1、full、local TCM 0、块口全开）：

- 同域 Fmax 65.4279 MHz，125 MHz WNS −7.284 ns。
- 物理 LUT/FF 24888/20140，DRM36K 34，APM 4，0 未布通。
- 前 100 条 SoC setup 路径全部从 `reset_sync_q[1]` 出发，复位网是首要物理问题。

后续同配置标准布局与复位树修正后，85 MHz 约束检查得到 Fmax 92.3306 MHz、
WNS +0.934 ns、0 未布通。这个 i1 结果不能作为新 scoreboard 后端的频率。

CoreMark：

| 检查点 | RV32 | RV64 |
|---|---:|---:|
| `19562a9` Core-only | 2.118203 | 1.944208 |
| I1 Core-only | 1.710011 | 1.549205 |
| I2 i2/q8 Core-only | 1.811039 | 1.627599 |
| C2 scoreboard i2/q16 单 LSU Core-only，64 次迭代 | 2.111139 | 1.892827 |
| C6 `b98f714` 双 LSU，M0 Core-only，64 次迭代 | 2.387318 | 2.099647 |
| C6 `b98f714`，M1 完整 SoC-TCM，64 次迭代 | 2.371599 | 2.087406 |
| `555453f` 请求缓冲，M1，同一固定镜像 | 2.142396 | 1.911813 |
| `fdb3ffb` 寄存退休，M0，同一固定镜像 | 2.393948 | 2.092062 |
| `fdb3ffb`，M1，同一固定镜像 | 2.137354 | 1.896438 |

新候选使用 p0/r0、DSP/SRT，固定镜像与原始日志见 `docs/understand/DUAL_ISSUE.md`
和工作区 `ITERATIONS.md`。M1 保留 DDR3、MMIO、DMA 等完整硬件，程序和数据在
TCM，DDR 空闲。DDR 执行和外设背景负载成绩尚未测量。Core-only、SoC-TCM、
DDR/RT 分开记录；不同迭代数、预测参数或镜像的历史成绩不作严格同条件增幅比较。
`fdb3ffb` 另将 ROB 完成到退休的路径分拍，双宽整核保持 129 拍连续双退休；
RV32 综合最差路径从 29 级、19.389 ns 降至 19 级、13.177 ns；
该历史检查点的标准 PDS 布线已中断，未冻结为 P0。

## 文档

- [项目介绍](docs/PROJECT_INTRO.md)：目录、参数、环境、仿真、FPGA、功能。
- [学习文档](docs/understand/README.md)：SoC、双发射、DDR/AXI、FPGA、优化五块。
- [FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)：PDS 流程、时序、资源、板级边界。
- 工作区根目录：`ITERATIONS.md`、`OPTIMIZATION_PLAN.md`、`HANDOVER.md`。

所有 Markdown 按 `../skills/regulation.md` 写。`docs/COMMIT.md` 不再存在。

## 快速验证

```bash
export RISCV_TOOL_ROOT=<toolchain-bin>
export MUL_IMPL=0 DIV_IMPL=1 PREDICTOR_MODE=1 RAS_ENABLE=1 RETIRE_ENTRIES=4
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make coremark XLEN=32
SOC_CACHE_BLOCK_ENABLE=1 SOC_DMA_WIDE_ENABLE=1 SOC_DMA_BLOCK_ENABLE=1 \
  SOC_LOCAL_TCM_ENABLE=1 make soc-riscv-tests XLEN=32
bash scripts/verilator/run_dma_block.sh 32
```

普通 `make` 的 DIV 默认 0、ISSUE 默认 1。正式对照使用 DSP/SRT、Tournament/RAS；
双发射加 `ISSUE_WIDTH=2 RETIRE_ENTRIES=8`。RT-Thread 需要先恢复 v5.2.2 依赖或用
`RTTHREAD_ROOT` 指向已核验副本。

新后端验证使用 `CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16 DIV_IMPL=1`；
`bash scripts/verilator/run_scoreboard.sh 64` 与 `run_scoreboard_soc.sh 64` 验证模块，
换为 32 验证另一位宽。旧性能表的预测配置与新 P0 的 p0/r0 物理模板分别记录。

## 边界

- 没有真实 DDR/UART/ILA、bitstream、烧板、十秒 CoreMark 或功耗。
- 125 MHz setup 未收敛，工具 Fmax 不是板上频率。
- 没有硬件 Cache 一致性；DMA 需要软件 clean/flush/invalidate。
- 每个 D$ bank 的 miss 阻塞；跨 bank 可独立排队，共享外部填充/写回带宽。
- AI 加速器尚未接入。
