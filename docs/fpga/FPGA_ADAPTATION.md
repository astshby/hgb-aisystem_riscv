# FPGA 适配与综合

## 当前应用与物理结果（2026-10-30）

| 用途 | 配置时钟 Core/SYS/DDR-user/外设/NPU，MHz | 视频 |
|---|---|---|
| 无 NPU 完整系统 C6 | 100/100/125/60/无 | 无 |
| YOLO C7 | 90/100/125/60/100 | 独立 148.5 MHz |
| YOLO Core 后备 C8 | (900/11)/100/125/60/100 | 独立 148.5 MHz |

系统 `pango_soc_pll` 保留一颗 GPLL，900 MHz VCO 以 /9、/10 或 /11、/9、/15、/9
生成 Core/SYS/外设/NPU。DDR-user 125 MHz 仍由 DDR IP 提供，IP 内部的 PLL 另计。
视频用独立 `GTP_PPLL`：27 MHz D18 输入，I=1、M=2、F=33、输出 /12，产生 148.5 MHz。
厂商原 PPLL/BUFG 模型实测 148.499986 MHz，3000 周期、失锁健康输入恢复和板级复位重锁通过。
视频 PLL 只由板复位控制；它的 lock 并入整机复位监督，视频 SYS/外设/像素 FIFO 共同复位。
这些配置与模型周期不是板上工作频率测量。

无 NPU C6 工程已完成 normal 布局、布线和 route_optimize。源码 `80576b9`，
I16/D8/mask2、O3/64 次自动 TCM CoreMark 固件，最终报告为：

| 域 | 配置 MHz | 布线 Fmax MHz | 同域 setup WNS ns |
|---|---:|---:|---:|
| Core | 100 | 87.3057 | −1.454 |
| SYS | 100 | 98.2415 | −0.179 |
| DDR-user | 125 | 122.5490 | −0.160 |
| 外设 | 60 | 72.2201 | +2.820 |

未布通为 0；资源为 74746 LUT（含常量/旁路）、61967 FF、38 DRM36K、4 APM。
Core 未达到 100 MHz，SYS 和 DDR 也有负裕量，不能按配置目标宣称收敛。
DDR→PHY 仍有 −0.027 ns setup，缺输入/输出 delay 为 35/73。
原始摘要 `logs/main-coremark-c6-cdc-20261029/physical-summary.json`，
工程 `$PDS_WORK_ROOT/work/main-coremark-c6-cdc-20261029`，命令、固件和报告哈希在摘要内。
该工程没有装入常驻交互固件。新增视频/YOLO 组合尚未综合布线，没有 bitstream 或板级结果。

当前入口要求 `max_threads=8`，`HGB_PDS_THREADS` 可覆盖；C6 最终时序报告实际使用 4 个进程，
尚无同输入 1/8 线程加速比。timing-v3 固定 fanout128、retiming 开、资源共享关、布局双输出 LUT 合并关、
布线权重90及 recovery 优化；place/route 均为 normal。旧 timing-v2 的 64/80 报告按历史参数核验。
PDS 2025.2 不支持 `place -mode performance` 或 `number_of_router_thread`，不再向新工程传入它们。
每阶段检查至少 6 GiB 物理和提交余量，约十分钟查看一次，不修改分页或终止无关进程。

YOLO 板级顶层 `pango_200hp_top` 默认 `VIDEO_ENABLE=NPU_ENABLE`。视频 DMA 接真实外部主端3，
SYS AXI-Lite 控制在 `0x10070000`，UART/MMIO 仍经 60 MHz 外设 CDC；SDA 是开漏。
`mes2l676_200hp_video.fdc` 记录同板参考的 32 个视频相关引脚及真实 27/148.5 MHz 时钟，
没有编造 I/O delay 或加入整域 false path。VIDEO=0 不实例显示/PPLL，MMIO 完全旁路新分流。
双宽 full/lite、VIDEO0/1 共 8 组封装展开和 6 项视频暂存测试通过，物理管脚/站点仍需新工程检查。

独立视频双宽完整 1080p 仿真、真实 UART/原视频驱动两轮 A/B 扫描已通过；
完整 416 模型的 83 Conv/266 节点通过 NPU 部件仿真，电脑执行 C 图，耗时 33 分 28.7 秒。
真实 RV32/RV64 Core 驱动各通过 3 个小卷积/171 输出/5 个量化值。
320 完整应用联合仿真已通过真实 UART 收图、83 Conv、框/画框图回传和 1080p 扫描后回 READY，
共核对 5,775,300 个 INT32 输出，11,638.68 秒、峰值 RSS 78,476 KiB，全部错误计数为 0。
C 在电脑执行，没有 RISC-V Core、CPU Cache 或 Flash，DDR 为行为模型；没有完整 RV32 整网或板上 HDMI 结果。
构建记录的提交为 `6008bc5`；实际源文件已保存于 `a91c795`，逐文件 SHA256 与运行快照一致。
命令和哈希见 `logs/demo-software-20261029/yolo-full/app320-full-rtl-v2/result.json` 及同目录 `sourceidentity.json`。
证据与入口见[项目介绍](../PROJECT_INTRO.md#环境与命令)。预载模型 CRC 检查不代表 Flash 冷启动已接通，
模型 UART 命令已有软件测试，尚无板上约 5 MB 模型全传验收。

## 历史停止点：TCM重构后布局布线前

2026-10-29，实验分支 `integrate/yolo-tcm-boundaries` 已完成 TCM 重构后的 9 组综合、双宽仿真和 CDC 核验。
本轮按要求停在 dev_map/place/route 前。组合 RTL 为 a7b25c2，YOLO 集成 76139dc，CDC 工具为 5b29642；正式基线未升级。
当前分层综合数值见[项目介绍](../PROJECT_INTRO.md)，下方日期更早的表保留为历史对照。

SoC+TCM 的 26 个 FIFO/358 个同步寄存器、YOLO 的 36 个 FIFO/502 个同步寄存器已核对原生引脚与时钟。
PDS 查询使用 128 项精确引脚分组，避开延迟集合句柄及 1000 项打印截断。Gray 指针约束到第一同步级；
载荷限定源时钟、实际 RAM/FF 数据输出和目标时钟；IRQ/DDR 就绪限定原生时钟树中的源寄存器及第一同步级。
第二同步级和普通同域路径继续接受 setup/hold 检查，时钟定义未变，没有加入整域 false path。
前后报告中的同域 Fmax、setup/hold、端点数一致，6/11 组功能跨域 setup 裕量为正，SDC-2040 和无匹配路径告警均为 0。
证据为 `logs/tcm-bram-20261028/cdc-{soc-tcm,yolo}-effectiveness.json`；146 项工具测试和新增 2 项对照检查通过。

准备好的原生工程在 `$PDS_WORK_ROOT/work/tcm-bram-20261028/yolo/physical-ready/`。
保留性能策略综合数据库、配对 O3 YOLO 固件、`backend_cdc.scf`、`backend_sync.lcf`、`ready-inputs.json` 和 `READY.json`。
`implement_ready.tcl` 每次打开工程后显式加载两份约束，再运行物理阶段；PDS CLI 的 `save_project` 仅适用于 GUI，
此入口不依赖它保存约束。`launch-physical.ps1` 先核对文件哈希和内存，再调用上述入口。
这份历史预案写入了 performance 放置/布线与单线程；后来确认该模式不受 PDS 2025.2 支持，
不能按这份未执行的预案启动。实际 normal 策略和已执行结果分别见本节开头及后续 C5 日期表。
映射、布局、布线、优化前分别检查物理与提交余量各至少 6 GiB。最终报告启用 max-skew 与 exception 明细。

2026-10-29 00:15 的预检为物理 14.988 GiB、提交余量 8.370 GiB；下次启动时重新查询。
以下是 2026-10-29 当时准备、尚未执行的历史入口，不作为当前启动命令：

```powershell
& "$env:PDS_WORK_ROOT\work\tcm-bram-20261028\yolo\physical-ready\launch-physical.ps1" -PdsHome $env:PDS_HOME
```

这份工程仅含已有 128-MAC YOLO，目标 Core/SYS/DDR-user/外设/NPU 为 100/80/125/25/100 MHz。
Core 综合为 92.9282 MHz、100 MHz 下 WNS −0.761 ns；在这个历史停止点还没有布线 Fmax/WNS、
未布通数量、bitstream 或板级结果。
物理阶段继续检查 Gray 最大偏斜、同域 setup/hold、DDR PHY 和 I/O，不能据本次 CDC 对照宣称整体时序闭合。

## 配置与入口

Windows PDS 2025.2 ADS，器件 PG2L200H-6IFBB676，HMIC_S 1.10 DDR3 IP。
生成 IP 和原生工程使用 `$PDS_WORK_ROOT` 的新目录；`reference` 只读。
`PDS_HOME` 指向 Windows 工具安装。Linux Verilator 通过不代表板上通过。

Core 为 ROB16/int8/mem4、RAS0、OOO0、Tournament1、forward3、MUL0/DIV1。
C6/C7 是当前演示目标；C1 历史目标 Core/SYS/DDR-user/外设 = 100/80/125/25 MHz。
C5 目标 Core/SYS/DDR-user/外设/NPU = 90/100/125/25/100 MHz，供 YOLO 布局布线；见下节。
`pango_soc_pll` 为功能域生成时钟，DDR 用户时钟来自 DDR IP；选定加速器使用额外 100 MHz 输出。

`prepare_project.py --core-backend scoreboard --board-clock-profile 6` 暂存无加速器 C6 工程；
YOLO 使用 `--board-clock-profile 7 --npu-enable`，默认包含视频源码和 `board_video.fdc`。
`--video-enable 0` 显式生成无显示的加速器候选，并写入 manifest，不能混用显示工程的结果。
`--npu-enable` / `--mm3-enable` 仍互斥，分支未保留的设备不能选择。
加速器专用分支从 `branch_profile.json` 读取默认设备，all 默认无设备。
默认入口已选择 scoreboard/C1；显式 legacy 使用原共同时钟，仍可显式覆盖时钟档。
四分支各 64 项 PDS 工具测试通过。暂存前需 `make loader XLEN=32` 与完整生成 DDR IP 目录。

含 CoreMark 的分支可用 `prepare_benchmark.py` 对 `core_tcm/soc_tcm/soc_ddr` 暂存与仿真
同配置、同 bundle 的工程；all 还支持 soc_npu。必须提供 `--bundle`、`--sim-receipt`，
DDR 组另需 `--ip-dir`。TCM 组使用真实 TCM RTL/BRAM 初值和外部时钟端口。
Cache 容量通过 `--icache-bytes`、`--dcache-bytes` 指定，默认各 4096 B，可选 4–64 KiB 的 2 次幂。
容量同时写入板级参数和清单，并核对仿真 build receipt、实际顶层参数转发和编译 Tcl；
不能只改测量标签而沿用旧硬件。比较容量时冻结同一固件、FDC、DDR IP 和综合选项。

标准综合使用 ADS `synthesize -ads -selected_syn_tool_opt 2`，增加路径报告深度；
当前统一入口要求 8 线程，旧表的单线程参数不追改。每个新工程保留编译 Tcl、FDC、镜像、
源码哈希和原始报告，不改写已有 PDS 工程或其结果；新增交互/视频硬件还没有运行 P&R。

## 2026-10-27 标准综合实测

Windows PDS 2025.2 ADS，PG2L200H-6IFBB676，selected_syn_tool_opt=2、单线程、max_path=100。
下表每格为 **综合估计 Fmax MHz / 同域 setup WNS ns**；目标依次为 100/80/125/25/100 MHz。
各域最高值独立统计，不能同时替换测试时钟后沿用原 CoreMark/MHz。

| 硬件 | Core | SYS | DDR-user | 外设 | NPU |
|---|---:|---:|---:|---:|---:|
| Core+TCM | 103.8853 / +0.374 | — | — | — | — |
| SoC+TCM | 95.0299 / -0.523 | 88.7311 / +1.230 | — | 93.1966 / +29.270 | — |
| SoC+Cache/DDR | 85.1064 / -1.750 | 83.8504 / +0.574 | 144.7178 / +1.090 | 87.5197 / +28.574 | — |

| 硬件 | LUT | FF | DRM36K | APM |
|---|---:|---:|---:|---:|
| Core+TCM | 26239 | 19665 | 32.0 | 4.0 |
| SoC+TCM | 46748 | 39193 | 32.0 | 4.0 |
| SoC+Cache/DDR | 61438 | 54342 | 36.0 | 4.0 |

DDR-user 125 MHz 是控制器用户接口；本轮 IP 配置为 DDR 数据率 1000 Mbps、外部 CK 500 MHz。
TCM 两组没有 DDR PHY，不填 DDR-user 数值。
各组 RTL、时钟、ROM/TCM 初值和完整原生报告均单独冻结。

原生工程位于 `$PDS_WORK_ROOT/work/four-branches-20261027/`，目录与表行分别为
`core_tcm`、`soc_tcm`、`soc_ddr-v2`。摘要、命令和报告哈希见本地
`logs/four-branches-20261027/synthesis-*.json`；工具输出不入源码仓库。
CoreMark 硬件组绑定 edc2349 公共硬件与 O3 TCM CoreMark 镜像。
最终分支裁剪移除未启用设备/应用，公共 Core、包和 BSP 的 100 份文件相同，应用在裁剪树另行复测。
报告绑定原测量输入，不把文档提交或裁剪树 SHA 写成未经运行的新综合。

| 硬件/域 | 最差起点 → 终点（末三级层次） | 逻辑级 | 最高扇出 |
|---|---|---:|---:|
| Core+TCM/Core | `u_core/u_issue/packet_q[658]/CLK` → `g_split_iq.u_scoreboard/g_ordered_integer.u_integer/packet_q[257]/D` | 22 | 39 |
| SoC+TCM/Core | `u_lsu/u_store/valid_q[3]/CLK` → `g_split_iq.u_scoreboard/g_ordered_integer.u_integer/packet_q[260]/D` | 17 | 32 |
| SoC+TCM/SYS | `g_target[0].u_exit/u_r/read_q[0]/CLK` → `g_soc.u_soc/u_fabric/r_next_q[3][0]/CE` | 14 | 274 |
| SoC+TCM/外设 | `g_soc.u_soc/u_reset/g_domain[3].release_q[2]/CLK` → `u_peripherals/u_irq/priority_q[1][0]/CE` | 14 | 1681 |
| SoC+Cache/DDR/Core | `u_tcm_target/u_target/write_q[15]/CLK` → `u_soc/g_tcm[0].u_ram/g_bank[0].mem_0/WEA` | 18 | 106 |
| SoC+Cache/DDR/SYS | `u_soc/u_reset/g_domain[1].release_q[2]/CLK` → `u_soc/u_fabric/r_next_q[1][0]/CE` | 17 | 1847 |
| SoC+Cache/DDR/DDR-user | `u_ddr_bridge/wr_cmd_q[3]/CLK` → `u_ddr_bridge/wr_error_q_reg[1]/D` | 11 | 57 |
| SoC+Cache/DDR/外设 | `u_soc/u_reset/g_domain[3].release_q[2]/CLK` → `u_peripherals/u_mtime/time_q[63]/D` | 16 | 1724 |

| 硬件 | 原始跨域 setup 最差 ns | 原始跨域 hold 最差 ns | 同域 hold 最差 ns | 未指定 input/output delay 数 |
|---|---:|---:|---:|---:|
| Core+TCM | — | — | +0.569 | 3/2 |
| SoC+TCM | -2.400 | +0.321 | +0.274 | 4/2 |
| SoC+Cache/DDR | -6.063 | -4.770 | -0.006 | 35/73 |

上述跨域数值是保留全部真实路径时的原始报告，尚未完成 FIFO/Gray/payload 端点约束及 DDR PHY/I/O 检查。
域内最差路径的完整端点/逻辑级/扇出，以及原始跨域 setup、hold 和未约束 I/O 均保存在摘要。
负 WNS 表示对应目标未达到；跨域、DDR PHY 和 I/O 约束仍需逐端点检查，不能据域内 Fmax 宣称整体时序闭合。
本轮未执行 P&R，布线 Fmax/WNS、未布通数和板级结果均为未测。

## Cache 容量综合对照

实验分支 `soc/cache-capacity-sweep`，起点 main `62e2d0f`，参数贯通 `cf25b9a`，
两份原生清单均记录 `1d9efff`。243 份 HDL、O3 TCM CoreMark 初值、DDR IP、FDC 与 ADS 参数相同，
仅 I$ 从 4 增至 16 KiB，D$ 保持 4 KiB。编译参数和实际顶层转发已核对。

| I$/D$ KiB | Core Fmax/WNS | SYS Fmax/WNS | DDR-user Fmax/WNS | 外设 Fmax/WNS |
|---|---:|---:|---:|---:|
| 4/4 | 85.1064 / -1.750 | 83.8504 / +0.574 | 144.7178 / +1.090 | 87.5197 / +28.574 |
| 16/4 | 86.8282 / -1.517 | 83.6960 / +0.552 | 150.4664 / +1.354 | 88.0747 / +28.646 |

Fmax 单位 MHz，WNS 单位 ns。Core 综合估计提高 2.0231%，SYS 降低约 0.1841%，仍达到 80 MHz。
四域估计值没有全部保持或提高；完整 DDR 系统的 Core 100 MHz 目标仍未达到。
CoreMark 固定用 100/80/125/25 MHz 做功能仿真，不能将本表各域独立 Fmax 代入原跑分。

| I$/D$ KiB | 总 LUT | 总 FF | 总 DRM36K | APM | I$ LUT/FF/分布式 RAM/DRM |
|---|---:|---:|---:|---:|---:|
| 4/4 | 61438 | 54342 | 36 | 4 | 594 / 659 / 42 / 2 |
| 16/4 | 61775 | 54918 | 38 | 4 | 1430 / 1235 / 152 / 4 |

总增量为 337 LUT（0.5485%）、576 FF（1.0600%）、2 DRM，latch 均为 0。
I$ 局部 LUT 增量为 836，整 SoC 的增量较小，其他模块的映射也发生了变化。
Core 最差路径现为 SQ `valid_q[3]` → 前递/请求选择 → `broadcast[8].valid` → IQ `packet_q[225]`，
18 逻辑级、扇出 49，数据延迟 11.031 ns，其中估计连线 9.127 ns。
报告的前 100 条 Core 路径均从该 SQ 有效位出发，以 IQ 为终点；原 TCM 系统写路径不再排在这组前列。
SYS 最差为 reset release → fabric write-route FIFO 的 CE，16 级、扇出 1838。
本轮只改 Cache 容量，未修改 SQ、TCM 或总线逻辑，频率变化包含综合映射变化。

原生目录为 `$PDS_WORK_ROOT/work/cache-capacity-20261027/baseline-i4-d4` 和 `candidate-i16-d4-v2`。
基线 Linux launcher 异常退出，Windows 子进程完成了综合；其 run.log、snr、完整网表和全部报告保留，
恢复摘要另记完成证据及提取脚本哈希，没有补写外层成功日志。候选有正常的外层完成标记。
候选旧目录在编译前被内存门禁拦截，失败记录保留；新目录外层余量 14.30/7.858 GiB，工具内部检查通过。
基线/候选综合耗时 51m44s/52m23s，工具报告峰值 3406/3306 MB。
摘要、报告哈希和输入对照在 `logs/cache-capacity-20261027/` 的 synthesis-*.json、paired-inputs-v2.json、cache-selection.json。
原始 DDR→SYS、外设→SYS setup WNS 仍为 -6.063/-2.998 ns，SYS→DDR hold 为 -4.770 ns；
DDR-user 同域 hold -0.006 ns、3 个端点，未指定 I/O delay 35/73。没有布局布线结果，未布通数为未测。

## 2026-10-27 SYS 控制路径综合对照

分支 `soc/fabric-onehot-control@0f66bf1`，同一I16/D4配置、固定O3初值、DDR IP、FDC与标准ADS选项。
固定编号的资格与独热授权替换旋转下标宽选择链，保留入口/出口FIFO、反压锁定、AW/W所有权和同ID排序。
双宽AXI/CDC测试及旧实现逐拍比较通过；六项短CoreMark周期完全相同。

| 配置 | Core Fmax/WNS | SYS Fmax/WNS | DDR-user Fmax/WNS | 外设 Fmax/WNS | LUT/FF/DRM/APM |
|---|---:|---:|---:|---:|---:|
| I16/D4原路径 | 86.8282/-1.517 | 83.6960/+0.552 | 150.4664/+1.354 | 88.0747/+28.646 | 61775/54918/38/4 |
| SYS独热授权 | 90.1307/-1.095 | 104.7449/+2.953 | 144.7387/+1.091 | 86.1104/+28.387 | 52625/54886/38/4 |

Fmax为MHz，WNS为ns。LUT减少9150（14.81%）、FF减少32，DRM/APM不变、latch为0。
模块资源表中fabric自身LUT14260→5047、FF8285→8278；同输入清单仅fabric RTL及两份来源元数据不同，固件/FDC/IP一致。

SYS最差reset release→fabric `r_next_q[0][0]/CE`为12级、扇出1730，对照16级/1838。
Core最差SQ valid→前递资格/请求选择→LQ state为17级、扇出50，数据延迟10.609ns。
Core 100MHz仍未达到；DDR-user和外设估计值下降，但高于125/25MHz目标，不能称四域全部不降。
DDR→SYS setup -6.064ns、外设→SYS -2.998ns，SYS→DDR hold -4.771ns、DDR同域hold -0.006ns/3端点；未约束I/O35/73。
没有P&R，布线Fmax/WNS和未布通数量未测。

原生工程 `$PDS_WORK_ROOT/work/path-tuning-20261027/sys-onehot`，摘要 `logs/path-tuning-20261027/sys-onehot-synthesis.json`。
启动与暂存收尾曾重叠，原清单误含5个运行文件；原清单与异常保留，266项静态输入逐一校验一致后移出运行项，复核通过。
A独立实验 `f8a72c2` 已在同一I16/D4原路径上完成标准综合；Core92.2594/-0.839、SYS84.0477/+0.602、DDR-user150.3759/+1.350、外设88.2613/+28.670（MHz/ns）。
资源61834 LUT/54917 FF/38 DRM/4 APM：LUT比原路径增加59、FF减少1；Load Queue自身LUT1234→1249、FF仍440。
A最差Core路径转为TCM目标r_valid→TCM RAM写使能，20级、扇出50。它改善Core估计频率，未实现提案预期的LUT下降。
B在SYS底座的对照 `c2a71e0` 为Core88.3470/-1.319、SYS101.9680/+2.693、DDR-user150.3759/+1.350、外设87.9430/+28.629。
53117 LUT/55041 FF/38 DRM/4 APM，比SYS增加492 LUT、155 FF；Core由90.1307降到88.3470 MHz，且每MHz跑分回退，本轮不采用。
SYS＋A＋bank及无A控制现已完成，取舍见下节。

## 路径实验的三层结果与取舍

以下保留 2026-10-27 测量。

测量代码47aec08，收尾分支integrate/soc-path-selected，保留SYS独热控制和bank参数入口，不含A/B。
默认仍I4/D4/mask0；DDR D8表项显式使用I16/D8/mask2。固定O3、原两次TCM初值、相同FDC和标准ADS选项，未运行P&R。

| 无A/B配置，测量源码47aec08 | Core MHz / WNS ns | SYS MHz | DDR-user MHz | 外设 MHz | LUT / FF / DRM / APM |
|---|---:|---:|---:|---:|---:|
| Core+TCM | 105.0641 / +0.482 | 不适用 | 不适用 | 不适用 | 26130 / 19665 / 32 / 4 |
| SoC+TCM | 93.6067 / -0.683 | 112.9433 | 不适用 | 98.8045 | 39908 / 39165 / 32 / 4 |
| 完整DDR，I16/D8/mask2 | 89.3336 / -1.194 | 106.6894 | 150.4664 | 86.3185 | 52571 / 55207 / 38 / 4 |

SYS是本轮主要收益；保留独热控制和可配置bank入口，A/B不进入收尾源码。D8/mask2保留显式候选，默认仍I4/D4/mask0。
SYS单项I16/D4/mask0的Core为90.1307 MHz，D8联合为89.3336 MHz，低0.8844%；D8六项每MHz几何均值提高0.8207%。不能写成相对SYS单项两项同时提升。
D4/mask1联合为85.4920 MHz，低于本轮起点86.8282，拒绝该映射。D8相对起点同时改善Core频率与每MHz性能，但外设Fmax下降、仍高于25 MHz目标。
SoC+TCM的Core由旧95.0299降到93.6067 MHz，下降1.4976%，同时LUT减少6840、FF减少28。**本轮未达到所有层Core主频不退的验收条件，正式baseline不升级。**
Core+TCM由旧103.8853提高到105.0641 MHz、LUT减少109、FF不变；该层>100 MHz，真实TCM每MHz仍>3。

含A对照8a0d8f7的Core+TCM/SoC+TCM/DDR为104.0042/93.1532/87.0701 MHz，LUT26449/39979/53056。
去掉A后三层分别少319/71/485 LUT、FF不变，Core均提高；逐文件配对只有Load Queue RTL和来源元数据不同。
D4/mask1的联合对照为Core85.4920、SYS104.6025、DDR150.4664、外设86.9414 MHz，52013 LUT/54887 FF/38 DRM/4 APM，保留负结果。
无A三层SYS WNS分别不适用/+3.646/+3.127 ns，外设WNS不适用/+29.879/+28.415 ns，DDR D8 WNS+1.354 ns；全部0 latch。

无A Core+TCM最差ISS packet→ISS packet，21级/扇出33；SoC+TCM最差ISS packet→TCM RAM地址，20级/扇出28。
DDR D8最差ISS packet→IQ packet，19级/扇出818；SYS最差AW decode→write-route FIFO CE，13级/扇出163。
Core+TCM无负setup/hold，缺I/O delay3/2；SoC+TCM外设→SYS setup -2.036ns，缺I/O4/2。
DDR D8跨域setup DDR→SYS -6.064、外设→SYS -2.998；hold SYS→DDR -4.771、DDR→PHY -1.137、DDR同域 -0.006ns/3端点；缺I/O35/73。
布线Fmax/WNS和未布通数量未测，不能写成0；目标时钟100/80/125/25 MHz与各域独立Fmax分别呈现。

原生工程 `$PDS_WORK_ROOT/work/path-tuning-20261027/{control-core-tcm,control-soc-tcm,control-sys-i16-d8-h2}`。
摘要、命令、源/镜像/日志哈希见 `logs/path-tuning-20261027/final-summary.json`，原始报告和两种源码对照均保留。
十组标准综合结束后再次核验静态输入全部通过；启动前物理/提交余量各至少6 GiB，未修改分页或终止无关进程。

## 2026-10-29 C5 历史目标时钟

2026-10-29 分支 `clocks/c5-yolo-90-100`，基于 `5966bbb`。首次提交 `864b344` 的目标是
无加速器的 85/106.25 MHz；按 YOLO 布局布线需要修订为 90/100 MHz 并保留 100 MHz NPU，
修订见下表和第二次提交。

| 域 | 综合估计 MHz（YOLO 性能） | 向下取 5 | C5 目标 MHz | 相对估计余量 |
|---|---:|---:|---:|---:|
| Core | 92.9282 | 90 | 90 | 3.2% |
| SYS | 113.9212 | 110 | 100 | 12.2% |
| DDR-user | 146.0494 | 145 | 125（IP 固定） | 不适用 |
| 外设 | 92.1574 | 90 | 25（保持原值） | 不适用 |
| NPU | 114.8633 | 110 | 100（保持原值） | 不适用 |

时钟树：125 MHz ref → PFD 25 MHz → VCO 900 MHz（`STATIC_RATIOF=9.0`）→ 整数 ODIV
10/9/36 得到 Core 90、SYS 100、外设 25 MHz，CLKOUT3 的 /9 给出 NPU 100 MHz，占空比均 50%。
VCO 800 MHz 的栅格只能给出 100/88.9/80/114.3 MHz，90 和 110 都不在栅格上；
{90, 110, 25, 110} 无整数 ODIV 解。900 MHz VCO 让四个域同时落在整数分频上，SYS 取 100 MHz
（900/9），比向下取整的 110 MHz 低一档，代价是 SYS 带宽少 9%。

| 文件 | 改动 |
|---|---|
| `vsrc/cpu/pango_soc_pll.sv` | 新增 `CLOCK_PROFILE=5`：`VCO_RATIOF=9.0`、Core ODIV 10、SYS ODIV 9、外设 ODIV 36、NPU ODIV 9；C1/C4 参数保持不变 |
| `vsrc/cpu/pango_200hp_top.sv` | `HOT_HZ=90 MHz`、`SYS_HZ=100 MHz`；`PERIPH_HZ` 与外设 UART 分频不变 |
| `scripts/pango/prepare_project.py` | `BOARD_CLOCK_PROFILES[5]`、`BOARD_CLOCK_RATIOS[5]=(18,25)/(4,5)/(1,5)`、`--board-clock-profile` 接受 5、NPU 校验改为 `NPU_DIV` 参数 |
| `scripts/pango/measurement_constraints.py` | `CLOCKS["C5"]` |
| `tb/tools/test_pango_handoff.py` | 暂存用例扩展到 1/4/5，同步新的 Hz 公式 |
| `scripts/hardware_profile.json` | `native_board_profiles` 增加 `yolo: 5`，`target` 仍为 1 |
| `scripts/hardware_config.py` | 按加速器选板级档：`yolo` 取 `yolo` 项（C5），其余仍取 `target`（C1） |

选择范围：只有 YOLO 应用工程暂存到 C5。`clock_periods_ps` 未改，YOLO 仿真仍按 target 的
100/80/125/25 MHz 运行，应用验证的周期数与板级 90/100 MHz 无关；CoreMark、RT-Thread 与其余
测量工程的板级默认仍为 C1。`tb_yolo_system` 只带缓存容量参数，时钟由 `tb_soc_system` 默认值决定，
因此这次切换不重建仿真时钟。

验证：

- 生成约束核验为 `-multiply_by 18 -divide_by 25`（90 MHz）、`4/5`（100 MHz）、`1/5`（25 MHz）。
- 用 PDS 自带 `GTP_GPLL.v` 行为模型仿真 C5（`NPU_ENABLE=1`），600 µs 窗口计数
  Core 54000、SYS 59999、外设 15000、NPU 59999 个上升沿，`locked=1`，输出
  `PASS pll C5 core=90.000 sys=100.000 periph=25.000 npu=100.000`。
  SYS/NPU 少 1 个沿是窗口边界（300 µs 与 900 µs 各有一沿落在判据之外），折算频率 99.998 MHz。
- `make test XLEN=32` 与 `XLEN=64` 各 84 PASS、2 SKIP（RAS 关闭、RV32 下的 RV64 用例）、0 FAIL；
  `make soc-lint` 无 `%Error`；`test_pango_handoff`/`test_soc_clock_plan`/`test_measurement_constraints`
  共 67 项通过。
- 日志 `logs/c5-clock-20261029/{test-rv32.log,test-rv64.log,soc-lint.log}`。

边界：C1/C4 参数与约束未变；本轮没有用 C5 运行综合和 P&R，90 MHz 是目标值。
YOLO 标准策略（Core 93.1532、SYS 101.8537、NPU 107.9680 MHz）也满足 C5 的 SYS 与 NPU 目标。
波形与板上测量均未做。

实现阶段的调用方式：`pds_shell -work_dir <工程> -file <tcl>`，工程由 `HGB_PDS_PROJECT` 打开。
2026-10-29 实测，多传 `-project_name` 会新建空工程并覆盖已有 `.pds`（147 KB 变 19 KB），
随后 `dev_map` 报 `Flow-0001: There are no design files`。实现脚本因此只传 `-work_dir` 与 `-file`。

PDS 2025.2 的 `place -mode` 与 `route -route_mode` 只接受 `fast`/`normal`；`performance` 会报
`Flow-0119`。`$PDS_WORK_ROOT/work/tcm-bram-20261028/yolo/physical-ready/strategy.json` 里的
`place -mode performance ... -refineplacement_cluster`、`route ... -number_of_router_thread`
都不是该版本的合法选项，那份“性能策略”没有执行过。实际可用的时序优先选项是
`place -optimize_gp_recovery / -logic_optimize_lut6d FALSE` 与
`route -slack_weight / -optimize_routing_recovery`；`place -dc_duplication` 只接受
`Global Disable`（默认已启用复制，该选项仅用于全局关闭），`-logic_optimize_lut_cascade`
本器件不支持（`Flow-0182`）。

### C5 首次布线实测（2026-10-29）

工程 `$PDS_WORK_ROOT/work/clocks-c5-yolo-perf2-20261029/yolo`，C5 目标
90/100/125/25/100 MHz，性能策略综合后执行 `place -mode normal -optimize_gp_recovery TRUE
-logic_optimize_lut6d FALSE`、`route -route_mode normal -slack_weight 80
-optimize_routing_recovery TRUE`、`route_optimize`，25 min 41 s 完成，布线收敛，未布通网络 0。

| 域 | 布线 Fmax | 目标 | Slack | 同域失败端点 |
|---|---:|---:|---:|---:|
| clk_core | 80.5794 | 90 | −1.299 | 6353 / 122429 |
| clk_sys | 93.1966 | 100 | −0.730 | 未列 |
| clk_npu | 91.4829 | 100 | −0.931 | 未列 |
| ddrphy_sysclk | 109.6011 | 125 | −1.124 | 1280 / 30478 |
| clk_periph | 55.6855 | 25 | +22.042 | 0 |

资源占用：CLMA 20256/30075（68%）、CLMS 6360/9875（65%）、DRM 165/415（40%）、
APM 43/370（12%）、GPLL 3/10。检查项只报 1 个 virtual_clock，没有缺失 I/O 约束。

跨域（本工程未加载 CDC 例外，按同步检查判负）：外设→core −2.674、sys→DDR −2.485、
DDR→sys −2.178、core→sys −2.079、sys→core −2.053、core→外设 −1.383。

Core 最差路径仍是 IQ 写口：TCM bank CLKA → 整数 IQ `packet_q`（8 级、扇出 34、
逻辑 2.874 / 布线 8.724），`u_memory/tag_q` → IQ `packet_q`（7 级、扇出 60、布线 85.9%）。

结论：C5 的 90 MHz 布线后不成立，Core 实际约 80.6 MHz；85 MHz 同样不成立。
要在布线上闭合，Core 目标需降到 80 MHz 或更低，SYS/NPU 需降到 90 MHz 或更低。
DDR 域在 125 MHz 下 −1.124 ns 与 C5 无关，需单独处理。

## 结果解释

综合 Fmax 与布线 Fmax 分别按对应报告呈现，二者都不等于已上板频率。
WNS、资源、最差路径、跨域报告和未布通数量分别记录。
没有运行布线时，routed Fmax/WNS/unrouted nets 记为未测，不能写零未布通。
各层同一 Core 的综合值会因 TCM、总线和其他模块的实际扇入/扇出变化而不同。

2026-10-26 历史 Core+TCM 为 104.712 MHz、26400 LUT/19663 FF/32 DRM/4 APM；
同日完整 YOLO 系统 Core/SYS/DDR-user/外设/NPU 为
89.3096/83.8926/144.6969/89.0076/112.3343 MHz，71659 LUT/66825 FF/162.5 DRM/86 APM。
这两组属于旧源码/镜像；日志曾被维护者清理，本轮新结果单独保留在
`$PDS_WORK_ROOT/work/four-branches-20261027/`，不能继承旧结果当作新验收。

旧 P0 有约 85 MHz 标准布线结果，后续源变化不自动继承。新 SoC 的 CDC payload/Gray
端点绑定、skew、DDR PHY/I/O 和板上启动仍需后续验收。不能用 false path 隐藏真实同步路径，
也不能修改约束数字来宣称时序闭合。

## 内存与启动

每阶段开跑前至少 6 GiB 物理与提交余量。WSL 的可回收文件缓存也可能占 Windows 提交预算。
本轮只对自己生成且闲置的构建文件使用 POSIX_FADV_DONTNEED，保留文件和日志；
随后再次查询 Windows 计数。未修改 pagefile、未终止无关进程。
综合结束/错误后记录结果，运行期间约十分钟查看一次即可。

bitstream 可包含 ROM/TCM 初值；配置 Flash 先恢复 FPGA 逻辑，CPU 才从 ROM 启动。
板上 DDR 初始化、软件搬运、Cache 维护和 UART 时基必须按实际域频率工作。
Flash 物理管脚接入与完整冷启动尚待板级验证。RT-Thread 仿真预装 DDR，
加速器仿真使用预装模型/输入；这些不等于 Flash 到 DDR 的完整上板流程已完成。
