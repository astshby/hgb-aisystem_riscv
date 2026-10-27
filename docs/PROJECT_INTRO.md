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

| 发布分支 | CoreMark | RT-Thread | 加速器 |
|---|---|---|---|
| main | M0 与三层实际硬件 | 独立应用 | 无 |
| baseline-yolo | 无 | 无 | YOLO |
| baseline-minimind | 无 | 无 | MiniMind |
| baseline-all | M0、三层与 YOLO 并发层 | 一份独立应用 | 分别选择 YOLO / MiniMind |

所有分支保留公共功能、ISA、AXI、CDC、UART 下载验证。加速器分支不携带 CoreMark 算法、
跑分脚本或 RT-Thread。原作者 MiniMind C 代码、模型锁和导出工具保留在 MiniMind/all。

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
默认配置仍为 4/4 KiB，16/4 为本实验推荐的显式配置，尚未替换正式 baseline。
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

本树无加速器。三层硬件标准综合分别测资源、域内 Fmax/WNS 和最差路径。
本轮没有 P&R、bitstream 或板级结果；CDC/PHY/I/O 的原始报告仍需后续处理。

## 本轮标准综合

五组测量的对应配置、各域 Fmax/WNS、LUT/FF/DRM/APM、最差路径和原始 CDC/hold 问题，
见 [FPGA 实测表](fpga/FPGA_ADAPTATION.md#2026-10-27-标准综合实测)。本分支表只列自身保留的硬件。
Core+TCM 达到 103.8853 MHz；SoC+TCM 为 95.0299 MHz，完整 DDR SoC 的 Core 为 85.1064 MHz。
只有 Core+TCM 达到 Core 100 MHz 综合目标，完整系统尚未达到。
没有本轮布局布线或上板成绩。已完成的仿真和原生综合绑定各自冻结输入，文档更新不改变测量来源。
Cache 候选的完整 DDR SoC Core 为 86.8282 MHz；SYS 为 83.6960 MHz，比同输入基线小幅下降。
资源代价与各域 WNS 见 [Cache 综合对照](fpga/FPGA_ADAPTATION.md#cache-容量综合对照)。
