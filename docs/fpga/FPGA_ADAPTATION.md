# FPGA 适配与 PDS

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。本文记录工具、流程、约束和结果，不把工具 Fmax 写成板上频率。

当前开发基线固定为 `baseline-rv32-soc-npu-20261027`，采用下面 `aaf63f9` 的系统
地址优化及 ROB16/四平台/NPU 配置；`e1598be` 只作为本地比较。发布快照与选定
测量源逐文件匹配，本次冻结未新增 RTL 或重跑 PDS。核级 104.7120 MHz 仍属于
继承的 `6cb7535` Core+TCM 测量；当前整机为 89.3096 MHz，未布局布线。

## AXI 地址递增候选（2026-10-26，aaf63f9）

`soc/tcm-stream-address@aaf63f9` 在 `6cb7535` 上只调整 scalar AXI 从口的 beat 地址
保存与递增边界，原请求/响应拍数不变。完整 SoC+NPU 使用相同 C1 时钟、ROB16、
冻结 2 次 TCM 固件和同份 DDR IP；标准综合估计如下：

| 域 | 目标 MHz | 6cb7535 Fmax MHz | 地址递增 Fmax MHz | 新 WNS ns |
|---|---:|---:|---:|---:|
| Core | 100 | 87.3057 | 89.3096 | −1.197 |
| SYS | 80 | 83.8997 | 83.8926 | +0.580 |
| DDR user | 125 | 144.7387 | 144.6969 | +1.089 |
| periph | 25 | 89.2698 | 89.0076 | +28.765 |
| NPU | 100 | 106.9633 | 112.3343 | +1.098 |

资源从 71,811 LUT/66,815 FF 改为 71,659 LUT/66,825 FF：LUT −152、FF +10
（+0.015%），DRM/APM 保持 162.5/86，0 latch。Core/NPU 分别提高 2.295%/5.021%；
其他域的估计上限略降，均仍高于既定工作目标。四层 CoreMark 的 24 项镜像、周期和
CRC 与 `6cb7535` 一致。Core/package 90 份源文件未改，核级 104.7120 MHz 仍属于
下节 `6cb7535` 的 Core+TCM 综合，不能当作本轮整机频率。

新 Core 最差 Store valid→地址/字节覆盖→双口请求选择→Load state，18 层、扇出 44，
数据延迟 10.711 ns。SYS 为读返回轮询指针到另一指针，15 层、扇出 434；NPU 为
MMIO 地址到 weight 写使能，13 层、扇出 34。原始 DDR→SYS/periph→SYS setup
−6.063/−3.072 ns、SYS→DDR hold −4.770 ns、DDR→PHY1 hold −1.138 ns，DDR 同域
hold −0.006 ns/3 端点仍保留；NPU 同域 hold +0.408 ns。CDC/PHY/I/O 仍待物理流程。

原生工程 `$PDS_WORK_ROOT/work/soc-tcm-stream-20261026/pointer-a/`，综合启动前
物理/提交余量 11.322/7.237 GiB；综合动作耗时 28 分 52 秒、工具池峰值 4432 MB。
摘要与对照在 `logs/soc-tcm-stream-20261026/{synthesis,synthesis-comparison}.json`；
仿真收据在 `build/soc-tcm-stream/20261026-a/`。未运行 P&R，布线 Fmax/WNS/未布通数未测。

`soc/tcm-local-decode@e1598be` 再复用现有 TCM 专用译码，双宽回归及 24 项 CoreMark
同周期/CRC 通过。组合工程 `local-decode-a/` 标准综合完成：Core/SYS/DDR-user/periph/NPU
为 90.9835/83.6400/144.7178/95.4563/111.7568 MHz，Core WNS −0.991 ns。
72,265 LUT/66,824 FF/162.5 DRM/86 APM，0 latch；比地址单项多 606 LUT、少 1 FF，
LUT 高于 `6cb7535` 454，不符合 LUT 减少门槛，未采用。
Core 最差 Store valid→转发/选择→整数 IQ packet，17 层、扇出 49。启动前物理/提交
9.738/6.402 GiB；综合动作 14 分 10 秒、峰值 4398 MB。摘要在
`logs/soc-tcm-decode-20261026/synthesis.json`；选定版本继续为地址递增单项。

## ROB16 联合候选标准综合（2026-10-26）

`core/lsu-shared-age-rob16` 采用 Load 分配沿提前请求、共享年龄矩阵、第二数据口只读
载荷裁剪、MDU FU 路由和 ROB16。正常 ALU/Load/DSP 流水保持 8/10/10；C 尚未实现。
Windows PDS 使用标准综合，Core+TCM 与完整 SoC+NPU 各自配对仿真源哈希和参数。

| 配置/域 | 目标 MHz | 同域综合 Fmax MHz | WNS ns |
|---|---:|---:|---:|
| Core+TCM / Core | 100 | 104.7120 | +0.450 |
| SoC+NPU / Core | 100 | 87.3057 | −1.454 |
| SoC+NPU / SYS | 80 | 83.8997 | +0.581 |
| SoC+NPU / DDR user | 125 | 144.7387 | +1.091 |
| SoC+NPU / periph | 25 | 89.2698 | +28.798 |
| SoC+NPU / NPU | 100 | 106.9633 | +0.651 |

Core+TCM 为 26,400 LUT/19,663 FF/32 DRM36K/4 APM，比原同顶层基线分别少
5,483 LUT、6,092 FF；DRM/APM 不变。最差 ISS packet→恢复/发射反馈→整数 IQ 数据口，
18 层、扇出 32。真实 TCM 短测为 3.012983/2.994267 CoreMark/MHz，64 次对照为
3.015015/2.996395；原基线 64 次为 2.724261/2.698377，使用相同 ELF/HEX。

完整 SoC+NPU 为 71,811 LUT/66,815 FF/162.5 DRM36K/86 APM，比初始 NPU 接入版少
7,517 LUT、6,331 FF，DRM/APM 不变。NPU AXI/CDC/设备子树为
7,751 LUT/11,179 FF/126.5 DRM/82 APM。完整组 Core 最差已转到 AXI `write_q[14]`
经地址计算、TCM 译码/bank 仲裁到 BRAM ADDRA，20 层、扇出 51；估计数据延迟
11.039 ns，其中逻辑 2.184 ns、连线 8.855 ns。核级频率不能代替完整组频率。
SYS 最差为复位释放→B 返回队列 CE，17 层、扇出 1942；NPU 为 MMIO 地址→bias
写使能，13 层、扇出 34。SYS 比初始 NPU 版低 0.0070 MHz，仍高于 80 MHz 目标。

原始 DDR→SYS setup −6.063 ns、periph→SYS −3.355 ns、SYS→DDR hold −4.680 ns、
DDR→PHY1 hold −1.138 ns，以及 DDR 同域 hold −0.006 ns/3 端点均保留。
NPU 同域 hold +0.408 ns；SYS→NPU/NPU→SYS setup +1.174/+1.194 ns，
hold +0.093/+0.179 ns。CDC 物理绑定、Gray skew、PHY 和 I/O 尚待物理流程验收；
没有用 false path 隐藏真实同步路径。

原生工程位于 `$PDS_WORK_ROOT/work/core-tcm-20261026/`：`admit-rob16-b/` 与
`rob16-soc-npu-b/`。启动前 Windows 物理/提交余量分别为 11.011/7.444 GiB、
11.992/7.141 GiB；合体综合工具池峰值 4389 MB。75 个 DDR IP 输入逐字节匹配初始
NPU 工程，源码配对记录为 `logs/npu-integration-20261026/rob16-source-pairing.json`。
该目录的 `core-tcm-rob16-synthesis.json`、`soc-npu-rob16-synthesis.json` 保存报告
和输入哈希。未运行 P&R，布线 Fmax、布线 WNS、未布通数和合体上板均未测。

## NPU 初始接入标准综合（2026-10-26，b16a026）

`soc/npu128-five-domain` 在 `main@a84ab1a` 上加入固定 YOLO `47ffb55` 的 128-MAC
核与 AXI/CDC。第五域采用 GPLL CLKOUT3、800 MHz VCO /8、独立 BUFG；前四域频率
保持不变。`--platform soc_npu` 使用与仿真配对的 Core/TCM 固件、完整 DDR IP 和
NPU 源码哈希，原始参数及命令保存在 `benchmark.json`。

| 域 | 目标 MHz | 同域综合 Fmax MHz | WNS ns |
|---|---:|---:|---:|
| Core | 100 | 84.4309 | −1.844 |
| SYS | 80 | 83.9067 | +0.582 |
| DDR user | 125 | 144.7387 | +1.091 |
| periph | 25 | 85.2806 | +28.274 |
| NPU | 100 | 105.7753 | +0.546 |

总资源 79,328 LUT/73,146 FF/162.5 DRM36K/86 APM，0 latch。相对下文完整 DDR 基线
增加 12,062 LUT/12,513 FF/126.5 DRM/82 APM；NPU AXI/CDC/设备子树为
7,752 LUT/11,179 FF/126.5 DRM/82 APM。全局总线和 DMA 接入成本包含在总差值中。
Core 最差 ISS→恢复→取指→TCM 数据口，16 层、扇出 75；NPU 最差
MMIO request_addr_q→weight_data_q/CE，13 层、扇出 34。NPU 同域 hold +0.408 ns。
原始跨域报告仍有 DDR→SYS setup −6.063 ns、periph→SYS −3.355 ns、SYS→DDR
hold −4.680 ns，DDR→PHY1 hold −1.138 ns；没有用例外隐藏这些端点。
新 NPU FIFO 的物理端点绑定与既有 CDC/PHY/I/O 检查须在物理阶段完成。

标准 Windows PDS 综合成功，工具池峰值 4683 MB；启动前物理/提交余量均 ≥6 GiB。
工程位于 `$PDS_WORK_ROOT/work/npu-integration-20261026/soc_npu/`，摘要在
`logs/npu-integration-20261026/soc_npu-synthesis.json`。未运行 P&R，布线 Fmax、
未布通数、bitstream 和合体上板未测。上游独立 NPU 板测结果不替代本工程验收。

## 上一基线（2026-10-25）

`baseline-rv32-soc-20261025` 固定当前 Core/SoC，统一测量入口为
`prepare_benchmark.py`，配置来自 `scripts/benchmark_platforms.json`。三组标准综合
已完成：Core+TCM、片上 SoC、完整 DDR3 SoC 的 Core Fmax 估计分别为
96.8523/91.7600/84.4523 MHz，对应 100 MHz 下 WNS −0.325/−0.898/−1.841 ns。
完整组 SYS/DDR 用户口/periph 为 84.8104/144.7178/90.9835 MHz；资源为
67,266 LUT、60,633 FF、36 DRM36K、4 APM、0 latch。完整表见
[项目介绍](../PROJECT_INTRO.md)。真实 TCM、Cache RAM 和 DDR 控制器/PHY 均保留。

本基线尚未布局布线，布线 Fmax 和未布通数未测。完整组最差 Core 路径经 ISS、
分支恢复、取指响应和 TCM 仲裁到 BRAM WEA，22 层、最大扇出 86。逐端点 CDC
绑定尚未完成；原始报告有 DDR→SYS setup −6.063 ns、periph→SYS setup −2.998 ns，
另有 DDR 同域 hold −0.006 ns/3 端点及 DDR→PHY1 hold −1.138 ns/52 端点。
真实同步失败须通过逻辑或物理实现处理。I/O delay、PLL 站点、bitstream/JTAG、
UART/DDR 板测与正式 CoreMark 留待后续。标准 PDS 每阶段入口检查 Windows 物理
可用和提交余量各至少 6 GiB；本次三组综合峰值分别为 2123/3148/4031 MB。

## S4 历史诊断

S4在 `fpga/s4-layered-characterization` 完成七组分层综合，入口 `e088a9d`。新增
`pango_measure_top` 三层诊断：H0 Core、H1 Core+TCM/Cache、H2完整软SoC至DDR AXI。
各域扫描输入保持/输出快照保留接口可控制性和可观察性；测量代码为 `eacef6a`。
生产RTL仅在 `3f7402a` 化简Flash位索引的等价除余表达式，解决原生 `bmsSREM`
不支持；其余174个生产RTL不变，P1 Core与默认fill4保持。独立Flash分支保留。
`prepare_measurement.py` 使用独立 `pango-layered-measurement-v1` 清单，显式记录
P1参数、fill4/8、C1/C4和源码哈希；`summarize_measurement.py` 分离扫描壳资源、
DUT资源和综合估算路径，布线Fmax字段在未实现时为空。

诊断工程入口（RV32；每次使用新的原生Windows盘目录）：

```bash
python3 scripts/pango/prepare_measurement.py \
  --output "$PDS_WORK_ROOT/work/<new-run>" \
  --layer H0 --clock-profile C1 --icache-fill-bytes 4
```

H1/H2只替换layer；fill8与C4必须显式选择。暂存后用现有 `run_phase.ps1` 的
synthesis阶段运行，再调用 `summarize_measurement.py <工程> --synthesis-log <原生日志>`。
输入清单含全部源文件、P1宏、实际时钟元数据和生成脚本哈希；TCM无固定固件，
由运行时可写接口保活，所以本诊断工程没有ELF/HEX。软件得分另绑定B20冻结镜像。

当前保守FDC只加载时钟、uncertainty与扫描IO预算，内部路径全部正常计时。
`proposed_cdc.fdc`保存待验证的定向例外，未加入工程。首次原生运行已发现编译库
复位pin与预想映射名不同；`pds_shell`未注册`open_dw`，后续 `open_design` 对象查询
因action参数类型错误退出。七组 `binding_audit_complete=false`，离线Tcl测试
不代表PDS实际绑定通过；不能把跨域slack转正当作CDC通过。

这些诊断顶层使用外部时钟端口及明确1ns扫描IO预算，不包含板级PLL和DDR PHY。
真实板级H3仍须generated-clock、PLL站点、DDR/复位和管脚约束验证。
本机旧place日志显示PG2L200H的GPLL/PPLL各10个，DDR占2 GPLL+2 PPLL；
新SoC PLL数量上可容纳，参考钟到合法站点的共存布局尚未验证。
七组输入、报告和网表哈希复核通过，器件为PG2L200H-6IFBB676，PDS单线程：

| 层次/配置 | 总LUT / FF | DRM / APM | Core综合估计MHz / WNS ns |
| --- | --- | --- | --- |
| H0 / C1 / fill4 | 42501 / 25996 | 0 / 4 | 36.8963 / −17.103 |
| H1 / C1 / fill4 | 48654 / 36189 | 36 / 4 | 36.6139 / −17.312 |
| H1 / C1 / fill8 | 48474 / 36188 | 36 / 4 | 36.8664 / −17.125 |
| H2 / C1 / fill4 | 82858 / 62615 | 40 / 4 | 37.0700 / −16.976 |
| H2 / C1 / fill8 | 82979 / 62614 | 40 / 4 | 36.9344 / −17.075 |
| H2 / C4 / fill4 | 83076 / 62614 | 40 / 4 | 36.5350 / −17.371 |
| H2 / C4 / fill8 | 83080 / 62613 | 40 / 4 | 36.5497 / −17.360 |

上述资源含测量壳，均0 latch，Core目标100MHz；不能用综合估计宣称实际频率。
H0原manifest记录提交前 `e088a9d` 与dirty清单，测量RTL哈希与 `eacef6a` 相同；
H1/fill4为干净 `eacef6a`，后五组为干净 `3f7402a`。7组共1274次输入哈希检查及
77份报告/网表检查均匹配；原始源码、命令、报告保存在各自原生目录。

Core前100条路径均集中在RAS恢复；旧r15/P2的ROB16/RAS关闭结果未覆盖当前
ROB32/RAS开启的34路恢复。H2/C1 SYS前100条均为同步复位释放到FIFO有效位/返回仲裁，
不能设false path；C4最差转为B响应选择/仲裁，fill4/fill8的SYS估计分别97.9336/95.4107MHz，
WNS−0.211/−0.481ns。四组DDR估计101.1429MHz均受扫描壳端点影响，尚未单列纯内部路径。
全部活动域的同域hold估计WHS均−2.523ns，没有setup/hold物理闭合。默认fill4保持。

双宽测量壳8 PASS/0 SKIP；修正后Flash定向/时钟4 PASS/0 SKIP，448成功读/7拒绝；
整机Flash/DMA C1双宽2 PASS/0 SKIP，RV32/RV64为64997/60241拍，覆盖跨域配置、
搬运/校验和Flash代码搬到DDR后执行。工具113 PASS/0 SKIP。本轮没有重跑通用
Core/ISA回归或CoreMark；B20固定镜像成绩保留原归属，不与综合估计相乘作为实际性能。

证据根 `logs/p2/s4-layered-20261023/`：`synthesis-batch-summary.json` 与
`final-batch-review.json` 为七组索引/复核，`flash-index-fix/summary.json` 与
`flash-integration/summary.json` 为修正后测试。测量壳原记录另在
`logs/p2/s4-physical-20261023/measurement/validation-summary.json`。精确stage、原生
命令及summary命令保存在每组 `<runid>-command.json`；原生目录为
`$PDS_WORK_ROOT/work/s4-layered-20261023/<runid>/`，H2旧失败尝试亦保留。

19:29批次结束后Windows物理可用16.610GiB、提交余量13.616GiB、提交上限35.781GiB，
PDS/DW为0；分页仍初始4/最大16GiB。完整标准布局尚未启动。H0已复制242个文件并
验签到 `h0-c1-if4-route-prepared`；建议入口46GiB提交/6GiB物理余量，随后每阶段
恢复双6GiB检查。46GiB由历史约39.34GiB进程提交样本加余量得出，不保证未来峰值。
标准入口使用 `run_phase.ps1 -Phase implementation`，继续dev_map/place/route/
route_optimize，不执行重放旧综合入口的 `impl.tcl`。没有改分页或结束无关进程。
当前没有新布线Fmax/85MHz验收；完整域表、容量方案与后续安排见工作区ITERATIONS B21和HANDOVER。

前一轮B20工作分支为 `soc/p2-p3-clock-study`，以 P1/P2 集成点 `0501f10` 为起点；
时钟复位提交另保留于 `fpga/p3-domain-clocks@1a4f8fa`。
P1 来自 `origin/main@91e33f7`，P2 完整保存点为
`baseline/p2-before-p1-20261023@f2b33b4`；集成时核对的 84 个 Core/包文件及
76 个 P2 SoC 文件分别与来源一致。B20 保留 P1 Core，新增 C1/C4 板级时钟、
协调复位和软件时基发现接口，完成相应仿真，没有重新运行综合、布局或布线。
当前组合的 RV32 ≥85 MHz 仍待标准 PDS 验收。

当前 scoreboard 工程采用下文的 schema 8，Core 默认为最终 P1 配置；
`logs/p2/p1-adapt-20261023/pango/summary.json` 保存 32 项暂存工具测试、
12 项时钟规划测试、双宽 full/lite 共 4 组 scoreboard wrapper 和 8 组 legacy wrapper
的结果，均 PASS、0 SKIP。厂商桩仅检查端口与展开参数，不模拟 DDR 校准。
以下 P1、P0 及早期 P2 测量分别保留其源码和工程归属。

P1.1a历史文档记录的源码为 `core/p1-1a-split-lq-sq@a23b65c`，LQ/SQ 拆分后保持 ROB16/IQ8。
本次S4没有找到下述P1.1a原生目录及JSON，没有重新复核这项历史数值。
标准综合、dev_map、place、route、route_optimize、report_timing 均完成，得到
86.1721 MHz、85 MHz WNS +0.160 ns、TNS 0、12 类 STA 零失败，57,149 条网络全部布通。
物理为 40,181 LUT、32,188 FF、36 DRM、4 APM、77 IO；综合为 37,486 LUT、32,057 FF、
零 latch。228 项输入哈希和 I/D-TCM 各 64 KiB 初值均匹配。最差路径由 Store 地址
经转发资格、提示标签、IQ 操作数选择到分支事件，20 级、11.135 ns，逻辑/布线
4.481/6.654 ns，最高扇出 38。证据为 `logs/p1/p1-1a/pds-result.json`，原生工程在
`$PDS_WORK_ROOT/work/p1-1a-lsq-split-20261022/soc-rv32`。85 MHz 为内部 STA，
IP 实际配置仍为 125 MHz，35/73 项 I/O 延迟缺失，未上板。

P1.1b `f547da3` 原生综合为 46,184 LUT、38,941 FF、36 DRM、4 APM、零 latch，
229 项输入及双 TCM 初值通过。标准布局完成，place 内存池峰值 14,879.289 MB；
布线第 13 轮仍有 24,179/69,295 条未布通、154,582 项 overused，主动取消中间运行。
只停止已核对身份和项目路径的自有 route，父 PDS 随后退出；没有最终 Fmax/WNS。
工程和原始报告保留在 `$PDS_WORK_ROOT/work/p1-1b-rob32-split-iq-20261022/`，
取消记录为 `logs/p1/p1-1b-drain/pds-cancelled.json`，`Flow-0189/-1` 随取消出现。
P1.3 选择 ROB32/int8/mem4、有限整数乱序、转发模式 3、Tournament/RAS。
`8c072c0` 完整回归为 RV32 237 PASS/4 SKIP、RV64 269 PASS/4 SKIP，八次 RV32 固定镜像
重放全部逐项一致。最终工程为 `$PDS_WORK_ROOT/work/p1-3-store-forward-tournament-20261022/soc-rv32`，
230 项输入哈希、216 个 HDL 及全部参数通过，全部 FDC 与 P1.1a 逐字节相同，未修改 false path。
综合入口物理可用/提交余量为 13.707/6.914 GiB，最终综合为 57,437 LUT、41,497 FF、
零 latch、36 DRM、4 APM、77 IO，230 项输入和双 TCM 各 64 KiB 初值全部匹配。
首轮标准实现入口为 17.859/20.725 GiB，place 入口为 17.314/20.179 GiB。标准 place
在 EP_DL 阶段申请 51,145,552 字节失败，耗时 10 分 15 秒、内存池峰值 20,193 MB；
没有进入 route，没有最终 Fmax/WNS，失败收据为 `logs/p1/p1-3-final/pds-place-failed.json`。
原工程及全部原始报告保留，未主动取消。已从综合完成快照复制到全新目录
`$PDS_WORK_ROOT/work/p1-3-memory-retry-20261022/soc-rv32`，283 个文件哈希一致，
230 项输入及双 TCM 初值复查通过，未重编 RTL 或改约束。
2026-10-22 22:57:13 +08:00 重试启动前物理可用/提交余量为 19.988/24.021 GiB，
额外 16/24 GiB 检查通过；place 入口为 19.826/23.847 GiB，标准各阶段仍检查双 6 GiB。
重试 place 在 EP_DL 申请 92,745,552 字节失败，耗时 6 分 8 秒、内存池峰值 22,191 MB，
23:03:59 自然退出，没有进入 route。Windows 事件 2004 在 23:03:57 记录
PDS 提交量 42,237,083,648 字节（约 39.34 GiB）及虚拟内存不足；
工具池峰值与进程提交量分别记录，该事件采样不覆盖完整运行峰值，
24 GiB 启动余量未能支撑此配置。系统按现有设置自动增长分页文件，仍发生分配失败；
没有手工修改分页或结束无关进程。
证据为 `logs/p1/p1-3-final/{retry-place-failed.json,retry-resource-event.json,retry-monitor.jsonl}`，
重试控制结果 `retry-controller-result.json` 为 FAIL。原工程、网表、两次失败日志和控制结果保留。
用户已要求暂停布局；最终 P1.3 没有 Fmax/WNS、物理资源、最差路径或未布通数量，
P1 的代码、仿真与综合结果已随 main 保留。后续明确恢复后再评估环境并使用新目录，
不直接重跑已失败的控制入口或覆盖日志。不能将 P1.1a 的物理结果代替最终 P1.3。

当前 P2 scoreboard wrapper 已接 `soc_system`、`ddr_axi_target` 和原生块桥。
双宽 full/lite 四种配置的离线展开通过；检查命令为
`python3 tb/tools/check_pango_wrapper.py --backend scoreboard --output <新目录>`。
默认不指定 backend 时仍验证 legacy 八种配置。桩只描述厂商端口元数据，
没有模拟 DDR 校准或倍频。本轮没有 PDS、资源或新 Fmax。

板级默认 profile 0 保留四路同接 125 MHz DDR 用户时钟及等待 DDR 校准的启动方式。
`BOARD_CLOCK_PROFILE=1/4` 已实现独立 SoC PLL 和 DDR 未就绪时的本地启动，
对应 C1/C4；频率、复位与仿真证据见第 7 节。Flash 容量仍设 0 且引脚未接。
C1/C4 尚未完成 generated-clock、PLL 站点、CDC 引脚及 DDR/reset/I/O 的物理约束验证。
以下 P0/历史 PDS 数据不能用于验收新总线。

## 1. 目标

- RV32 统一承担性能优化与完整 SoC 标准 PDS ≥85 MHz 验收；RV64 只做功能/ISA/SoC 仿真，不设性能门槛、不启动 P&R。
- 同域 Fmax、WNS、资源、最差路径和未布通网络一起记录。
- DDR PHY、外部 IO、UART、ILA 和十秒 CoreMark 单独验收。

默认 profile 0 使用 DDR IP 的 125 MHz 用户时钟；C1/C4 为新增候选。
历史报告未给出当前组合在这些时钟配置下的 setup 收敛结果，没有可交付 bitstream，
没有烧板。

CMP `2b49c77` 的 r12 已完成标准 PDS：87.8837 MHz、85 MHz WNS +0.386 ns、
TNS 0、零未布通；slow/fast setup、hold、recovery、removal、MPW、skew 均零失败。
物理 LUT/FF 为 46,457/32,096，36 DRM、4 APM。最差路径为 IQ 读指针到 DSP，
7 级、10.015 ns，高扇出 897。35 输入、73 输出仍缺 I/O 延迟约束。
历史 ISS `85ab1ca` 为 ALU/Load/DSP 8/10/10 级，完整双宽回归与八次重放通过；
r13 完整标准 PDS 为 82.8726 MHz、WNS −0.302 ns、86 个 slow setup 失败端点、零未布通，频率验收失败。每次原始报告与输入哈希均独立保存，详见
工作区 `ITERATIONS.md` 9.6。

完成预选 `180f6fc` 的 r14b 已完成标准综合、place、route、route_optimize 和最终
STA：82.7423 MHz、WNS −0.321 ns、TNS −0.759 ns、5 个 slow setup 失败端点，
其余 11 类 STA 零失败，57,902 条网络全部布通。物理 40,954 LUT、32,318 FF、
36 DRM、4 APM；最差路径为 LSQ 转发选择到分支接纳，18 级、11.675 ns。
周期与 ISS 保持一致，频率仍未达标。place 用时 8 分 18 秒、内存池峰值 9,305 MB；
route 用时 11 分 32 秒，各阶段入口双 6 GiB 均通过，运行最小物理可用/提交余量为
8.272/0.682 GiB，无内存分配失败。源与报告绑定在
`logs/pipeline/preview-180f6fc-20261021/pds-result.json`。

历史 P0 `dffb8a2` 的 r15 标准 PDS 已完成：**85.2464 MHz、85 MHz WNS +0.034 ns、
TNS 0、零未布通**，12 类 STA 均无失败，57,382 条网络全部布通。物理为
40,154 LUT、32,318 FF、36 DRM、4 APM、77 IO；比 r14b 少 800 LUT，FF 不变。
相对 r14b，Fmax 提高 3.03%；比 CMP 的 87.8837 MHz 低 3.00%。
用户已确认按 8–10 级结构、CoreMark/MHz 不回退和标准 PDS ≥85 MHz 冻结 r15 为新 P0。
CMP 是 7 级 ALU 诊断点，不作为本次冻结门槛。原 `p0-acceptance.json` 保留当时
与 CMP 比频率的失败记录，原始数值和判据没有改写。发布基线为 `publish/p0-r15`，
发布仅含当前 P0 文件的一次提交，不带开发历史；原开发和历史阶段分支全部在
本地保留。后续 RTL 优化从独立分支开展。
r15 最差路径从 LSQ 地址比较，经 Store 转发资格、请求选择、提示完整标签和 IQ
匹配/数据选择到分支下一 PC，19 级、11.183 ns；逻辑 3.588 ns、布线 7.595 ns，
路径最高扇出 76。place 20 分 20 秒、峰值池 10,058 MB；route 11 分 28 秒，
route_optimize 1 分 4 秒。各阶段入口双 6 GiB 全部通过，实现期间采样最小物理
可用/提交余量为 6.129/0.464 GiB，无内存分配失败。综合为 37,678 LUT、32,188 FF、
36 DRM、4 APM、0 latch；226 项输入、212 个原生 HDL 和双 TCM 初值均通过。
同源结果为 `logs/pipeline/forward-format-dffb8a2-20261021/pds-result.json`；
原联合判据为同目录 `p0-acceptance.json`，其中对 CMP 的频率不回退项失败；
用户随后决定采用上述 P0 冻结依据，原报告保留。
35/73 项 I/O 延迟仍缺失，85 MHz 裕量为 0.034 ns，未验证板上运行。

2026-10-22 新 SoC `soc/p2-unified-bus@e3caafe` 完成一次标准 PDS：
97,358 条网络全部布通，0 未布通/0 过使用；Fmax **84.9856 MHz**，
WNS **−0.002 ns**、TNS **−0.002 ns**，1/184,374 个 slow setup 端点失败；
slow/fast hold、recovery/removal/MPW/skew 零失败。CLMA 47%、LUT 41%/39%、
FF 17%、DRM 9%、IO 20%。最差路径为 LSQ descriptor 到 branch_event_valid，
21 级，logic 3.926 ns、route 7.266 ns、扇出 35。未达到 85 MHz；四域仍同接
`core_clk`，35/73 项 I/O 延迟仍缺，不能当作独立 CDC 或板级结果。
结构化结果和哈希在 `hgb-aisystem_riscv/logs/pipeline/p2-unified-bus-20261022/`。

2026-10-23 的 `fpga/p3-c1-board-physical` 增加 C1/C4 物理暂存：`prepare_project.py`
的 `--board-clock-profile` 生成 schema 9 和 `board_clocks.fdc`，从
`g_domain_clocks.u_soc_pll.u_pll/CLKOUT0..2` 建立 `clk_core`/`clk_sys`/`clk_periph`
generated clock。profile 0 保持 schema 8 和原 `compile.tcl`。第三版 C1 暂存
`soc-rv32-c1c` 通过 258 个字节哈希和 557 条约束检查（0 error、18 warning）。
C1 综合 PASS，20 分 55 秒、峰值 4,025 MB；76,298 LUT/159,800、61,092 寄存器/319,600、
36 DRM/415、4 APM、0 latch。综合估计 `clk_core` 36.5150 MHz（WNS −17.386）、
`clk_sys` 84.1326 MHz、`clk_periph` 73.0514 MHz、`ddrphy_sysclk` 144.7178 MHz。
未加载 CDC 例外时，ddr→sys setup −6.063 ns/556 端点、periph→sys −2.998/36；
hold sys→ddr −4.680/772、ddr→phy_dq_sysclk_1 −1.138/52。这些不是闭合结果。
约束不含 clock group、false path、max_delay 或 I/O delay；PLL 站点、DDR IP 共存、
CDC 绑定和板级链仍未完成。当前机器没有 FPGA/JTAG 设备，没有 bitstream 或烧板。
Core 的 36.5 MHz 综合估计来自 `ras.sv` 的 34 级串行恢复链，旧 r15/P2 的 85 MHz
不覆盖当前 P1 Core。

## 2. 工具与目录

- PDS：`$PDS_HOME\bin\pds_shell.exe`。
- 工程根：`$PDS_WORK_ROOT\work\timing-YYYYMMDD-<topic>`，每次新目录。
- `reference/` 只读。
- 生成 IP、网表、工程、原始日志和报告都放 `$PDS_WORK_ROOT`，仓库只保留源码、脚本和摘要。

运行前查 Windows 可用提交。常规 place 曾在 EP_DL 大块分配失败，历史快速布局
数据仅作对照。当前使用单线程标准 `place`，布线与优化保持 Normal 模式；
`r8-route4` 为复用同一布局的 4 线程布线实验，
不自动回退快速模式。不改分页、不终止无关进程、不烧板。

启动前先清理确认可丢弃的本项目遗留进程，避免与仿真、编译并发。
WSL 文件缓存也会占用 Windows 物理内存和提交余量；先对本项目非可执行生成
文件释放可丢弃缓存，保留源码、镜像、日志及数据库，再读取 Windows 字节计数。
WSL 的 `MemAvailable` 不能替代 Windows 指标；禁止将其他 agent 的任务当作遗留进程。
`memory_gate.ps1` 同时要求 Windows 物理可用量和提交余量至少 6 GiB，按原始
字节判断，查询失败即拒绝。双 6 GiB 仅为脚本最低门槛，不能视为当前 P1+P2
工程的容量保证；P1 两次 OOM 中，第二次已有 24.021 GiB 启动提交余量仍不足。
未来恢复 PDS 前需结合约 39.34 GiB 的进程提交采样及额外余量重新评估环境。
更高的流程门槛通过 `HGB_PDS_MIN_PHYSICAL_GIB`、
`HGB_PDS_MIN_COMMIT_GIB` 保留，不能设为低于 6。每次查询保存独立 JSON。
暂存工程包含两个内存检查脚本及哈希；`implement.tcl` 在 dev_map、place、route、
route_optimize 前逐次检查。新工程用 `scripts/pango/run_phase.ps1` 的
`-Project <工程.pds> -LogDirectory <新日志目录> -Phase synthesis|implementation`
入口，`PDS_HOME` 指向 Windows PDS 安装目录。旧工程和旧日志保留原状。
入口在 Windows 本地工程目录运行，避免 UNC 工作目录限制。若继承的 `PATHEXT`
缺少 `.EXE`，仅为当前启动进程和 PDS 子进程临时补齐，完成后恢复；不修改用户或
机器环境。原生调用失败或没有有效退出码时不能算成功。可用
`tb/tools/test_pango_native_launch.ps1 -OutputDirectory <fresh-test-directory>`
在 Windows 实测这条启动路径、stderr 和失败退出码。
综合只接受尚无 `.pds` 的新目录；实现阶段仅传 `-file implement.tcl`，由 Tcl 打开
已综合工程，并先保存原生 `.pds` 副本。不能给实现阶段传 `-project_name`：该参数
会先强制新建同名工程，丢失设计输入列表。r11 的这次入口错误保留在工作区记录中，
后续使用新目录重新综合，不手工拼接不完整的原生工程。

## 3. 流程

```text
WSL loader 构建
  → prepare_project.py 暂存 RTL/IP/固件
  → verify_synthesis.py --staging-only
  → pds_shell compile + synthesize
  → check_tcm_init.py 核对 ITCM/DTCM INIT
  → dev_map -force_to_run
  → place
  → route
  → route_optimize
  → report_timing -max_path 100 -nworst 1
  → timing-summary.json
```

当前暂存入口为 `prepare_project.py --core-backend scoreboard`，生成 schema 8，
明确记录 `soc_system` 拓扑和最终 P1：i2、ROB32、int8/mem4、split=1、有限整数
乱序=1、转发模式 3、Tournament/RAS、LQ4/SQ4、checkpoint4、IF64、双数据口。
Python 入口直接采用这组默认值；仿真入口须先
`source scripts/verilator/p1_core_config.sh`。单项 CLI 参数可显式覆盖，覆盖后的
配置标为 `custom`；校验器核对配置与 Tcl，不能仅凭 `p1` 名称认定参数生效。

新 SoC 固定本地 TCM，省略 `--local-tcm` 时记录有效值 1，显式 0 会拒绝。
Tcl 不再给 scoreboard wrapper 传递 `LOCAL_TCM_ENABLE`、`DMA_WIDE_ENABLE`、
`CACHE_BLOCK_ENABLE`、`DMA_BLOCK_ENABLE` 四个 legacy 开关。schema 8 暂存仍只接受
默认 `BOARD_CLOCK_PROFILE=0`：四个端口同接 DDR 用户时钟 125 MHz，`mtime` 归属
periph 域。校验器检查默认值、同钟分支接线和频率声明，拒绝改写元数据或接线后沿用
原声明。C1/C4 的 PLL/复位 RTL 已实现，但没有通过此暂存入口交付其物理工程；
`plan_soc_clocks.py` 生成的规划也不能代替实际 generated-clock、PLL 站点、
Gray max-delay/skew 与板级引脚约束。后续须为候选补齐并校验约束后再启动标准 PDS。

历史 schema 1–7 仍按原命令校验；P1 schema 7 的 ROB32/调度参数保留。
合入 P1 前的 P2 schema 4 省略 legacy 参数时，还须存在已覆盖哈希的 `soc_system`
wrapper。`--core-backend legacy` 继续生成 schema 3；`scripts/pango/build.ps1`
也仍是 legacy/schema3 入口，不能用它代表新的 P1+P2 profile。
manifest 保存源码提交/分支、工作树状态及每个暂存文件的 SHA。
本节暂存检查只生成和校验离线配置；B20 另有第 7 节的功能仿真，未启动后续 PDS 阶段。

原始 64 KiB `firmware/{i,d}mem.hex` 同时生成 `.bank0`/`.bank1`，按 XLEN 字
交错切分；校验器检查每份 bank 的哈希以及与原图像的逐字对应。
`check_tcm_init.py` 另从综合网表的地址/输出连线及全部 INIT 参数重建内容：
旧 RV32 使用 16K×2，新 RV32 为两个交错 bank，各八个 8K×4 DRM。
新 RV64 的 4K×8/9 模式由厂商模型及工具测试覆盖；r7 的实际 RV64 网表也已
完成两块 64 KiB TCM 的全字节校验，每块使用 16 个 DRM。
未知连线、缺失 INIT、重叠输出位均拒绝。`timing-20261021-p0-scoreboard-r2`
的 RV32 两个 TCM 各 64 KiB 已全部匹配；新旧映射及证据输出的八项工具测试通过。
历史 scoreboard RV32 配置综合映射为 36 DRM、4 APM、0 latch；RV64 为 38 DRM、12 APM、
0 latch。旧 RV32 控制组仍要求 34 DRM、4 APM，RV64 旧核映射尚未纳入校验入口。
`verify_synthesis.py` 按位宽和后端分别检查，41 项 PDS 交接工具测试通过。
r2/r3 的默认标准 place 均在 EP_DL 阶段内存分配失败，尚无有效布线时序结果。
r3b 的 `logic_optimize_lut_cascade` 被器件拒绝，未进入布局；通用帮助中的选项
不保证适用于本器件。r4 `769d739` 使用标准 `place -logic_optimize_lut6d FALSE`，
仅关闭 LUT 拼合，命令及资源/时序另列。综合为 41,182 LUT、31,381 FF、
36 DRM、4 APM、0 latch；两块 TCM 全部 INIT 匹配，布局仍在 EP_DL 内存失败，
峰值工具池 17,312 MB。关闭 LUT 拼合没有解决该失败。
后续独立关闭单元复制或宏优先仍在 EP_DL 内存失败。r7 `555453f` 的综合资源为
RV32 40,530 LUT / 31,682 FF，RV64 61,614 LUT / 44,319 FF；双宽均通过源输入、
资源与 TCM 初值核对。r8 `fdb3ffb` 对 ROB 完成到退休分拍，RV32 综合为
41,793 LUT、31,682 FF、36 DRM、4 APM、0 latch；最差路径从 29 级、
19.389 ns 降至 19 级、13.177 ns，综合 WNS −2.043 ns。源输入、TCM 初值通过。
RV32 标准 PDS 的首次启动因可用提交仅 2.663 GiB 而在运行前被脚本拦下，
该次没有启动综合。释放自有编译页缓存后重试完成，标准布局用时 12 分 6 秒，
工具池峰值 7,682 MB，运行前可用提交 9.327 GiB。单线程 route 第 8 轮耗时
818.903 秒、剩余 38,942 个未布通网络后人为中断；日志和进程身份记录均保留。
`r8-route4` 新目录复用原布局，228 项哈希核对通过，在 8.411 GiB 可用提交下
运行 `route -force_to_run -route_mode normal -number_of_router_thread 4`
并用 `-input_place_db_file` 显式指定复制的布局数据库。原 RTL、器件、IP、
85 MHz 约束均相同；该次布线后来按用户要求中断，没有最终时序。

`summarize_timing.py` 自动读取可选的 `placement-reuse.json`：核对原工程与新工程
全部源输入、网表、TCM 初值证据、布局数据库、原始布局日志的哈希；要求原工程
最后一次成功布局为默认标准 `place`，并确认新 route 实际使用该数据库及声明的
Normal 模式和线程数。原布局和新布线成功标记分别检查，缺一不能汇总成完成结果。
资源表的日志来源另存入摘要。新增 7 项布局复用拒绝/接纳测试后，PDS 工具共
48 项通过；未改变硬件。
`check_tcm_init.py --summary <new-json>`
可在两块 TCM 全部匹配后创建证据，绑定 manifest、网表和 HEX 哈希，拒绝覆盖已有报告。

历史 P0 候选参数：`CORE_XLEN=32`、`MUL_IMPL=0`、`DIV_IMPL=1`、
`CORE_BACKEND=scoreboard`、`ISSUE_WIDTH=2`、`RETIRE_ENTRIES=16`、
`SOC_PROFILE=full`、`LOCAL_TCM_ENABLE=0`、
`DMA_WIDE_ENABLE=1`、`CACHE_BLOCK_ENABLE=1`、`DMA_BLOCK_ENABLE=1`。

## 4. 旧控制组完整布线结果

2026-10-20，源码 `c24ff08`，工程
`$PDS_WORK_ROOT\work\timing-20261020-i2-rv32`（参考机器的实际值见交接记录）。

| 指标 | 结果 |
|---|---:|
| 同域 Fmax（`ddrphy_sysclk`） | 65.4279 MHz |
| 125 MHz WNS | −7.284 ns |
| setup 失败端点 | 16614 / 78712 |
| 物理 LUT / FF | 24888 / 20140 |
| 综合 LUT / FF | 19033 / 20085 |
| DRM36K / APM | 34 / 4 |
| latch / 未布通 | 0 / 0 |
| 同域 hold | +0.061 ns |
| DDR PHY 跨域 | −0.061 ns |
| 外部 IO 约束 | 35 输入、73 输出缺失 |

与 `19562a9` 的 84.7314 MHz 相比下降 22.8%；LUT 增加 29.6%，FF 增加 56.2%。

关键路径：

```text
reset_sync_q[1]
  → retire_gpr_query
  → ex_operand_register
  → mul_unit/g_dsp.../Z
```

8 级逻辑，数据延迟 13.696 ns（逻辑 4.538、布线 9.158）。前 100 条 SoC setup
路径全部从 `reset_sync_q[1]` 出发。DDR IP 自身最差只有 −0.061 ns。

## 5. 旧端口默认值问题

PDS 2025.2 拒绝 SystemVerilog input 端口默认值，I2 有 89 处、23 个文件。
该旧检查点按原样不能综合；其结果来自 F: 暂存副本删除默认值后的版本，补丁在
`$PDS_WORK_ROOT\work\timing-20261020-i2-rv32\portability-patch.diff`。
`c04c588` 已将修正纳入仓库，历史 P0 从干净提交暂存并核对全部源哈希。

## 6. 十三轮 Fmax

| 轮次 | Fmax RV32/RV64 (MHz) | 主要代价 |
|---|---|---|
| 01 | 41.75/35.80 | 未单独测 |
| 02 | 47.57/38.96 | TCM 乘积 −4.9%/−7.5% |
| 03 | 43.39/33.87 | TCM 周期恢复 |
| 04 | 55.86/43.45 | TCM −70.8%/−71.5% |
| 05 | 55.78/45.61 | 基本不变 |
| 06 | 64.59/46.99 | Core-only −16.6%/−15.0% |
| 07 | 62.23/49.85 | Core-only −2.2%/−2.0% |
| 08 | 65.20/58.07 | 普通除法 +1–2 拍 |
| 09 | 73.56/60.16 | 不变 |
| 10 | 60.76/55.67 | Core-only −10.4%/−9.5% |
| 11 | 80.60/67.91 | 不变 |
| 12 | 68.39/63.15 | 不变 |
| 13 | 84.73/81.85 | 不变 |

十三轮说明：布线和布局对结果影响大；插寄存器不一定切断所有控制依赖；删掉一条
路径也不一定缩短全局最差路径。

## 7. 时钟、复位与软件时基

`pango_200hp_top.sv` 的 `BOARD_CLOCK_PROFILE` 独立于 full/lite 外设配置。
以下为 RTL 声明及仿真采用的频率，单位 MHz，不是布线 Fmax：

| 板级配置 | Core+TCM+I$/D$ | SYS：AXI/DMA/Flash 数据面 | DDR 用户口 | PERIPH：MMIO/Timer/UART/IRQ | 启动条件 |
| --- | --- | --- | --- | --- | --- |
| 0，默认及 schema 8 暂存 | 125 | 125 | 125 | 125 | 等 DDR PLL、PHY 和校准就绪 |
| 1，C1 候选 | 100 | 80 | 125 | 25 | SoC PLL 锁定后可执行 ROM/TCM/MMIO |
| 4，C4 候选 | 100 | 100 | 125 | 25 | 同 C1 |

板级 profile 0 不等同于便携测试的 C0；测试 C0 为四域 100 MHz。
Core 与 TCM/Cache 当前保持同域，M0/M1/M2 测量层次也不与时钟域一一对应。

`pango_soc_pll.sv` 使用 `GTP_GPLL` 和三个 `GTP_CLKBUFG`。125 MHz 参考经 `/5`
形成 25 MHz PFD，反馈配置形成 800 MHz VCO；Core `/8`、SYS `/10` 或 `/8`、
PERIPH `/32`。DDR 继续使用 DDR IP 自身的 125 MHz 用户口。SoC 三路同源相关，
与 DDR PLL 输出的相位关系须在物理工程中确认，不能仅因频率不同而全域设 false path。

C1/C4 的 `pango_soc_reset.sv` 在持续运行的参考钟域管理复位。首次启动只等
板级复位和 SoC PLL；DDR 未校准或停钟时，Core 可从 Boot ROM 进入 TCM 并访问 MMIO。
DDR 曾就绪后，锁定/ready 撤销经同步器触发整机复位；DDR 停钟由 heartbeat 看门狗检测。
复位保持 64 个参考周期，各功能域经 `soc_reset_controller` 三拍同步释放；
heartbeat 计数器也有 DDR 域三拍释放。DDR 控制器、AXI target、块桥和 CDC 两端
共同进入新一轮复位，丢弃在途事务。默认 profile 0 保留原 `reset_sync_q` 路径。
DDR IP 的 `resetn` 接口释放要求、复位 recovery/removal 及实际网络延迟仍需物理核对，
本轮没有新增复位时序例外。

`soc_info` 的旧 `+0x004` 字段保持原 ABI。新增窗口先由 `+0x03c` 的 bit 8 宣告，
启用后 `+0x050` 为版本/有效位，`+0x054/058/05c/060/064` 分别返回
Core/SYS/DDR/PERIPH/Timer 的 Hz；Timer 等于 PERIPH。C1/C4 wrapper 启用此窗口，
profile 0 默认关闭。寄存器返回配置值，不能代替时钟测量或 STA。

`software/common/soc_clocks.h` 在发现位缺失时仅读取旧字段；发现位存在时校验新窗口。
RT-Thread 的 tick 和超时采用 Timer 频率，UART 分频采用 PERIPH，SPI 分频采用 SYS，
CoreMark 的 `mcycle` 换算采用 Core 频率。旧 `CLOCK_HZ` 不再承担所有独立域的时基。
软件时基测试检查寄存器、UART/SPI 分频配置和约 1 ms 内的 `mtime/mcycle` 比例，
不发起 Flash 读，也未验证板上串口波形。

B20 的以下仿真均已完成，日志根为 `logs/p2/joint-step3-20261023/`：

| 检查 | 结果 | 证据与边界 |
| --- | --- | --- |
| C1/C4 PLL 与复位/FIFO 专测 | 3 次运行 PASS，0 SKIP | `board-clocks/suite-v4/receipt.json`；PLL 使用未修改的厂商 GPLL/CLKBUFG 模型，检查输出周期；复位覆盖 DDR 停钟、PHY/ready/SoC PLL 失效及旧事务清除 |
| 双 XLEN 独立启动，C1/C4 | 4 次运行 PASS，0 SKIP | `system-rv32/boot/`、`system-rv64/boot/`；真实 CPU 执行 ROM→TCM→MMIO，外部 AXI 主口在 DDR 停钟时获得错误响应；复位后无旧响应，新请求返回正确 ID |
| 双 XLEN SoC 功能，C0–C4 | 10 次运行 PASS，0 SKIP | `system-rv32/soc-system-*.log`、`system-rv64/soc-system-*.log` |
| 双 XLEN 软件时基，C0–C4 | 10 次运行 PASS，0 SKIP | 同目录 `clock-contract-*.log`；C2/C3 为 CDC 仿真组合，未提供相应板级 PLL profile |

实际命令、输入和日志哈希见各自 receipt/manifest；软件镜像由整机测试 manifest 记录。
PLL 模型测试与独立启动测试分开运行；
独立启动使用测试时钟与受控 AXI 端口，没有模拟 DDR PHY 校准，也没有运行完整板级
PLL+DDR PHY 联合模型。`check_pango_wrapper.py` 的厂商端口桩展开仍只验证接线和参数。

新增 PLL、复位监督器和 Cache 安装候选尚无综合/物理资源数据。历史 I2 的物理
FF 20,140 及 perf/full 资源建议保留为旧配置参考，不能作为当前 P1+P2 的资源统计。

## 8. 板级边界

- 当前组合的 profile 0/C1/C4 均无新增 PDS 结果，没有可交付 bitstream；RV32 ≥85 MHz 待验。
- 旧控制组 DDR PHY 跨域曾为 −0.061 ns；当前集成版没有新增物理结果，外部 IO 约束仍缺 35/73。
- 未验证板上 DDR 颗粒、校准、UART、ILA、功耗。
- 没有十秒 CoreMark。
- C1/C4 已有 PLL、复位和 CDC 功能 RTL；generated-clock、PLL 站点、CDC 引脚约束以及 DDR/reset/I/O 时序尚未 PDS 验证，不能只改 FDC 数字宣称闭合。

## 9. 原始证据

历史工程在 `$PDS_WORK_ROOT\work\timing-20261016-*` 和 `timing-20261020-i2-rv32`。
历史流水拆分使用 `timing-20261021-pipe-head-r11b`、`pipe-completion-r12`、
`pipe-issue-r13`、`pipe-preview-r14b`、`lsu-forward-format-r15` 对应的新目录，
完整目录名见工作区记录；包含 manifest、网表、
原生工程、日志和时序报告。仓库不提交二进制、网表或原始工具报告。
