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

## 加速器与 FPGA 边界

YOLO 使用固定 128-MAC 上游，双宽两个卷积与 4096 B DDR DMA 数据核对通过，
83 个 MAC 工作沿中 28 个与 DMA 在途重叠。RV32/RV64 O3 为 418,831/423,561 TB 周期，
RV32 Ofast 与 O3 相同。完整 YOLOX 尚未验证。

标准综合按五种实际硬件分别测资源和域内 Fmax，不将核级最高值用作完整系统频率。
本轮没有 P&R、bitstream 或板级结果。原生综合与内存检查位于 `$PDS_WORK_ROOT/work/four-branches-20261027/`。
CDC/PHY/I/O 的原始跨域报告与域内路径分别呈现，不用 false path 隐藏真实同步路径。
