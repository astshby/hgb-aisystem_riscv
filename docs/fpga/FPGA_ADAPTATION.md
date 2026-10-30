# FPGA 适配与综合

本 all 分支仅仿真，不生成第四份物理镜像。双核同挂载使用soc_all_system；板级pango_200hp_top仍是
单应用壳，不能将其二选一布局布线结果登记为双核结果。无NPU、YOLO、MiniMind的物理调试分别在
main、yolo、minimind分支进行。已有无NPU物理Core90.6208MHz等结果只对应原b94580c及交互固件，
新增双核/HDMI/共享Core修改没有P&R数据。MiniMind多写RAM推断问题尚未修复。

联合仿真前检查两个独立窗口、PLIC源8/9、软件MM3_MMIO_BASE与顶层一致；共同复位同时清CDC两端。
MiniMind和显示在external口的读写owner各独立，突发最多四拍，轮询起点在真实响应完成后转移。
VIDEO_ENABLE=1的RV32 lint通过，但真实MiniMind与HDMI并发扫描尚未运行。HDMI是否无欠载须另测带宽竞争；小程序地址/中断/GEMV通过不能代替完整视频模型或物理时序验收。
C9/C10时钟入口、原生CDC工具、normal种子对照及独立timing-v2/v3脚本均保留，未执行PDS。
Windows PDS原始产物继续留PDS_WORK_ROOT，仿真日志与固件留主工作区logs/build。


## 配置与入口

Windows PDS 2025.2 ADS，器件 PG2L200H-6IFBB676，HMIC_S 1.10 DDR3 IP。
生成 IP 和原生工程使用 `$PDS_WORK_ROOT` 的新目录；`reference` 只读。
`PDS_HOME` 指向 Windows 工具安装。Linux Verilator 通过不代表板上通过。

Core 为 ROB16/int8/mem4、RAS0、OOO0、Tournament1、forward3、MUL0/DIV1。
C1 目标 Core/SYS/DDR-user/外设 = 100/80/125/25 MHz。
`pango_soc_pll` 为功能域生成时钟，DDR 用户时钟来自 DDR IP；选定加速器使用额外 100 MHz 输出。

`prepare_project.py --core-backend scoreboard --board-clock-profile 1` 暂存无加速器板级工程；
加 `--npu-enable` 或 `--mm3-enable` 选择对应加速器。两标志互斥，分支未保留的设备不能选择。
加速器专用分支从 `branch_profile.json` 读取默认设备，all 默认无设备。
默认入口已选择 scoreboard/C1；显式 legacy 使用原共同时钟，仍可显式覆盖时钟档。
四分支各 64 项 PDS 工具测试通过。暂存前需 `make loader XLEN=32` 与完整生成 DDR IP 目录。

含 CoreMark 的分支可用 `prepare_benchmark.py` 对 `core_tcm/soc_tcm/soc_ddr` 暂存与仿真
同配置、同 bundle 的工程；all 还支持 soc_npu。必须提供 `--bundle`、`--sim-receipt`，
DDR 组另需 `--ip-dir`。TCM 组使用真实 TCM RTL/BRAM 初值和外部时钟端口。

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
| SoC+YOLO | 88.1368 / -1.346 | 83.8293 / +0.571 | 144.7387 / +1.091 | 79.9552 / +27.493 | 106.5871 / +0.618 |

| 硬件 | LUT | FF | DRM36K | APM |
|---|---:|---:|---:|---:|
| Core+TCM | 26239 | 19665 | 32.0 | 4.0 |
| SoC+TCM | 46748 | 39193 | 32.0 | 4.0 |
| SoC+Cache/DDR | 61438 | 54342 | 36.0 | 4.0 |
| SoC+YOLO | 71569 | 66789 | 162.5 | 86.0 |

DDR-user 125 MHz 是控制器用户接口；本轮 IP 配置为 DDR 数据率 1000 Mbps、外部 CK 500 MHz。
TCM 两组没有 DDR PHY，不填 DDR-user 数值。
各组 RTL、时钟、ROM/TCM 初值和完整原生报告均单独冻结。

原生工程位于 `$PDS_WORK_ROOT/work/four-branches-20261027/`，目录与表行分别为
`core_tcm`、`soc_tcm`、`soc_ddr-v2`、`soc_npu-v2`。摘要、命令和报告哈希见本地
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
| SoC+YOLO/Core | `u_tcm_target/u_target/write_q[15]/CLK` → `u_soc/g_tcm[0].u_ram/g_bank[0].mem_0/CEA` | 16 | 104 |
| SoC+YOLO/SYS | `g_npu.u_reset/g_domain[1].release_q[2]/CLK` → `u_fabric/g_master[2].u_write_route/occupancy[0]/CE` | 17 | 1934 |
| SoC+YOLO/DDR-user | `u_ddr_bridge/wr_cmd_q[3]/CLK` → `u_ddr_bridge/wr_error_q_reg[1]/D` | 11 | 56 |
| SoC+YOLO/外设 | `u_soc/u_reset/g_domain[3].release_q[2]/CLK` → `u_peripherals/u_mtime/time_q[63]/D` | 17 | 1703 |
| SoC+YOLO/NPU | `g_npu.u_target/u_device/request_addr_q[10]/CLK` → `g_npu.u_target/u_device/bias_q[64]/CE` | 13 | 34 |

| 硬件 | 原始跨域 setup 最差 ns | 原始跨域 hold 最差 ns | 同域 hold 最差 ns | 未指定 input/output delay 数 |
|---|---:|---:|---:|---:|
| Core+TCM | — | — | +0.569 | 3/2 |
| SoC+TCM | -2.400 | +0.321 | +0.274 | 4/2 |
| SoC+Cache/DDR | -6.063 | -4.770 | -0.006 | 35/73 |
| SoC+YOLO | -6.063 | -4.680 | -0.006 | 35/73 |

上述跨域数值是保留全部真实路径时的原始报告，尚未完成 FIFO/Gray/payload 端点约束及 DDR PHY/I/O 检查。
域内最差路径的完整端点/逻辑级/扇出，以及原始跨域 setup、hold 和未约束 I/O 均保存在摘要。
负 WNS 表示对应目标未达到；跨域、DDR PHY 和 I/O 约束仍需逐端点检查，不能据域内 Fmax 宣称整体时序闭合。
本轮未执行 P&R，布线 Fmax/WNS、未布通数和板级结果均为未测。

MiniMind 五域仿真通过；本次 PDS 出现 14 个加速器数组多写 RAM 推断警告，约 59 分钟后按维护者决定停止。
MiniMind 的 LUT/FF/DRM/APM、Fmax/WNS 均未取得结果，100 MHz 只作为目标；保留源码，列为存储结构待修。
原生目录 soc_minimind 的 user-stop.json 和完整日志保留，不能用 YOLO 数值替代 MiniMind。

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

## 内存与启动

每阶段开跑前至少 6 GiB 物理与提交余量。WSL 的可回收文件缓存也可能占 Windows 提交预算。
本轮只对自己生成且闲置的构建文件使用 POSIX_FADV_DONTNEED，保留文件和日志；
随后再次查询 Windows 计数。未修改 pagefile、未终止无关进程。
综合结束/错误后记录结果，运行期间约十分钟查看一次即可。

bitstream 可包含 ROM/TCM 初值；配置 Flash 先恢复 FPGA 逻辑，CPU 才从 ROM 启动。
板上 DDR 初始化、软件搬运、Cache 维护和 UART 时基必须按实际域频率工作。
Flash 物理管脚接入与完整冷启动尚待板级验证。RT-Thread 仿真预装 DDR，
加速器仿真使用预装模型/输入；这些不等于 Flash 到 DDR 的完整上板流程已完成。
