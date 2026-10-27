# hgb-aisystem：main

分层裸机 CoreMark 与独立 RT-Thread，完整四域 SoC 无 NPU。Core 使用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0。
RV32 优先优化，RV64 验证功能。正常 ALU/Load/DSP 为 8/10/10 级，C 扩展尚未实现。

Core/SYS/DDR-user/外设目标为 100/80/125/25 MHz。
这些是配置目标，综合估计另列，本轮没有布局布线或上板结果。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示本分支入口：

```bash
make check XLEN=32
make check XLEN=64
SOFTWARE_OPT=O3 make score COREMARK_PLATFORM_OUT=build/score-O3
make rt-thread-fetch
make rt-thread XLEN=32
```

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共 Core/SoC 配置在
`scripts/hardware_profile.json`，分支功能在 `scripts/branch_profile.json`。

M0 64 次 O3 为 3.590617/3.570731 CoreMark/MHz；真实 TCM 短测为 3.052755/3.035846。
两者的存储路径不同，分别记录。RT-Thread 不参加 CoreMark，程序主体在 DDR，热 trap 驻 ITCM。
短 CoreMark 仿真未满足正式十秒要求。

说明见[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)、
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。全部源码与可选应用集中保存在 baseline-all；
本分支只保留上述应用。历史分支已保存为本地 archive 标签，详细变更用 git log/git show 查询。
