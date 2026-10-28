# 项目配置与测量

## 目录与公共配置

`vsrc/core` 保存共享 Core，`vsrc/soc` 保存 TCM/Cache、AXI、DMA、MMIO 和跨域接口，
`vsrc/cpu` 为 FPGA 顶层。`scripts/hardware_profile.json` 固定 Core 参数、容量和目标时钟；
`scripts/branch_profile.json` 记录当前分支保留的应用。`make help` 只显示存在的应用。
Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4，
正常 ALU/Load/DSP 为 8/10/10 级；C、F/V、MMU/Linux 未实现。

目标 Core/SYS/DDR-user/外设为 100/80/125/25 MHz，选用加速器时增加独立 100 MHz 域。
ITCM/DTCM 各 64 KiB，I$/D$ 各 4 KiB、两路、32 B 行；I$ 当前填充粒度 4 B。
TCM 与 Cache 命中逻辑仍在 Core 域；Core 与它们进一步分域仅是未来候选。
SYS 负责统一 AXI 仲裁，DDR 与外设分别通过 FIFO 跨域。DMA 是 SYS 域主设备，
CPU 提交地址/长度/方向、启动、核对完成和处理 Cache 所有权；不允许 DMA 写 START 等控制寄存器。
生产顶层为 `soc_system.sv`，CPU 侧使用 `cpu_memory_adapter` 与 `tcm_bram`。
SYS 与 Core 是并行的时钟域；SYS 域不包含 Core、TCM 或 Cache。各域组件见[系统结构](understand/SOC_SYSTEM.md)。

| 发布分支 | CoreMark | RT-Thread | 加速器 |
|---|---|---|---|
| main | M0 与三层实际硬件 | 独立应用 | 无 |
| baseline-yolo | 无 | 无 | YOLO |
| baseline-minimind | 无 | 无 | MiniMind |
| baseline-all | M0、三层与 YOLO 并发层 | 一份独立应用 | 分别选择 YOLO / MiniMind |

所有分支保留公共功能、ISA、AXI、CDC、UART 下载验证。加速器分支不携带 CoreMark 算法、
跑分脚本或 RT-Thread。原作者 MiniMind C 代码、模型锁和导出工具保留在 MiniMind/all。

当前实验分支 `integrate/yolo-tcm-boundaries` 另保留 CoreMark/RT 独立回归入口，并接入已有 YOLO；不含 MiniMind。上述四个正式分支尚未更新。

## 环境与命令

实测工具为 GCC 16.1.0、Verilator 5.052、Windows PDS 2025.2 ADS。
外部路径使用 `RISCV_TOOL_ROOT`、`PDS_HOME`、`PDS_WORK_ROOT`、`RTTHREAD_ROOT`。
依赖 `riscv-tests` checkout 只读、不作为本轮新子模块提交。

`make check XLEN=32|64` 运行通用功能、scoreboard、ISA、SoC、五组时钟、AXI 和 C smoke。
`make loader-host-test` 与 `make loader-soc-test XLEN=32|64` 检查下载协议和 UART 实际引脚。
本分支应用入口以 `make help` 为准。
软件默认 O3，用 `SOFTWARE_OPT=O2|O3|Ofast` 覆盖。Ofast 本轮没有稳定额外收益，未设为默认。

Cache 容量实验共用上述软件入口。`coremark-platforms`、独立 RT 测试和 PDS 暂存均支持
`--icache-bytes` / `--dcache-bytes`，未指定时各为 4096。实际实例参数、固件和时钟写入测量清单。
批量容量测试使用 `scripts/verilator/run_cache_sweep.py`，命令见[联合优化](understand/OPTIMIZATION.md)。

## CoreMark 口径

`make score` 保留 M0（TB 一周期存储）及 `scripts/benchmark_platforms.json` 定义的平台。
`core_tcm` 是真实 Core+TCM，`soc_tcm` 增加 ROM/DMA/MMIO，`soc_ddr` 增加 Cache/DDR，
all 的 `soc_npu` 再增加 YOLO。综合使用相同参数、软件 bundle 和仿真 build receipt。
RT-Thread 不参加这组测试。

CoreMark/MHz = iterations × 1,000,000 / 计时区 mcycle。
其他时钟域影响等待拍数，分母仍为 Core MHz。cold 未预热 Cache，warm 先运行一次；
background 加 DMA 和 Timer IRQ，NPU background 还执行、核对卷积。

| 软件优化 | M0 perf / val，64 次 | 真实 TCM perf / val，2 次 | DDR cold / warm perf，2 次 |
|---|---|---|---|
| O2 | 3.526520 / 3.507011 | 3.012983 / 2.994267 | 2.389572 / 2.404525 |
| O3 | 3.590617 / 3.570731 | 3.052755 / 3.035846 | 2.381312 / 2.395887 |
| Ofast | 3.590617 / 3.570731 | 3.052755 / 3.035846 | 2.381290 / 2.395887 |

编译矩阵 78 PASS、0 SKIP，源提交 d5abd51；公共集成 edc2349 重放 O3 24 项周期一致。
O3 提升 M0/TCM，但 DDR 略低；同表保留取舍。短仿真未满足正式十秒要求。
完整记录在工作区 `2-coremark/record.md`，镜像及日志在本仓库忽略目录
`build/four-branches/`、`logs/four-branches-20261027/`。记录包含命令、CRC、ELF/HEX/源码哈希。
历史日志曾被维护者删除，旧摘要不能替代本轮原始报告。

Cache 容量实验保持 Core 与上述时钟比例，O3 64 次迭代共 18 项通过。
I$16/D$4 KiB 的 cold、warm、DMA/IRQ performance 为 2.507487、2.508556、2.187186 CoreMark/MHz；
六个场景/种子的跑分几何均值比 4/4 KiB 提高 4.8455%，8/4 KiB 提高 4.5763%。
32/4 KiB 的两次迭代初筛周期与 16/4 完全相同；D$8/32 KiB 出现回退，保留 D$4 KiB。
默认配置仍为 4/4 KiB，16/4 是上述容量实验的显式配置；后续bank候选见下文，尚未替换正式baseline。
真实 TCM 重放周期不变，RV64 候选功能通过；RT32 的 I$ miss 6048→1635，总周期减少约 0.44%。
后者包含 tick 等待，单独记录。

## RT-Thread 独立运行

仅 main/all 保留，固定 v5.2.2 提交 `ddf52e2cdd977f14fc04035c88672ac204aec713`。
先 `make rt-thread-fetch`，再 `make rt-thread XLEN=32`；RV64 使用相同入口。
完整四域 SoC 无 NPU。Boot ROM 跳到 ITCM 启动，常用 trap/上下文代码驻 ITCM 顶部 8 KiB，
其加载镜像在 DTCM 的 `0x0110c000`；DMA 搬入后校验并执行 FENCE.I，再安装 mtvec。
程序主体、数据、BSS、线程栈/堆在 DDR `0x80000000`，由 Cache 自动填充；
DTCM 保留观测区和机器异常栈。TB 为仿真预装 DDR 镜像，板上装载仍需 Flash/UART 启动链。

O3 双宽实际运行通过：RV32/RV64 为 2,765,395/2,774,072 TB 周期，39 次 trap，
DDR 退休计数均超过 260 万，I$/D$ 命中和 DMA 热代码搬运均被检查。它们是功能时间，不能换算 CoreMark。

## FPGA 边界

当前实验三层 CoreMark 综合关闭 NPU；YOLO 应用工程单独打开第五域。分别测资源、域内 Fmax/WNS 和最差路径。
本轮没有 P&R、bitstream 或板级结果；CDC/PHY/I/O 的原始报告仍需后续处理。

## 本轮 TCM 与 YOLO 实验

TCM 改用双端口 BRAM：取指/数据主口固定，辅助口公平仲裁，CPU 读不增加一级。AXI beat 级写校验、已有请求队列的静态路由预译码、8 路 SYS 复位释放副本和同步器保护已加入组合。
真实 TCM 64 次为 3.095736/3.081770 CoreMark/MHz，较 R3 的 3.054825/3.040240 提高约 1.34%/1.37%。
SoC+TCM 加 DMA/IRQ 为 2.750866/2.737537；DDR cold 为 2.530971/2.513669，warm 为 2.532010/2.514682，后台为 2.207755/2.194270。
14 项长测已用冻结固件重放，周期与原汇总逐项相同。

| 工程/策略 | Core MHz / WNS ns | SYS MHz | DDR-user MHz | 外设 MHz | NPU MHz | LUT / FF |
|---|---:|---:|---:|---:|---:|---:|
| 组合 Core+TCM，标准 | 103.5733 / +0.345 | 无 | 无 | 无 | 无 | 26031 / 19682 |
| 组合 SoC+TCM，标准 | 96.4413 / −0.369 | 110.1200 | 无 | 98.7362 | 无 | 40759 / 39286 |
| 组合完整 DDR，标准 | 90.0252 / −1.108 | 107.6310 | 150.5117 | 87.6808 | 无 | 55906 / 55348 |
| 组合 Core+TCM，性能 | 104.1016 / +0.394 | 无 | 无 | 无 | 无 | 26939 / 24465 |
| YOLO，标准 | 93.1532 / −0.735 | 101.8537 | 146.4772 | 85.9107 | 107.9680 | 64816 / 67831 |
| YOLO，性能 | 92.9282 / −0.761 | 113.9212 | 146.0494 | 92.1574 | 114.8633 | 66393 / 72759 |

上表全部是综合估计。两套 TCM 工程用 32 DRM/4 APM，完整 DDR 用 38 DRM/4 APM，YOLO 用 164.5 DRM/86 APM，均无 latch。
加上端口单项三层，本轮 9 组综合均完成。Core+TCM 性能策略较组合标准提高约 0.51%，FF 增加约 24.3%；
YOLO 性能策略改善 SYS/NPU，但 Core 略退。尚未达到 Core+TCM 超过 130 MHz 或联合指标不退，正式基线未升级。
SYS 的 Fmax 可以高于 Core；它们分别由域内最差路径决定。目标频率仍为 100/80/125/25/100 MHz。

YOLO O3/I16/D8/mask2 双宽裸机通过，RV32/RV64 为 418463/423721 周期；实际 MAC 工作 83 次，与 DMA 重叠 28 次。NPU AXI 四种频率、双宽共 8 项各 14 检查通过。只验证小卷积与搬运，没有完整 YOLO 网络 FPS/mAP。
RT-Thread 在无 NPU 组合单独通过，RV32/RV64 为 2741224/2752870 周期、各 39 次 trap；它们是功能耗时。

RTL 组合测量提交 a7b25c2，YOLO 集成 76139dc，配对原生工程工具 8277462。命令、ELF/HEX 和日志哈希在
`logs/tcm-bram-20261028/`、`build/yolo/system-rv{32,64}-O3-i16384-d8192-h2/result.json`。
临时树跨文件系统迁移失败后被删除，部分原始仿真日志丢失；原生 PDS 工程、报告、冻结固件及汇总保留。
组合双宽回归、14 短/14 长/3 项 RV64、RT 与 PLL 已补测，新的证据在 `logs/tcm-bram-20261028/recovery/`，与丢失原件分开记录。
SoC+TCM 26 个 FIFO/358 个同步寄存器及 YOLO 36 个 FIFO/502 个同步寄存器已核对原生对象和时钟归属。
约束前后对照已通过：6/11 组功能跨域 setup 裕量为正，同域时钟、Fmax、setup/hold 和端点数一致，
同域例外及无匹配路径告警均为 0。146 项工具测试与新增 2 项时序对照测试通过，工具提交 5b29642。
YOLO 的 `physical-ready` 工程与启动脚本已冻结；预检为物理 14.988 GiB、提交余量 8.370 GiB。
按用户要求停在 dev_map/place/route 之前。Core 100 MHz 的综合 WNS 仍为 −0.761 ns，物理结果待测。
补测重复快照和可重建编译产物已清理，日志、固件和结果保留约 74 MB，清单为
`logs/tcm-bram-20261028/recovery/retained-evidence.json`。所有原生 PDS 报告保留。

## 上轮路径实验

收尾分支integrate/soc-path-selected基于47aec08，保留SYS独热控制和可配置bank入口，不含A/B；正式baseline未升级。
I16/D8/mask2是显式性能候选，默认I4/D4/mask0保持。六项64次DDR与bank-only对照同周期，TCM周期保持。

| 当前无A配置 | performance / validation，每MHz | Core综合估计MHz | LUT / FF |
|---|---:|---:|---:|
| M0，64次 | 3.590617 / 3.570731 | 不单列裸Core测频 | 不适用 |
| Core+TCM，2次 | 3.052755 / 3.035846 | 105.0641 | 26130 / 19665 |
| SoC+TCM，2次 | 3.052755 / 3.035846 | 93.6067 | 39908 / 39165 |
| SoC+TCM＋DMA/IRQ，2次 | 2.642689 / 2.618037 | 同上 | 同上 |
| DDR cold，64次 | 2.530971 / 2.513669 | 89.3336 | 52571 / 55207 |
| DDR warm，64次 | 2.532010 / 2.514682 | 同上 | 同上 |
| DDR＋DMA/IRQ，64次 | 2.207225 / 2.193928 | 同上 | 同上 |

SoC+TCM的SYS/外设为112.9433/98.8045 MHz，DDR完整系统SYS/DDR-user/外设为106.6894/150.4664/86.3185 MHz。
三层DRM分别32/32/38、APM均4；各域WNS、最差路径和约束缺口见 [路径实验综合](fpga/FPGA_ADAPTATION.md#路径实验的三层结果与取舍)。
四分支整理时Core+TCM/SoC+TCM/DDR Core为103.8853/95.0299/85.1064 MHz；随后I16/D4容量实验为86.8282 MHz。
当前Core+TCM频率与资源改善；SoC+TCM Core比旧95.0299下降1.4976%，因此本轮未验收所有层主频不退，正式baseline保持。
SYS单项I16/D4/mask0的Core90.1307 MHz高于D8联合89.3336；D8六项每MHz几何均值+0.8207%，两项取舍分开记录。
A单项曾得到92.2594 MHz，但联合三层的Core频率与LUT均由无A控制取得较好结果；B在相同SYS底座使Core90.1307→88.3470、增加492 LUT/155 FF且每MHz回退，均不采用。
D4/mask1联合Core85.4920 MHz，低于起点86.8282，被拒绝。没有本轮布局布线或上板成绩。

47aec08完整双宽test各82 PASS/2 SKIP、scoreboard31/0，ISA58/2与78/2，smoke各1/0，M0各2/0通过。
I16/D8/mask2独立RT双宽通过，总周期2741313/2753088，各39次trap；该功能耗时不作为RT跑分。
完整短/长矩阵、两份源码对照、三层标准综合与哈希保存在本地record和final-summary.json。
