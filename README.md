# hgb-aisystem：baseline-yolo

YOLO 128-MAC、驱动与五域 SoC，无 CoreMark/RT-Thread。Core 使用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0。
RV32 优先优化，RV64 验证功能。正常 ALU/Load/DSP 为 8/10/10 级，C 扩展尚未实现。

Core/SYS/DDR-user/外设目标为 100/80/125/25 MHz。所选加速器另用独立 100 MHz 域。
这些是配置目标，综合估计另列，本轮没有布局布线或上板结果。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示本分支入口：

```bash
make check XLEN=32
make check XLEN=64
make yolo XLEN=32
make yolo XLEN=64
```

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共 Core/SoC 配置在
`scripts/hardware_profile.json`，分支功能在 `scripts/branch_profile.json`。

两个卷积与 DDR DMA 数据比较通过。83 个实际 MAC 工作沿中 28 个与 DMA 在途重叠；
调度使用裸机异步启动与轮询，RT-Thread 不作为当前依赖。完整 YOLOX 尚未验证。

说明见[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)、
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。全部源码与可选应用集中保存在 baseline-all；
本分支只保留上述应用。历史分支已保存为本地 archive 标签，详细变更用 git log/git show 查询。
