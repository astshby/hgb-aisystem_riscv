# CoreMark 与性能指标解读

## 当前结论

A5 已具备可信的“周期级 CoreMark”闭环：RV32/RV64 裸机 C 冒烟通过，CoreMark
performance 与 validation 两组 CRC 都通过，计时区间均超过按 1 MHz 归一化的
10 秒。当前结果是：

| 配置 | Iterations | `mcycle` 差值 | CoreMark/MHz |
|---|---:|---:|---:|
| RV32I_Zicsr | 11 | 11,148,066 | 0.986718 |
| RV64I_Zicsr | 10 | 12,004,387 | 0.833029 |

这证明长 C 程序、栈、数据段、控制流、Load/Store、Zicsr 和精确退出可以协同工作。
它不是 FPGA Fmax 或最终 SoC 成绩：当前存储器是 Verilator 中的一周期同步模型，且
没有 Cache、总线竞争和硬件 M 扩展。

## 目录与各部分职责

```text
benchmark/
├── bsp/                    # 裸机启动、链接、计时、退出和软件算术
├── smoke/                  # 跑分前的最小 C 环境验证
└── coremark/
    ├── vendor/coremark/    # 不修改的官方 EEMBC v1.01 源码
    └── port/               # 本 CPU 的 seeds、内存、时间和输出适配
```

`vendor/coremark/` 中五个 `core_*.c` 与 `coremark.h` 保持上游原样；版本标签是
`v1.01`，程序报告的 benchmark 版本为 CoreMark 1.0。`bsp/crt0.S` 设置 `gp/sp/mtvec`、
清零 `.bss`、调用 `main`，最后用 `a7=93 + ECALL` 进入 Trap handler 并写 `tohost`。
链接脚本把代码和数据放在同一地址空间的不同区段，脚本再分别提取为 Harvard IMem
和 DMem 镜像。

CoreMark 不依赖 UART、中断或操作系统。`ee_printf` 最终对 `sim_console` 发出字节 Store，
TB 仅被动显示该地址，因此没有伪造 UART RTL；真正上板时再把同一输出抽象接到 UART。
计时直接读取 CPU 的 `mcycle`，不需要外设计时器。RV32 使用
`mcycleh → mcycle → mcycleh`，若两次高半不同则重读，以获得不会撕裂的 64 位周期数。

## 为什么没有 M 扩展也能运行

编译参数严格限制为 `rv32i_zicsr/ilp32` 或 `rv64i_zicsr/lp64`，不会生成 MUL/DIV
指令。编译器需要的 `__mul*`、`__div*` 和 `__mod*` ABI 函数由 `bsp/softarith.c`
使用移位、加法、减法与比较实现。这样能先验证 Base-I CPU，但软件乘除本身也计入
周期，所以结果不是未来 RV32IM/RV64IM 的性能。

RV64 当前分数低于 RV32，主要因为 LP64 的指针和 `long` 运算更宽，CoreMark 与运行时
会走更昂贵的 64 位软件辅助路径。完成 M 扩展后必须用 `rv32im_zicsr`/
`rv64im_zicsr` 重新编译并重新测量，不能沿用本页数字。

## 执行流程

```text
make coremark XLEN=32
  → 构建 128 KiB IMem/DMem benchmark 仿真顶层
  → 编译 1 次 performance 迭代并校准周期
  → 自动选择约 11M 周期的正式迭代数
  → 运行 performance seeds 并检查官方 CRC
  → 运行 validation seeds 并检查官方 CRC
  → 根据 performance 的 mcycle 差值计算 CoreMark/MHz
```

CoreMark 使用 2000 bytes 静态工作区、单 context 和 `-O2`。两种正式模式使用同一
CoreMark 源码、编译选项、内存配置和迭代数。`make benchmark-smoke` 应先通过；它覆盖
`.data` 初值、`.bss` 清零、局部栈、函数调用、软件乘除、DMem Store 和周期递增。

## 分数如何理解

若计时得到 `C` 个周期、迭代数为 `N`、目标频率为 `F MHz`：

```text
执行时间(s)  = C / (F × 1,000,000)
CoreMark/s    = N × F × 1,000,000 / C
CoreMark/MHz  = N × 1,000,000 / C
```

因此 `CoreMark/MHz` 只描述每个时钟周期的执行效率，与假定频率无关。若只为了观察
某个频率下的换算值，可运行：

```bash
COREMARK_FREQ_MHZ=50 make coremark XLEN=32
```

这只是算术换算，不证明设计能在 50 MHz 收敛。真实 `Fmax` 必须来自 FPGA
place-and-route 后的时序报告，而不是 Verilator 的宿主机耗时。资源效率也必须明确口径：

```text
CoreMark/LUT = 实际频率下的 CoreMark/s ÷ 已用 LUT 数
```

如果使用 `CoreMark/MHz/LUT`，必须用完整名称标注，不能与上式混写。

## 当前还缺什么

对“功能正确和周期效率”而言，A5 已经足够；对可发布的上板成绩，还需要：

- A6 将 Core 接到真实双口 BRAM/Cache adapter，并确认其 ready-valid 时序；
- 用 Vivado 综合和实现报告记录目标器件、约束、WNS、实际频率、LUT/FF/BRAM/DSP；
- 用板上 UART/JTAG 输出 CRC、周期与迭代数，确认 `mcycle` 按 CPU 时钟计数；
- 正式运行前关闭调试 trace，固定工具链、源码 commit、编译选项和存储器配置；
- 分别保存无 M、有 M、有 Cache 等配置的结果，任何架构变化都重新跑 CRC 与计时。

MMIO 是 CPU 访问 UART/Timer 等设备寄存器的地址协议；MMU 是虚拟地址到物理地址的
转换与保护机制，两者不在同一层，也都不是当前 CoreMark 仿真的必要条件。DMA 是与
CPU 并列的总线主设备，用于搬运数据；加入 D-Cache 后才需要软件维护 DMA 与 Cache
的一致性。当前 CoreMark 全部驻留 BRAM，由 CPU 直接访问，因此无需 DMA。

## 后续性能验证

CoreMark 给出整体整数工作负载指标，但不能定位瓶颈。后续应同步记录：

- `minstret` 与 `mcycle`，计算 IPC/CPI；
- 条件分支数、预测错误数和重定向代价；
- 连续 Load、load-use、Store 与存储等待的周期数；
- 接入 Cache 后的 I/D miss rate、miss penalty 和总线等待比例；
- M 扩展的单指令延迟、吞吐以及 CoreMark 前后变化；
- FPGA Fmax 与 LUT/FF/BRAM/DSP，最后再计算 CoreMark/LUT。

这些 microbenchmark 与硬件计数器应和 CoreMark 分开报告：前者解释“为什么快或慢”，
后者验证真实长程序上的综合效果。
