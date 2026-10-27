# hgb-aisystem：baseline-minimind

MiniMind 整数算子、原作者软件与五域 SoC，无 CoreMark/RT-Thread。Core 使用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0。
RV32 优先优化，RV64 验证功能。正常 ALU/Load/DSP 为 8/10/10 级，C 扩展尚未实现。

Core/SYS/DDR-user/外设目标为 100/80/125/25 MHz。所选加速器另用独立 100 MHz 域。
这些是配置目标，综合估计另列，本轮没有布局布线或上板结果。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示本分支入口：

```bash
make check XLEN=32
make check XLEN=64
make minimind XLEN=32
make minimind XLEN=64
```

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共 Core/SoC 配置在
`scripts/hardware_profile.json`，分支功能在 `scripts/branch_profile.json`。

CPU 经 0x20000000 配置算子；NPU 独立 AXI 主口读写共享 DDR，系统 DMA 可并行运行。
双宽 38 命令单层与参考一致，运行库 CPU/加速器对照及 32 KiB DMA 并发通过。
本轮尚未完成全八层、多 Token 和语言质量测试；先按软件 README 恢复锁定模型。

说明见[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)、
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。全部源码与可选应用集中保存在 baseline-all；
本分支只保留上述应用。历史分支已保存为本地 archive 标签，详细变更用 git log/git show 查询。

MiniMind 的五域仿真通过；本次 PDS 出现多写 RAM 推断警告，约 59 分钟后按维护者决定停止。
资源与 Fmax 尚未取得，独立域 100 MHz 为目标。存储 bank/写端口/同步读结构列为待修，
详见 [FPGA 状态](docs/fpga/FPGA_ADAPTATION.md#2026-10-27-标准综合状态)。
