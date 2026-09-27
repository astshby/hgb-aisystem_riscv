# FPGA 平台适配

## 目标与当前状态

rhbyv 必须同时面向紫光同创盘古 676-200K Pro 和 Zynq-7020；先集成盘古，再适配
Zynq。不能在可移植 Core
中固化 Xilinx 接口。目前完成的是共享 RTL 和 Verilator 验证；两块板均未完成
BRAM、时钟、外设、约束集成或上板验证，不能把规划目标表述为已支持的板级工程。

| 平台 | 工程目标 | 当前边界 |
|---|---|---|
| 盘古 676-200K Pro（首个目标） | 独立厂商工程与约束，沿用同一 Core 和软件契约 | 精确器件/封装、工具版本、引脚、BRAM/DDR IP 和时钟资料待板卡资料确认 |
| Zynq-7020（后续目标） | 保留 Vivado 工作流，CPU 运行于 PL | 现有 Tcl 默认 `xc7z020clg400-1`；是否使用 PS DDR 需单独决策 |

## 共享层与平台层

- `vsrc/pkg/`、`vsrc/core/`：ISA、六级流水、CSR/Trap、MDU；不实例化厂商 DSP/BRAM。
- `vsrc/sim_cpu/`：仿真存储器与仿真顶层，不替换 Core 的运算时序。
- `vsrc/cpu/`：可综合平台连接、时钟/复位和存储器协议适配。
- `ip/`、`constr/`、`scripts/`：未来按平台分别保存 IP 配置、引脚/时序约束和重建脚本。

建议后续将平台 adapter 分置于 `vsrc/cpu/platform/zynq7020/` 和
`vsrc/cpu/platform/pango676/`，IP/约束使用对应平台子目录。这些目录是规划，不代表
当前已经存在实现；Zynq 的既有 Vivado 工作流不删除。

先实现共享的物理地址映射、I/D-TCM、MMIO 路由和系统总线契约，再接入 DMA
到 TCM/外存，最后在可缓存外存路径接入 I$/D$；BRAM、DDR、IP 桥接由平台层实现。厂商
DDR IP 的用户侧接口是否 AXI4，须按具体 IP 配置确认，不能凭器件系列推定。
Zynq 的 PS DDR 必须经 PS–PL 接口并满足 PS 初始化条件；若保持完全纯 PL，
首版只使用 PL 内 BRAM/TCM，DDR 方案需另审。详见 [设计草案](understand/THINKING.md)。

## 必须保持一致的契约

Core 使用独立 IMem/DMem ready-valid 接口；平台 adapter 负责将真实 BRAM 的同步
读延迟、响应保持和请求可接收条件转换为该协议。等待期间保持请求/响应载荷，
已握手的事务不能重复，清除错误路径也不能丢失必须排空的响应。

两种平台都提供 CPU 时钟和同步复位，`mcycle` 按 CPU 时钟计数。CoreMark 输出、
退出协议和内存布局由 BSP 适配，UART 与其他 MMIO 的地址/访问宽度必须有明确约定。
未来访存错误与中断接口须在共享契约中扩展，而不是只在某一平台偷偷增加语义。

## MDU 与 DSP

MDU 的统一握手和 ISA 符号处理与平台无关。`MUL_IMPL=0/1/2` 分别选择使用单个 `*`
的 DSP 推断乘法、Radix-4 Booth-Wallace、普通移位乘法；`DIV_IMPL=0/1` 选择
移位恢复除法、Radix-4 SRT。默认 0/0，编译时只实例化一种乘法和一种除法。
Verilator 使用 `CORE_MUL_IMPL/CORE_DIV_IMPL` 宏；未来厂商工程须设置相同宏，
当前 Vivado 框架沿用缺省值。算法与延迟见 [M 扩展解读](understand/M_EXTENSION.md)。

乘法运算符可由各自综合工具映射到 DSP 或逻辑资源；`mul_dsp` 的名字不能替代
综合映射报告。不保证两个平台有相同 DSP 数量或 Fmax，也不预先假定盘古 DSP
的原生位宽。SRT 使用归一化、截断 QDS、carry-save 余数、在线商转换与最终修正，
较少迭代不能直接推导更高时钟频率。
当前没有直接实例化 DSP primitive 或乘除 IP；后续再分别评估两家厂商 IP。

如果后续需要厂商专用后端，必须隔离实现并验证相同的结果、延迟、反压、复位和
取消行为；禁止 `SYNTHESIS` 宏让仿真变为单周期、上板变为多周期。

## 平台验收

每个平台分别完成 BRAM 时序测试、ISA smoke、CoreMark CRC 与周期测量，并记录
工具版本、器件、约束、LUT/FF/BRAM/DSP、实现后时序与实际时钟。先完成盘古
的 TCM/基础总线与板级闭环，再复用 Core 契约适配 Zynq；真实 Cache 与 DMA
分步验证。主流水拆分在上板闭环与关键路径分析之后评审。
