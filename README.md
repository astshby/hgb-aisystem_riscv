# hgb-aisystem：TCM 与 YOLO 时序实验

当前实验从 R3 重构 TCM 本地访问，并选择性接入已有 128-MAC YOLO。分层裸机 CoreMark 和独立 RT-Thread 使用无 NPU 四域 SoC；YOLO 裸机测试使用五域 SoC，不运行 RT-Thread。Core 使用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0。
RV32 优先优化，RV64 验证功能。正常 ALU/Load/DSP 为 8/10/10 级，C 扩展尚未实现。

Core/SYS/DDR-user/外设目标为 100/80/125/25 MHz，YOLO 增加 100 MHz NPU 域。
这些是配置目标，综合估计另列，本轮没有布局布线或上板结果。
当前已完成 CDC 约束前后对照和 YOLO 性能工程预检，按要求停在布局布线启动前。
启动入口与停止点见 [FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)；正式基线未升级。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示本分支入口：

```bash
make check XLEN=32
make check XLEN=64
SOFTWARE_OPT=O3 make score COREMARK_PLATFORM_OUT=build/score-O3
make rt-thread-fetch
make rt-thread XLEN=32
make yolo XLEN=32
```

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共 Core/SoC 配置在
`scripts/hardware_profile.json`，分支功能在 `scripts/branch_profile.json`。
YOLO 重跑时用 `YOLO_OUT=build/yolo/new-run` 指定新目录，保留原镜像和测量日志。

M0 64 次 O3 为 3.590617/3.570731 CoreMark/MHz；本轮真实 TCM 64 次为 3.095736/3.081770。
两者的存储路径不同，分别记录。RT-Thread 不参加 CoreMark，程序主体在 DDR，热 trap 驻 ITCM。
短 CoreMark 仿真未满足正式十秒要求。

说明见[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)、
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。全部源码与可选应用集中保存在 baseline-all；
当前实验保留独立测量入口，只接入 YOLO 加速器，不含 MiniMind。正式 main、baseline-yolo、baseline-minimind、baseline-all 尚未更新；详细变更用 git log/git show 查询。
