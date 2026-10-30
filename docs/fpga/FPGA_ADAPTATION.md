# FPGA 适配与综合

## 当前应用时钟与PDS入口

2026-10-30，main为无NPU完整系统，C9 `main_margin2`：
Core/SYS/DDR-user/外设为88.75/98.611111/125/68.269231 MHz。
系统GPLL输入125 MHz，I/M/F=10/1/71，VCO887.5 MHz，输出分频10/9/13；
DDR用户钟125 MHz由DDR IP提供。PLL、FDC、TB、频率寄存器和软件时基使用同一profile。
main不保留RT-Thread或NPU，RT仅在all。YOLO独立分支采用C10并由A负责，main和MiniMind由B负责。

本轮统一8线程、timing-v2：fanout64、retiming开启、算术资源共享关闭、normal布局/布线、
双输出LUT合并关闭、route时序权重80、GP/route recovery和route_optimize开启。
旧timing-v3的128/90保留；fast不使用，PDS2025.2的place/route不支持performance模式。

完整交互固件为`build/coremark-board/rv32-O3-i0-b115200`，生产ID `ea1773fca42aa7c6`。
冻结目录保留program.elf、20项源/HEX身份，生产test_iterations=0；
上电READY后回车/P运行performance，V运行validation，返回64位周期/CRC、DONE、READY。
软件从实际硬件频率寄存器取得UART和计时参数，正式计分需运行至少十秒；尚无板上成绩。
双宽旧C6短流程已通过，迭代2、500000 baud、formal=0，不替代正式成绩。

硬件82cbf7a、I16/D8/hash2的完整C9综合估计如下；综合阶段Core低于所选工作档，后续布线结果单列。
新旧时钟、综合/物理策略和RTL有差异，不能把差额归因单项修改。

| 域 | 目标MHz | 综合估计Fmax MHz | setup WNS ns |
|---|---:|---:|---:|
| Core | 88.75 | 83.5307 | −0.704 |
| SYS | 98.611111 | 110.0987 | +1.058 |
| DDR user | 125 | 144.7387 | +1.091 |
| 外设 | 68.269231 | 93.3476 | +3.935 |

综合LUT56468、FF60595、DRM38、APM4、latch0。原件在
`$PDS_WORK_ROOT/work/release-ab-20261030/main-coremark-r2/`，
本地摘要为`logs/release-ab-20261030/main-synthesis-summary.json`。
最差综合路径是ISS操作数经branch、issue许可和early广播返回memory IQ/ISS；
18级，data11.485 ns，其中logic2.245、估计net9.240 ns，最大扇出64。
### 本轮完整布局布线

唯一一次P&R于2026-10-30 14:06正常退出，原生用时1h33m04s；固件、IP和时钟与上表同一冻结输入。

| 域 | 工作档MHz | 布线Fmax MHz | setup WNS ns |
|---|---:|---:|---:|
| Core | 88.75 | 90.3702 | +0.202 |
| SYS | 98.611111 | 107.5410 | +0.842 |
| DDR user | 125 | 131.9784 | +0.423 |
| 外设 | 68.269231 | 78.5252 | +1.913 |

0未布通；LUT75364（含常量/旁路）、FF60590、DRM36K38、APM4。
slow/fast hold最小+0.054/+0.042 ns，recovery+2.871/+4.823、removal+0.363/+0.222、MPW均+0.035，失败端点均0。
CDC max-delay最小+3.278/+6.125，Gray skew+6.402/+6.688；同域/第二同步级误例外0。
DDR PHY的ddrphy_sysclk→phy_dq_sysclk_1仍有1端点setup−0.028 ns，
实际是phy_wrdata_en_d[0]→DQS group1 TS_CTRL[2]，6.019 ns中线路5.511 ns，占91.6%。
I/O缺35输入/73输出delay，尚无bitstream/板测；只能确认C9四工作域通过，不能宣布整机全部闭合或Core100 MHz达标。

实际Core最差转为retire generation→LSU选择→store hint broadcast[9]→integer IQ packet CE，
14级、扇出156、data10.268 ns=logic2.745+net7.523，线路占73.3%。
报告的100条Core slow路径中77条经过store hint[7–10]，其余最差为head copy→IQ packet D、WNS+0.307 ns。
七广播候选须与真实TCM效率一起验证；去掉hint后仍有接近的非hint路径，不能据此承诺100 MHz。
旧90.6208到本轮90.3702 MHz为−0.28%，SYS/DDR/外设能力提高，FF少3463；配置、策略、RTL均不同，不能分摊为某项优化收益。
DDR用户域已通过125 MHz，原读缓冲候选移后；PHY使能那1条负路径须单独处理，不能靠改DDR用户侧载荷清零逻辑代替。

本轮devmap9m21、place9m46、route1h08m36、opt2m55；工具池峰值12995 MB，route峰4946 MB。
入口与大阶段双6 GiB门禁通过，运行中提交余量可低于6 GiB，日志保留实际样本；未改分页或停止无关进程。
原始报告在上述Windows工程，摘要、完整路径和精确命令/哈希在
logs/release-ab-20261030/main-physical-r1/{physical-receipt.json,actual-worst-paths.txt}。

### 新工程和原生CDC

先设置RISCV_TOOL_ROOT、PDS_HOME和PDS_WORK_ROOT；生成DDR IP目录必须包含pnr/ddr_test.fdc及pnr/ddr3_test.rcf。
下列命令在WSL执行，PDS_WORK_ROOT使用/mnt盘符映射，输出用未存在的新目录：

```bash
make coremark-board XLEN=32
python3 scripts/pango/prepare_project.py \
  --output "$PDS_WORK_ROOT/work/main-c9-new" \
  --ip-dir "$PDS_WORK_ROOT/work/clocks-c5-yolo-20261029/ddr-ip/candidate/ddr3_test" \
  --xlen 32 --core-backend scoreboard --board-clock-profile 9 \
  --soc-profile full --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2 \
  --firmware-dir build/coremark-board/rv32-O3-i0-b115200 \
  --firmware-role coremark-interactive --synthesis-strategy timing-v2
```

兼容入口默认仍为旧时钟和4/4 KiB，不能省略上面的profile/Cache参数。
Windows PDS先用scripts/pango/run_phase.ps1的synthesis阶段编译；
用summarize_benchmark.py解析该次日志，prepare_cdc_audit.py生成查询，
在原生open_design的synthesize动作内查询对象与时钟根，再以--bind-log发布
backend_sync.lcf、backend_cdc.scf和scope收据；implementation默认implement_cdc.tcl。
query_cdc.tcl通过Windows环境HGB_PDS_PROJECT打开已有.pds，
implementation不再创建工程；只open_project后的延迟句柄不计原生绑定证据。
两份约束必须在dev_map前加载，第二同步级、普通同域、复位和DDR PHY继续检查。

main本轮绑定31 FIFO、442同步FF、93 max-delay和60 max-skew；
YOLO还包含视频FIFO及同步器，必须使用它自己的原生清单，不能套main对象数。
新C9的分层CoreMark由B从当前P2源重新构建并冻结bundle，旧ELF拒绝C9/C10。
原有分层分数继续保留为旧档测量。

### RCF补充与I/O分类

HMIC_S手册UG042003的PDF第67页要求自建工程导入生成的pnr/*.rcf，
PDS Tcl手册UG990004的add_constraint条目支持.rcf。
本轮原始main/YOLO暂存未加载该文件；厂商例程本身也可能有缺项，不能将增加文件当作物理修复已通过。
新prepare_project精确冻结pnr/ddr3_test.rcf原字节为board_ddr.rcf，compile.tcl加载一次，
manifest绑定SHA和两条ioclk_gate优先网。它们与当前adj_wrdqs_en负路径不同。
原始RCF SHA256为01a316eaa22fb40512d6d7948533b18296e2cc2860469bbf1ae8dbf0fe872002。
旧manifest继续可核验且明确RCF未验证；115项工具测试通过，没有重跑PDS或修改原件。

新离线交接输入在$PDS_WORK_ROOT/work/release-ab-20261030/main-c9-rcf-inputs，
真实程序、244份HDL、C9与64/80策略保持，尚未运行综合/PDS。B先核两条原生网名和RCF实际加载，再按同配置比较。
PHY的同一路径从旧+0.089到新−0.028 ns，损失117 ps：数据线路+96、逻辑+6、发射时钟+15 ps。
DDR FDC和75项公共IP哈希相同。单branch MPNR建议仅作为B的未执行候选，本机不启动probe/ECO。

35输入/73输出中的103条为DDR方向条目（双向DQ会计两次），其余5条为
差分时钟负端、异步UART收发、异步复位和LED。专用DDR约束、外部板级数据眼、同步器和内部恢复时序分别核验。
io_coverage.py只分类并输出CLASSIFIED_NOT_TIMING_CLOSED，未补通用0/1ns或宽泛例外：

```bash
python3 scripts/pango/io_coverage.py \
  --project "$PDS_WORK_ROOT/work/release-ab-20261030/main-coremark-r2" \
  --physical-summary logs/release-ab-20261030/main-physical-r1/physical-summary.json \
  --output logs/main-io-classification-new.json
```

本机按最新要求完成当前YOLO、添加文件后停止；不追加完整P&R、MPNR或原生help/probe。

### A/B复测与内存

本机只做完整main、完整YOLO各一次同策略P&R。A复用YOLO报告后处理UART、DDR资源加载、
HDMI与上板；B复用main报告后重测分层CoreMark、UART并修MiniMind多写RAM。
仅在实际失败路径或板级约束已修复时，A、B各最多再做一次P&R；MiniMind先修RTL和综合，
本计划不追加MiniMind布线或种子矩阵，all不做PDS。

本机Windows可见31.78 GiB内存、24逻辑CPU，WSL约15 GiB并有4 GiB swap；
PDS请求8线程，STA历史最多4进程。启动及每大阶段要求Windows物理余量和真实提交余量各至少6 GiB，
约10分钟查看一次阶段/内存，错误/结束单独记录。Linux available不能代替Windows提交量。
WSL缓存曾令Windows只余物理3.70 GiB、提交1.03 GiB，门禁拒绝启动；
对自有已完成文件fsync并回收干净文件缓存后恢复到15.75/8.42 GiB，没有修改分页或结束无关进程。
只有可重建且已结束的中间文件经哈希后可清理，固件、模型、源码和原始报告继续保留。
布局布线用于测实际线延迟、hold修复和资源分布，综合估计不能替代它；
两组规模与时钟不同，也不能把对照差值全部归给某个RTL或64/80策略。

## 历史C6交互候选（2026-10-30）

2026-10-30的条件候选采用旧RTL `d273172`、新RTL `b94580c`配对，工程位于`$PDS_WORK_ROOT/work/c6-interactive-20261030/{baseline,candidate}`，两套使用相同交互ELF/HEX/DDR IP/时钟/综合策略。原物理87.3057 MHz使用旧自动O3/64固件，不能将其与新交互镜像直接当作纯RTL配对收益。配对SYN、双宽回归与唯一追加P&R均已完成；本次从新SYN查询CDC对象/时钟根，绑定发布93 delay/60 skew及scope收据。入口工具163项Python与14项原生PowerShell检查通过。

新交互程序的实际四域UART仿真已通过RV32/RV64启动、P/V、计数/CRC回传、DONE和READY，使用2次迭代与500000 baud、`formal=0`；生产115200 baud、自动校准且至少十秒的正式板上成绩尚未测量。短流程与最终固件镜像身份分别记录，不将短流程数值作为正式CoreMark成绩。

新建工程由prepare_project/prepare_benchmark复制CDC入口并写入输入哈希；旧清单仍按旧字段核验，不回写历史输入。对已完成SYN的工程在新物理目录追加CDC约束和新入口，保留原RTL/IP/固件/SYN文件哈希，不重新compile/synthesize。原生查询必须在`open_design`的synthesize动作内执行；仅open_project返回的`::tcicmd::`延迟句柄不计绑定证据。C6的60 MHz报告周期16.6667 ns按报告小数位与真实分数周期核对，不能因显示舍入改FDC周期。

### 正式交互候选最终布局布线（2026-10-30）

`b94580c`、生产固件ID `ea1773fca42aa7c6`、C6、I16/D8/hash2于07:25:43完成唯一追加P&R。
本轮没有第二个物理候选、不升级baseline；原生工程为`$PDS_WORK_ROOT/work/c6-interactive-20261030/candidate/`。

| 域 | 目标MHz | 最终Fmax MHz | setup WNS ns |
|---|---:|---:|---:|
| Core | 100 | 90.6208 | −1.035 |
| SYS | 100 | 100.9082 | +0.090 |
| DDR user | 125 | 124.1619 | −0.054 |
| 外设 | 60 | 73.0004 | +2.968 |

0未布通；LUT75543（含常量/旁路）、FF64053、DRM36K38、APM4。
slow/fast hold最小+0.062/+0.039 ns，recovery+1.890/+4.115、removal+0.244/+0.163、MPW均+0.035，均0失败。
CDC max_delay最小+2.781/+4.820，Gray skew最小+4.395/+5.625，无受保护路径误例外。
DDR PHY setup/hold均通过，最小slow setup+0.089、fast hold+0.042；DDR用户域自身3端点−0.054，Core3222端点−1.035。
35输入/73输出delay仍缺，1个virtual clock，no_clock/loop/latch为0；没有bitstream或板测。

耗时1:19:45：devmap9:37、place8:52、route57:30、opt2:35、report1:11；工具池峰place12088 MB、route4860 MB。
请求8线程，STA实际最多4进程；所有阶段使用原memory gate，启动前Windows物理/提交余量9.268/6.671 GiB，
退出后13.491/13.225 GiB，无运行PDS。没有调整分页、停止无关进程或放宽约束。

实际Core最差是ISS操作数→分支方向→ROB取消→完成选择/广播→memory IQ→ISS，
14级、data10.326 ns=logic2.875+net7.451（72.16%），最大扇出63；两段net1.578/1.491 ns。
它与SYN的JALR路径不同，后续按实际弧段处理。物理收据和完整路径在
`logs/closing-c6-20261030/physical/{physical-receipt.json,actual-worst-paths.txt}`。
旧物理使用自动固件，不能将旧/新物理差值全部归到单项RTL；严格同固件SYN对照与性能周期另见优化文档。

### 原RTL C6布局布线（2026-10-30）

工程`$PDS_WORK_ROOT/work/main-coremark-c6-cdc-20261029/`于01:27:37完成。复用80576b9的baseline-main SYN，硬件与main@e3bcf17等价；RV32、I16/D8/hash2、TCM各64 KiB。31个FIFO、442同步寄存器、16244原生引脚已绑定，93条max_delay及60条max_skew在映射前加载。

| 域 | 目标MHz | 最终Fmax MHz | setup WNS ns |
|---|---:|---:|---:|
| Core | 100 | 87.3057 | −1.454 |
| SYS | 100 | 98.2415 | −0.179 |
| DDR user | 125 | 122.5490 | −0.160 |
| 外设 | 60 | 72.2201 | +2.820 |

0未布通；LUT74,746、FF61,967、38 DRM36K、4 APM。物理LUT包含常量/旁路，不能直接与综合逻辑LUT比较。总耗时2小时19分10秒；place峰值14,079 MB，route4,555 MB，route_optimize4,780 MB。请求8线程，实际route8、Timing4；没有同输入1/8线程速度对照。

slow/fast全部hold、recovery、removal、MPW、PHY skew通过，fast hold最小+0.025 ns。CDC max_delay最小+1.741 ns、Gray max_skew最小+5.144 ns，无同步路径误例外。DDR→PHY0另有setup−0.027 ns、5失败端点；35 input/73 output缺delay逐端口保存。Core/SYS/DDR user同域setup未闭合，不能据CDC通过宣布整机100 MHz通过。

Core前100路径中，79条为系统TCM读地址→译码/辅助口选择/碰撞→fetch_fire，最差−1.454 ns；15条reset→ROB/commit→rename→IQ，最差−1.215 ns、复位扇出2372；6条ISS反馈经过分支/ROB取消/完成选择/广播/IQ，最差−1.134 ns。TCM末网fetch_fire扇出195、单网2.462 ns。先评估原推进边沿保存地址游标、局部TCM合法位、并行碰撞比较，同时检查复位与ISS反馈；单改TCM不足以承诺100 MHz。SYS的write_error−0.179 ns、DDR写/读选择及PHY0分别处理。

原件摘要和76条逐arc分析保存在`logs/main-coremark-c6-cdc-20261029/{physical-summary.json,physical-path-analysis.json,physical-worst-paths.txt}`，完整原生报告仍在Windows工程。hold修复前后最差setup均−1.454 ns，逻辑数据实例和LUT/FF未变，没有新增数据buffer导致Core下降的证据。每次启动/大阶段检查物理与提交余量各≥6 GiB；未改分页、未停止无关进程。

本次固件是冻结O3/64次TCM performance、sim_console输出。新独立UART CoreMark已通过双宽真实SoC流程短测，RT终端已双宽构建；均未替换该物理工程固件，没有bitstream或板级验收。Logos2的免重布线INIT更新流程尚未验证。按用户顺序先完成演示仿真；频率仍未达标且候选验证有收益后，才追加一次优化P&R。

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
该历史准备稿曾填写performance放置/布线；PDS2025.2仅支持fast/normal，
该配置未执行物理阶段。后续使用上文normal入口，约10分钟检查进度，结束/失败记录。
映射、布局、布线、优化前分别检查物理与提交余量各至少 6 GiB。最终报告启用 max-skew 与 exception 明细。

2026-10-29 00:15 的预检为物理 14.988 GiB、提交余量 8.370 GiB；下次启动时重新查询。
历史准备入口如下；未执行，不能直接用于本轮新RTL/时钟：

```powershell
& "$env:PDS_WORK_ROOT\work\tcm-bram-20261028\yolo\physical-ready\launch-physical.ps1" -PdsHome $env:PDS_HOME
```

这份工程仅含已有 128-MAC YOLO，目标 Core/SYS/DDR-user/外设/NPU 为 100/80/125/25/100 MHz。
Core 综合为 92.9282 MHz、100 MHz 下 WNS −0.761 ns。当前没有布线 Fmax/WNS、零未布通、bitstream 或板级结果；
物理阶段继续检查 Gray 最大偏斜、同域 setup/hold、DDR PHY 和 I/O，不能据本次 CDC 对照宣称整体时序闭合。

## 历史配置与入口（2026-10-27）

Windows PDS 2025.2 ADS，器件 PG2L200H-6IFBB676，HMIC_S 1.10 DDR3 IP。
生成 IP 和原生工程使用 `$PDS_WORK_ROOT` 的新目录；`reference` 只读。
`PDS_HOME` 指向 Windows 工具安装。Linux Verilator 通过不代表板上通过。

Core 为 ROB16/int8/mem4、RAS0、OOO0、Tournament1、forward3、MUL0/DIV1。
C1 目标 Core/SYS/DDR-user/外设 = 100/80/125/25 MHz。
C5 目标 Core/SYS/DDR-user/外设/NPU = 90/100/125/25/100 MHz，供 YOLO 布局布线；见下节。
`pango_soc_pll` 为功能域生成时钟，DDR 用户时钟来自 DDR IP；选定加速器使用额外 100 MHz 输出。

`prepare_project.py --core-backend scoreboard --board-clock-profile 6 --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2` 暂存当时无加速器板级基线；
加 `--npu-enable` 或 `--mm3-enable` 选择对应加速器。两标志互斥，分支未保留的设备不能选择。
加速器专用分支从 `branch_profile.json` 读取默认设备，all 默认无设备。
默认入口已选择 scoreboard/C1；显式 legacy 使用原共同时钟，仍可显式覆盖时钟档。
四分支各 64 项 PDS 工具测试通过。暂存前需 `make loader XLEN=32` 与完整生成 DDR IP 目录。

含 CoreMark 的分支可用 `prepare_benchmark.py` 对 `core_tcm/soc_tcm/soc_ddr` 暂存与仿真
同配置、同 bundle 的工程；all 还支持 soc_npu。必须提供 `--bundle`、`--sim-receipt`，
DDR 组另需 `--ip-dir`。TCM 组使用真实 TCM RTL/BRAM 初值和外部时钟端口。
Cache 容量通过 `--icache-bytes`、`--dcache-bytes` 指定，默认各 4096 B，可选 4–64 KiB 的 2 次幂。
容量同时写入板级参数和清单，并核对仿真 build receipt、实际顶层参数转发和编译 Tcl；
不能只改测量标签而沿用旧硬件。比较容量时冻结同一固件、FDC、DDR IP 和综合选项。

标准综合使用 ADS `synthesize -ads -selected_syn_tool_opt 2`，单线程，增加路径报告深度；
不启用快速布局布线，本轮不执行 P&R。每个工程保留编译 Tcl、FDC、镜像、源码哈希和原始报告。

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

## SYS 控制路径综合对照

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

## C5 目标时钟

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

Fmax 是对应域内路径的综合估计，不等于已上板频率。WNS、资源、最差路径、跨域报告分别呈现。
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

## 启动边界

每阶段开跑前至少 6 GiB 物理与提交余量。WSL 的可回收文件缓存也可能占 Windows 提交预算。
本轮只对自己生成且闲置的构建文件使用 POSIX_FADV_DONTNEED，保留文件和日志；
随后再次查询 Windows 计数。未修改 pagefile、未终止无关进程。
综合结束/错误后记录结果，运行期间约十分钟查看一次即可。

bitstream 可包含 ROM/TCM 初值；配置 Flash 先恢复 FPGA 逻辑，CPU 才从 ROM 启动。
板上 DDR 初始化、软件搬运、Cache 维护和 UART 时基必须按实际域频率工作。
Flash 物理管脚接入与完整冷启动尚待板级验证。RT-Thread 仿真预装 DDR，
加速器仿真使用预装模型/输入；这些不等于 Flash 到 DDR 的完整上板流程已完成。
