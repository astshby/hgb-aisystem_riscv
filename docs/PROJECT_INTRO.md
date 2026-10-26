# 项目介绍

> 写作约束：[skills/regulation.md](../../skills/regulation.md)。本文给项目目录、参数、环境、仿真和 FPGA 的当前状态，不把规划写成已实现。

2026-10-27 用户确认新开发基线为 **`baseline-rv32-soc-npu-20261027`**：采用
`ec85d36` 的代码树，包含 `aaf63f9` 地址递增，保留 ROB16/四平台/第五 NPU 时钟域。
本次以单个汇总提交发布选定快照，原阶段提交和比较分支保留在开发者本地；下文的
`aaf63f9`、`e1598be`、`6cb7535` 用于关联本机原始测量，并非本次上传的实验分支。
GitHub 交付代码、配置、测试和报告摘要；原始 ELF/HEX、日志、PDS/IP 工程仍在本地，
新环境按文中命令重建，不能直接逐字重放旧生成物。旧基线 `baseline-rv32-soc-20261025`
保留。本次冻结只更新基线说明，生产 RTL、软件和测试与选定快照一致。

2026-10-27 系统路径继续优化后选择 `soc/tcm-stream-address@aaf63f9`，Core/package
90 份源文件与 `6cb7535` 相同，正常 ALU/Load/DSP 仍为 8/10/10，C 尚未实现。
AXI 从口保存当前 beat 起址，在 beat 完成时递增，请求路径省去编号移位和一次加法。
24 项四层短 CoreMark 的 ELF/HEX、周期和 CRC 均与下述 `6cb7535` 结果一致。
两项当前模型也各重放真实 TCM 64 次，21,227,090/21,358,999 拍，
3.015015/2.996395 CoreMark/MHz；与原候选同镜像/CRC/周期。结果在各自
`build/{soc-tcm-stream,soc-tcm-decode}/20261026-long64/results/`，正式十秒成绩仍未测得。

| 完整 SoC+NPU 域 | 目标 MHz | 当前综合 Fmax MHz | WNS ns |
|---|---:|---:|---:|
| Core | 100 | 89.3096 | −1.197 |
| SYS | 80 | 83.8926 | +0.580 |
| DDR user | 125 | 144.6969 | +1.089 |
| periph | 25 | 89.0076 | +28.765 |
| NPU | 100 | 112.3343 | +1.098 |

总资源 71,659 LUT/66,825 FF/162.5 DRM/86 APM，0 latch。相对 `6cb7535`，Core/NPU
估计频率 +2.295%/+5.021%，LUT −152、FF +10（+0.015%）；其他域估计上限略降，
仍高于对应目标。Core 最差已转到 Store valid→转发覆盖→双口选择→Load state，
18 层、扇出 44。100 MHz 的整机 Core 目标尚未满足；CDC/PHY/I/O 仍需物理验收。

比较分支 `soc/tcm-local-decode@e1598be` 复用专用 TCM 译码，同样通过完整仿真，
Core 达 90.9835 MHz；但总 LUT 72,265，比选定单项多 606、高于 `6cb7535` 454，
因此未采用。两分支和报告保留。双宽回归：`make test` 各 82 PASS/2 SKIP，Core ISA
58/78 PASS、各 2 SKIP，SoC ISA 59/79 PASS、各 1 SKIP，整机各 5 PASS，smoke 各
1 PASS；AXI 为 12/14 PASS、无 SKIP，四层功能各 4 PASS。专用译码另有双宽各
14,176 个地址/权限检查通过。RV64 不测 CoreMark/PDS，本轮未运行 P&R。

两项证据分别在 `build/{soc-tcm-stream,soc-tcm-decode}/20261026-a/` 和
`logs/{soc-tcm-stream,soc-tcm-decode}-20261026/`；模型和源码收据逐一匹配各自提交。
原生工程在 `$PDS_WORK_ROOT/work/soc-tcm-stream-20261026/{pointer-a,local-decode-a}/`，
两次启动前物理/提交余量均 ≥6 GiB。原始镜像、日志和 PDS 报告未随 Git 发布。
核级 Core+TCM 的 104.7120 MHz 仍引用下面 `6cb7535` 的综合结果，当前两项未重跑
核级综合；第二、三层也未补测本轮综合，不能使用旧分支频率替代。

以下为本轮继承的 `6cb7535` 联合候选及原基线数据；各项按标明的版本阅读。

2026-10-26 的联合候选为 `core/lsu-shared-age-rob16`，保留 `main@a84ab1a` 和 ROB32
比较分支。采用分配沿提前提交 Load、共享年龄矩阵、只读第二口写载荷裁剪和 MDU FU
直接路由，仿真/综合入口共同选择 ROB16、int8/mem4、LQ4/SQ4、RAS0、OOO0、forward3。
结构仍按 ALU/Load/DSP 的 8/10/10 级记录，减少的是分配后的请求等待，未新增 C 扩展。

真实 Core+TCM 标准综合为 **104.7120 MHz、WNS +0.450 ns**，26,400 LUT、19,663 FF、
32 DRM、4 APM、0 latch。相对原真实 TCM 基线：频率 +8.115%、LUT −17.197%、FF −23.654%。
同一 GCC 16.1.0、O2、rv32im_zicsr、2000 B、2 次迭代冻结镜像的结果如下：

| 场景 | performance 周期 / CoreMark/MHz | validation 周期 / CoreMark/MHz |
|---|---|---|
| 四组各自 TCM 驻留 | 663,794 / 3.012983 | 667,943 / 2.994267 |
| 片上 TCM + DMA/IRQ | 766,375 / 2.609688 | 773,010 / 2.587289 |
| DDR cold | 836,970 / 2.389572 | 842,413 / 2.374132 |
| DDR warm | 831,765 / 2.404525 | 837,329 / 2.388547 |
| DDR + DMA/IRQ | 957,051 / 2.089753 | 964,263 / 2.074123 |
| DDR + DMA/IRQ + NPU | 1,316,595 / 1.519070 | 1,327,930 / 1.506103 |

四平台共 24 PASS，Core+TCM performance 比原基线提高 10.564%；validation 为
2.994267，尚不足 3。以上为短仿真，未构成正式十秒 CoreMark 成绩。旧 M0 一周期
TB 存储另列：固定 64 次 18,148,201/18,249,159 拍，3.526520/3.507011 CoreMark/MHz。
ROB16 相对提前请求的 ROB32 候选略损失 TCM/M0 吞吐，NPU 背景成绩也低于该分支的
1.579361；与原基线及 NPU 初始接入版本比较，各场景均提高。保留两种容量供后续选择。

真实 TCM 另做同镜像 64 次对照，保持 O2、2000 B 及相同软硬件接口：

| 版本 | performance 周期 / 每 MHz | validation 周期 / 每 MHz |
|---|---|---|
| 原 ROB32 基线 | 23,492,612 / 2.724261 | 23,717,958 / 2.698377 |
| 当前 ROB16 候选 | 21,227,090 / 3.015015 | 21,358,999 / 2.996395 |

performance 提高 10.673%，validation 提高 11.044%。两版本 ELF/HEX 哈希相同，旧基线
使用已保存且验过哈希的仿真器。候选计时区约 0.212/0.214 秒，仍未满足正式十秒规则；
validation 仍不足 3。该结果与上面的 2 次迭代、旧 M0 一周期存储结果分别记录。

双宽四平台功能各 4 PASS，LSU 定向各 4 PASS，配置/暂存工具 117 PASS；完整双宽
回归通过：`make test` 各 82 PASS/2 SKIP，Core ISA 为 58/78 PASS（各 2 SKIP），
SoC ISA 为 59/79 PASS（各 1 SKIP），整机各 5 PASS，smoke 各 1 PASS。ROB16 容量专项
各 6 PASS，覆盖年龄回卷、重命名、恢复、退休和异常/IRQ。RV64 不运行 CoreMark/PDS。

完整 SoC+NPU 匹配标准综合也已完成：Core/SYS/DDR-user/periph/NPU 同域 Fmax 为
**87.3057/83.8997/144.7387/89.2698/106.9633 MHz**，目标仍为 100/80/125/25/100 MHz。
资源为 71,811 LUT、66,815 FF、162.5 DRM、86 APM、0 latch。Core 最差为 AXI 写地址
生成→TCM 译码/仲裁→BRAM ADDRA，20 层、扇出 51，100 MHz 下 WNS −1.454 ns；
核级 104.7120 MHz 不能作为整机频率。原 CDC 端点绑定、DDR/PHY hold 和 I/O 待办
继续保留。NPU 实际工作短测在 ROI 内完成 32/33 个任务、核对 131/132 个输出向量，
错误 0；包含 CPU Timer 服务成本。详细五域表见[FPGA 适配](fpga/FPGA_ADAPTATION.md)。

未做本轮布局布线。证据在 `build/core-lsu-rob16/20261026-a/`、
`logs/core-lsu-rob16-20261026/` 和 `logs/npu-integration-20261026/`，
原生核级工程 `$PDS_WORK_ROOT/work/core-tcm-20261026/admit-rob16-b/`；源文件、参数、
ELF/HEX、命令和日志哈希由收据保存。合体工程为同根 `rob16-soc-npu-b/`，核级和合体
摘要分别为 `core-tcm-rob16-synthesis.json`、`soc-npu-rob16-synthesis.json`。64 次
镜像/结果在 `build/core-lsu-rob16/20261026-long64/`，旧基线结果在同根
`20261026-long64-baseline/`。本地生成物未随 Git 发布。

以下 NPU 初始接入与 2026-10-25 基线结果按各自版本阅读。

2026-10-26 新分支 `soc/npu128-five-domain` 从下面的固定基线继续，加入第四组
`soc_npu`，Core 保持原样。NPU 引用 YOLO-accelerate `47ffb55` 的 128-MAC/分级 MMIO，
通过 AXI/CDC 独立挂载，初始第五域为 100 MHz，原四域仍为 100/80/125/25 MHz。
RV32/RV64 的 CPU 配置、DDR→DMA→NPU 装载及结果读回、两组有符号卷积通过；
跨域专项各 4 PASS，覆盖同频、100/125/约 90 MHz NPU、背压、字节选通和协调复位。

第四组短 CoreMark 双模式 10 PASS：NPU 空闲的 TCM/cold/warm/DDR DMA 场景与原基线
周期完全相同。额外 NPU+DDR DMA/IRQ 场景 performance/validation 分别为
1,388,742/1,403,362 周期、1.440152/1.425149 CoreMark/MHz；计时区内分别完成
34/35 个驻留 4×1、Ci8/Co16 卷积任务，核对 138/140 个输出向量，无数值错误。
该场景包含 CPU 在 Timer 中断里轮询、核对并释放输出槽的开销；NPU 没有直接 IRQ。
AXI 仿真 RAM 仍不含 DDR3 PHY/刷新时延，不将此分数称为板上推理吞吐。
NPU 80/125 MHz 两模式另有 4 PASS，performance 为 1.429957/1.445360；小任务的
收益主要受 Timer 轮询服务限制，先保留独立 100 MHz，125 MHz 不作物理频率承诺。
合体标准综合完成：Core/SYS/DDR/periph/NPU 分别为
84.4309/83.9067/144.7387/85.2806/105.7753 MHz，NPU 在 100 MHz 目标下 WNS +0.546 ns。
总资源 79,328 LUT/73,146 FF/162.5 DRM/86 APM；0 latch。未做合体布局布线，原
CDC、PHY hold、I/O delay 待办保留，详细结果见 [FPGA 适配](fpga/FPGA_ADAPTATION.md)。

新授权的候选允许最长正常流水 ≤12、可试 C 扩展，真实 Core+TCM 目标为
CoreMark/MHz >3 与标准综合 >100 MHz。两项指标及 LUT/FF/DRM/APM 同配置比较；
当前正式 Core 尚未增加流水或 C 扩展。隔离候选虽达 3.026465/MHz，但标准综合
81.4067 MHz、LUT +90，未采纳。旧 M0 64 次镜像已重放，周期仍为
20,307,247/20,452,186，3.151584/MHz；双宽功能合计 222/262 PASS、各 5 SKIP，
工具 187 PASS；本轮没有 RV64 CoreMark。原三组完整数据与固定基线如下。

2026-10-25 最新开发基线为 `baseline-rv32-soc-20261025`，测量实现来自
`bench/unified-coremark-three-platforms@7449fe7`、Core 来自 E0u `9a7edd1`。
基线补齐已用于原生综合的 C1/C4 暂存脚本、参数核验和配套测试，三套可运行平台
使用同一配置清单。Core 保持 RAS0/OOO0、ROB32、int8/mem4、forward3、Tournament1，
正常流水 ALU/Load/DSP 仍为 8/10/10。当前四域目标是 100/80/125/25 MHz，
DDR 125 MHz 为控制器用户接口时钟；现有 DDR IP 配置为 1000 Mb/s，不能把用户接口
时钟当作 DDR3 器件 CK 或 CPU 频率。

| 配置 | TCM/Cache/DDR | 活跃时钟域 | 软件场景 |
|---|---|---|---|
| `core_tcm` | 生产 64+64 KiB TCM，本地 Boot ROM，无 Cache/DDR | Core | TCM |
| `soc_tcm` | TCM、AXI、ROM、DMA、MMIO/IRQ，DDR FIFO 裁剪 | Core/SYS/periph | TCM、片上 DMA/IRQ |
| `soc_ddr` | TCM、4 KiB I$ + 4 KiB D$、完整总线、DDR | Core/SYS/DDR/periph | TCM、DDR cold/warm、DMA/IRQ |

三组相同 TCM 镜像的 2 次迭代 performance 均为 733,915 周期、2.725111 CoreMark/MHz；
DDR cold/warm 为 2.184639/2.197375，背景 DMA/IRQ 为 1.909776。双模式 14 项通过，
另有单域改频 16 项通过；均为短仿真测量。DDR 仿真使用 256 KiB AXI 验证 RAM，
硬件译码 512 MiB；第三组 PDS 包含真实 DDR 控制器/PHY，本轮只做综合、不做 P&R。
旧 M0 约 3.15 采用一周期内存，不能直接与真实 TCM 的 2.725111 计算回退。

RV32 使用 GCC 16.1.0、`-O2 -march=rv32im_zicsr -mabi=ilp32`、2000 字节工作数据。
目标频率下的完整双模式记录如下，performance 每秒成绩按仿真 Core 100 MHz 计算：

| 软件场景 | performance 周期 / 每 MHz | validation 周期 / 每 MHz | performance 仿真每秒成绩 |
|---|---|---|---:|
| 三组各自 TCM 驻留 | 733,915 / 2.725111 | 741,695 / 2.696526 | 272.511122 |
| 片上 DMA/IRQ | 838,844 / 2.384234 | 847,028 / 2.361197 | 238.423354 |
| 完整组 DDR cold | 915,483 / 2.184639 | 923,125 / 2.166554 | 218.463915 |
| 完整组 DDR warm | 910,177 / 2.197375 | 917,508 / 2.179818 | 219.737480 |
| 完整组 DDR + DMA/IRQ | 1,047,243 / 1.909776 | 1,057,023 / 1.892106 | 190.977643 |

标准综合估计如下，Fmax 单位 MHz、WNS 单位 ns；三组均为 0 latch：

| 配置 | Core Fmax / WNS | SYS Fmax / WNS | DDR 用户口 Fmax / WNS | periph Fmax / WNS | LUT / FF / DRM36K / APM |
|---|---|---|---|---|---|
| Core+TCM | 96.8523 / −0.325 | 不适用 | 不适用 | 不适用 | 31,883 / 25,755 / 32 / 4 |
| 片上 SoC | 91.7600 / −0.898 | 86.1104 / +0.887 | 不适用 | 97.6467 / +29.759 | 52,918 / 45,759 / 32 / 4 |
| 完整 DDR3 SoC | 84.4523 / −1.841 | 84.8104 / +0.709 | 144.7178 / +1.090 | 90.9835 / +29.009 | 67,266 / 60,633 / 36 / 4 |

三组使用同一 Core RTL，顶层的端口裁剪、负载、时钟源和最差路径不同，不能把核级
96.8523 MHz 当作完整 SoC 频率。完整组最差为 ISS→分支恢复→取指响应→TCM 仲裁/
BRAM WEA，22 层、扇出 86；原始 CDC 约束绑定、部分 DDR/PHY hold 和 I/O delay
仍需完成。尚无此基线的布线 Fmax、未布通数或板级结果，历史 P0 r15 的
85.2464 MHz 保留为独立物理验收点。

双宽功能回归含新三组平台：RV32 220 PASS/5 SKIP、RV64 260 PASS/5 SKIP。
基线发布时，统一测量、Pango 暂存/内存/时序摘要和分层参数工具检查共 201 PASS/0 SKIP。
旧 M0 64 次固定镜像两模式再次通过，周期为 20,307,247/20,452,186，performance
3.151584；RV64 不测 CoreMark，不做 P&R。短 CoreMark、综合和板级验收分别记录。
原始仿真命令、RTL/ELF/HEX/仿真器哈希在本地
`build/unified-coremark/20261025-b/{models,results}`，固件在 `20261025-a/firmware`；
固件 manifest SHA256 为 `b4c4ac5a3d436e04812bb6100636aeaebee80901937e8c5e47bea58bad09637d`，
TCM performance ELF SHA256 为 `5399ae505be47bc16ee75578e214b5625e735a9506a8f35637210b7968421573`。
原生工程在 `$PDS_WORK_ROOT/work/unified-coremark-20261025/`，综合摘要及回归日志在
`logs/unified-coremark-20261025/`。这些镜像、工具生成物和日志不随 Git 交付；新环境
按下列入口及相同工具链重新构建，测得的分数必须附自己的镜像哈希。

`scripts/benchmark_platforms.json` 是共用配置。运行示例：

```bash
make coremark-platforms COREMARK_PLATFORM_OUT=build/unified-coremark/new-run
make coremark-platforms XLEN=64 COREMARK_PLATFORM_OUT=build/unified-coremark/rv64-functional \
    COREMARK_PLATFORM_ARGS="--functional"
python3 scripts/verilator/run_unified_coremark.py --output build/unified-coremark/clock-sweep \
    --bundle build/unified-coremark/new-run/firmware --platforms soc_ddr \
    --clocks core80 sys100 ddr100 periph50 --modes performance
python3 scripts/pango/prepare_benchmark.py --platform core_tcm \
    --output "$PDS_WORK_ROOT/work/paired-core-tcm" \
    --bundle build/unified-coremark/new-run/firmware \
    --sim-receipt build/unified-coremark/new-run/models/core_tcm-target-rv32/build.json
```

`soc_tcm` 同样提供对应 receipt；`soc_ddr` 还需要 `--ip-dir` 指向生成的 `ddr3_test`。
PDS 暂存将相同 TCM ELF/HEX 拆成两 bank 初始化，并核对仿真/综合源码哈希。
`benchmark_synthesize.tcl` 在每组综合前检查 Windows 物理/提交余量各至少 6 GiB。
完成后用 `scripts/pango/summarize_benchmark.py <工程目录> --output <结果.json>` 收集
资源、各时钟域综合估算、存储裁剪和最差路径；未布通数与布线 Fmax 仍为未测。
DDR 原生 C1/C4 时钟候选保留，core80/ddr100/periph50 只属于仿真扫频。
CoreMark/MHz 统一按 Core 周期计算；不同域只能通过 CPU 的等待、争用、中断开销
改变结果。每秒成绩必须用同次运行的实际 Core 频率，不能拼接另一频率比例下的分数。

以下为 2026-10-23 的 `soc/p2-p3-clock-study` 快照，从B19 `0501f10` 推进P2/P3步骤1–3，
生产RTL为 `1a4f8fa`。远端P1 Core固定，新增I-cache宽安装候选、分域时钟发现/BSP、
独立GPLL与DDR协调恢复，并补齐持续DMA、IRQ-only/DMA-only和W源等待观测。
当前为RTL/软件/仿真候选，标准PDS与板级启动尚未执行，85MHz仍待当前树验收。
保存点 `baseline/p2-before-p1-20261023@f2b33b4`、B19分支与原本地历史均保留。

Core、TCM和Cache命中仍共域。C1为Core/SYS/DDR/periph=100/80/125/25MHz，
C4只将SYS提高为100MHz。I-cache默认安装4字节，候选显式选择8字节；32B行安装
尾部9→5Core拍，IF64命中II=1。M1队列及生产DMA未改，已有等待分别归因于同bank
争用、AW到首W固定一拍及下游反压。软件频率发现、程序布局和复位见
[SoC系统](understand/SOC_SYSTEM.md)，PLL/物理准备见[FPGA适配](fpga/FPGA_ADAPTATION.md)。

RV32仍用GCC16.1冻结镜像，M0/M1各两种模式与B19周期一致；M1四组合都没有
DDR、MMIO、DMA或Cache refill。M2两种安装宽度×C1/C4×cold/warm/background×
两模式×i2/i64的48模式联合矩阵全部通过。

| 层次 | C1 fill4 基线 | C1 fill8 候选 | C4 fill4 对照 | C4 fill8 候选 |
| --- | ---: | ---: | ---: | ---: |
| M0 Core-only | 3.237325 | 3.237325 | 3.237325 | 3.237325 |
| M1 SoC-TCM | 2.797692 | 2.797692 | 2.797692 | 2.797692 |
| M2 cold | 2.246406 | 2.254766 | 2.254507 | 2.263539 |
| M2 warm | 2.246827 | 2.255064 | 2.254787 | 2.263801 |
| M2-B DMA/IRQ | 1.949692 | 1.958627 | 1.971318 | 1.980001 |

数值为64次迭代performance的CoreMark/MHz。M0控制组独立重放两模式一次，
其余列复用该不变Core结果；M1四组合均实跑两模式。C1/C4的Core均为100MHz，
仅SYS为80/100MHz，DDR125/periph25MHz保持。

M2 cold在C1下提高0.372%，C4下提高0.401%；M2 warm在C1下提高0.367%，C4下提高0.400%；M2-B DMA/IRQ在C1下提高0.458%，C4下提高0.440%。

M0/M1控制10模式、旧binary C4长测6模式、观测关闭4模式另列，共68次独立运行；
新fill4与同钟旧模型等周期，fill8与同钟fill4两模式均无回退。

CoreMark/MHz只除以Core周期，四域Hz单独记录；仿真周期不代表FPGA Fmax。
64次迭代的实际持续时间不足10秒，虚拟1MHz打印不作为正式十秒成绩。M2-B继续
按100μs绝对期限触发；程序变快时IRQ/DMA次数自然减少。TCM/DDR预装基准不代表
生产Flash loader已完成。与B19的M1对照保留CLOCK_HZ/UART和DDR模型参数差异，
无MMIO/DDR访问支持ROI比较，不声称全部elaboration参数相同。

双宽通用回归为RV32 233 PASS/5 SKIP、RV64 272 PASS/5 SKIP，另两项lint；
双宽整机/时钟软件20次、独立启动/恢复4次、Cache安装及兼容65次通过。
W观测器14项、DMA连续8次、IRQ/DMA软件8次、观测开关CoreMark4次通过。
工具111项、Pango规划/暂存46项、wrapper展开20次、厂商PLL/复位3项通过。
持续DMA在当前DDR模型下测得SYS80/100为519.20/615.85MB/s，按独立负载单列。

RT-Thread双宽smoke与CoreMark应用4个镜像编译通过；完整RT运行0PASS/2未完成：
原 `tb_soc_benchmark.sv`/`tb_rt_thread.sv` 引用旧 `soc_top` 层级，RV32构建失败，
RV64同因未启动。裸机时钟软件已运行通过，RT调度器运行仍需后续测试台适配。
RV64本轮只验功能，没有RV64 CoreMark或P&R。

结果、精确命令、源码/ELF/HEX/binary哈希在 `logs/p2/joint-step3-20261023/`。
固定镜像需要本地 `build/frozen/p0-c6-m{0,1}-rv32/` 与
`build/frozen/p2-step1-{i2,i64}-20261022/`；这些生成资产及日志不随Git交付。
主要复现入口如下，示例另选日志目录；I-cache和CoreMark同时另选构建目录，
clock-contract按XLEN/profile复用构建目录。重复运行时给新日志换名：

```bash
source scripts/verilator/p1_core_config.sh
ICACHE_INSTALL_LOG_ROOT=logs/p2/replay-icache32 ICACHE_INSTALL_BUILD_ROOT=build/p2/replay-icache32 \
  bash scripts/verilator/run_icache_install_width.sh 32 8
ICACHE_INSTALL_LOG_ROOT=logs/p2/replay-icache64 ICACHE_INSTALL_BUILD_ROOT=build/p2/replay-icache64 \
  bash scripts/verilator/run_icache_install_width.sh 64 8
P2_LOG_ROOT=logs/p2/replay-clock32 bash scripts/verilator/run_soc_clock_contract.sh 32
P2_LOG_ROOT=logs/p2/replay-clock64 bash scripts/verilator/run_soc_clock_contract.sh 64
python3 scripts/verilator/run_p2_coremark.py --replay build/frozen/p2-step1-i64-20261022 \
  --sim build/p2/b20-replay-c1-if8/Vtb_soc_system --build-sim --expect-core-profile p1 \
  --clock-profile 1 --clocks 1 --icache-fill-bytes 8 --log-root logs/p2/b20-replay-c1-if8
```

首次需按环境设置RISCV_TOOL_ROOT；Pango模型专测另需PDS_HOME，详见FPGA适配。
历史B19在C1、fill4下M0/M1/M2cold/warm/M2-B为
3.237325/2.797692/2.246406/2.246827/1.949692，完整旧结果在
`logs/p2/p1-adapt-20261023/summary.json`。以下P1/P0数值属于各自源码与镜像，
GCC11.4与GCC16.1分开比较。

P1.1a 的 LQ/SQ 控制与数据已拆分，实测源码 `core/p1-1a-split-lq-sq@a23b65c`。
双宽完整仿真及 RV32 四次同镜像比较通过，标准 PDS 为 86.1721 MHz、85 MHz WNS
+0.160 ns、零未布通，详见 [双发射](understand/DUAL_ISSUE.md) 和
[FPGA 适配](fpga/FPGA_ADAPTATION.md)。`core/p1-1b-rob32-split-iq@f547da3` 为
ROB32、int8/mem4 IQ，按全局年龄顺序发射。完整回归 RV32 228 PASS/5 SKIP、
RV64 264 PASS/5 SKIP；四次同镜像比较通过，标准 PDS 尚未完成。
M0/M1 为 2.635803/2.335916 CoreMark/MHz，较本次 GCC 11.4 重建 P0 提高 0.0814%/0.7759%。
P1.2 开发分支为 `core/p1-2-limited-integer-ooo`，开关 `LIMITED_INTEGER_OOO=1`。
整数队列选择最老就绪项，访存保持 FIFO 和串行屏障，精确退休沿用原 ROB。
双宽各三项定向通过，Core 各观察到 30 次越过阻塞整数项。
就绪旁路限于 ALU/MDU，访存/分支保持接纳顺序，晚异常不能占住老 IQ 项所需的 ISS。
十场景精确事件通过，Core ISA 为 RV32 58 PASS/2 SKIP、RV64 78 PASS/2 SKIP。
`5963d72` 完整回归为 RV32 229 PASS/5 SKIP、RV64 265 PASS/5 SKIP，四次同镜像比较通过。
M0/M1 为 2.670535/2.378539 CoreMark/MHz，较重建 P0 提高 1.4002%/2.6147%。
P1.3 开发分支为 `core/p1-3-iq-forward-timing`。已编写并行年龄序位选择，以及全部
旁路、分支屏蔽、全部 LSU 捕获、仅 Store 提示捕获四种模式；分配捕获在分流前共享。
四模式双宽定向各 17 PASS/0 SKIP，Core 均为 492/510 拍，新增统计计数器双宽各 1 PASS、
解析器 8 PASS；新双宽 P0 LSU 差分各 5 PASS/0 SKIP。`ea3fb0a` 五组、二十次固定镜像
比较通过，选模式 3 + Tournament/RAS，M0/M1 为 2.933400/2.566781/MHz，较同镜像重建
P0 提高 11.3812%/10.7359%。配置入口为 `scripts/verilator/p1_core_config.sh`。
`8c072c0` 最终回归为 RV32 237 PASS/4 SKIP、RV64 269 PASS/4 SKIP，含八次 RV32 重放，
两轮的 CRC、ROI/TB、统计和镜像哈希完全相同。最终综合为 57,437 LUT、41,497 FF、
零 latch、36 DRM、4 APM，双 TCM 初值匹配，保留 8/10/10 级。两次标准 place 在
20,193/22,191 MB 内存池峰值时分配失败；重试启动前物理可用/提交余量 19.988/24.021 GiB，
仍发生虚拟内存不足。用户已要求暂停布局；原工程和日志保留，没有最终 Fmax/WNS、
物理资源、最差路径或未布通数量，最终 P1 物理验收未完成。
P1.1b 中间布线第 13 轮仍有 24,179/69,295 条未布通，已主动终止，没有最终时序报告。
下文 r15 和旧控制组的数据保留原镜像、配置及历史归属；当前 P1 结果见本文开头。

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

此前 P2 的 `soc/p2-unified-bus` 固定 P0 Core，新增 `soc_system` 四域顶层、
统一 AXI4、TCM 系统端口、AXI4-Lite64、DMA 单主口和 SPI Flash 只读目标。
TCM/Cache 命中仍留 core 域；系统通路增加 FIFO、地址译码寄存和 CDC。
新 SoC 双宽异频功能与 ISA 已通过；标准 PDS 一次结果为 84.9856 MHz、
WNS −0.002 ns、1 个 slow setup 端点失败，未达 85 MHz。M2 正式性能尚未验收。
结构、地址表、启动与 DMA 路径见 [SoC 系统](understand/SOC_SYSTEM.md)。
P0 的 85.2464 MHz 仍只属于原实测源码；新 SoC 的 84.9856 MHz 是单时钟结果，
四域独立时钟未验证。

## 2. 目录

| 路径 | 内容 |
|---|---|
| `vsrc/core/` | 可移植 Core：frontend、decode、execute、lsu、writeback、csr |
| `vsrc/pkg/` | 类型、地址、配置、总线包 |
| `vsrc/soc/` | Cache、总线、TCM、ROM、DMA、UART/Timer/GPIO |
| `vsrc/cpu/` | FPGA wrapper、Pango DDR 桥 |
| `vsrc/sim_cpu/` | 仿真存储模型 |
| `tb/unit/` | 通用单元测试 |
| `tb/fpga/` | Pango厂商PLL模型与独立复位专测，由专用runner运行 |
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
| `RETIRE_ENTRIES` | 4 | 2、4、8、16、32 | 唯一退休队列容量 |
| `ISSUE_WIDTH` | 1 | 1、2 | 单发射或对应后端的双发射 |
| `CORE_BACKEND` | legacy | legacy、scoreboard | 旧控制组或新 RAT/scoreboard 双发射 |

冻结 P0 使用 `CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16`，
IQ8、LQ4/SQ4、checkpoint4、p0/r0、DSP/SRT4；C6 已完成双宽功能与固定镜像回归，
r15 已通过 RV32 标准 PDS 的 85 MHz 门槛。旧正式性能对照使用 `MUL_IMPL=0 DIV_IMPL=1 PREDICTOR_MODE=1 RAS_ENABLE=1`，
双发射加 `ISSUE_WIDTH=2 RETIRE_ENTRIES=8`。普通 `make` 的 DIV 默认 0，不能把
默认构建写成 DSP/SRT 结果。

P1 选定配置由 `source scripts/verilator/p1_core_config.sh` 提供：ROB32、int8/mem4、
有限整数乱序、转发模式 3、Tournament、DSP/SRT4。2026-10-24 起正式配置使用
`RAS_ENABLE=0`，综合裁掉 RAS 及恢复逻辑；历史 RAS 候选保留在独立分支。
P2 测试入口通过统一配置
传递这些参数；未选择 P1 时保留原 P0 参数对照，不能将默认入口误记为 P1 测试。

SoC 开关：

| 变量 | 默认 | 含义 |
|---|---|---|
| `SOC_CACHE_BLOCK_ENABLE` | 0 | I/D 行走 256 位块通道 |
| `SOC_DMA_WIDE_ENABLE` | 0 | 允许对齐 DDR 段宽搬运 |
| `SOC_DMA_BLOCK_ENABLE` | 0 | 双槽 DMA |
| `SOC_LOCAL_TCM_ENABLE` | 0 | TCM 走局部 hot 路 |

旧板级控制组固定 i1、full、local0、cache_block1、dma_wide1、dma_block1。
scoreboard 整机使用 `soc_system`，TCM 固定走本地 bank，Cache 与 DMA 固定汇入
统一 AXI。上表四个开关只控制 legacy；新 runner 保留其 CLI 兼容性，实际结构
写入 manifest，不能用旧开关名推断新 RTL。外部时钟由 `clk_core/clk_sys/clk_ddr/clk_periph`
输入；`DDR_BYTES/FLASH_BYTES/NPU_BYTES` 分别控制窗口容量，0 表示未装配。

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
新总线与四域整机入口为 `make soc-axi-test XLEN=32` 和
`make soc-system-test XLEN=32`，RV64 使用相同入口改 XLEN。
旧 `make test` 的配置 TB 仅支持退休队列 2/4/8；P0 的 ROB16 使用
`make scoreboard-test` 和明确的 scoreboard ISA/benchmark 配置验证，不能把
旧配置 TB 的拒绝当成新 Core 功能失败。

## 5. 仿真性能

历史 r15 实测源码为 `core/pipe-lsu-forward-format@dffb8a2`，RV32 四次重放与 ISS
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

新 SoC 本轮日志在 `logs/p2/unified-bus/final/`。每宽 AXI/CDC 定向 9 PASS、
C0–C4 整机程序 5 PASS；SoC ISA 为 RV32 59 PASS/1 SKIP、RV64 79 PASS/1 SKIP。
固定 Core 的 M0 重放 performance/validation 为 22,381,822/22,507,018 拍，
与 P0 一致。M1 C1 同冻结镜像的两模式为 25,658,220/25,792,596 拍，分数与上表 P0 相同；
512 MiB DDR 译码、64 KiB DDR 模型，100/80/125/25 MHz 仿真时钟。TB 各增加
88 个 ROI 外启动周期。M2 cold/warm 与 M2-B 尚待专门测量。

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

- RV32/RV64 I/M/Zicsr，scoreboard 后端支持双发射、有限整数乱序选择、独立完成和按序双退休。
- DSP/Booth-Wallace/移位乘法，SRT/移位除法。
- P0 为 ROB16/IQ8；P1 配置为 ROB32/int8/mem4、有限整数乱序；RAT、精确异常、机器中断、CSR。
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
- P1 有限整数乱序 Core 已通过原功能回归，最终物理验收未完成；C 扩展暂缓，AI 接口单独规划。

## 8. 未来

1. 在独立分支完成 P1 Core 与 P2 SoC 适配，保留双方源码与原始性能证据。
2. 使用相同冻结软件比较 M0/M1/M2 cold/warm 和独立 M2-B，双宽验证功能、取消和完整标签。
3. P3 完成真实时钟、CDC 与 IO 约束后，按内存实际峰值安排标准 PDS，保持 85 MHz 门槛。
   现有 8/10/10 级保持；本次适配不启动 PDS。
4. 恢复 RT-Thread 依赖并完成真实 DDR/UART/ILA、十秒 CoreMark、功耗和 AI 接口。

## 9. 文档

- [学习文档](understand/README.md)
- [FPGA 适配](fpga/FPGA_ADAPTATION.md)
- 工作区根目录：`ITERATIONS.md`、`OPTIMIZATION_PLAN.md`、`HANDOVER.md`
