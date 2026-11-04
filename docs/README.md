# 文档入口

| 文档 | 内容 |
|---|---|
| [软件与复现入口](../software/README.md) | 程序、模型、固定图片和可执行测试 |
| [PROJECT_INTRO.md](PROJECT_INTRO.md) | 项目目录、参数、环境、仿真性能、FPGA 性能、功能与边界 |
| [understand/README.md](understand/README.md) | 五份学习总结：SoC、双发射、DDR/AXI、FPGA、优化 |
| [fpga/FPGA_ADAPTATION.md](fpga/FPGA_ADAPTATION.md) | PDS 流程、时钟约束、时序与资源结果 |
| [fpga/YOLO_BRINGUP_STATUS.md](fpga/YOLO_BRINGUP_STATUS.md) | YOLO 板级启动诊断与证据边界 |

## 阅读顺序

1. [项目配置与测量](PROJECT_INTRO.md)：核心参数、时钟档、仿真与物理结果。
2. [系统结构](understand/SOC_SYSTEM.md) 与 [双发射](understand/DUAL_ISSUE.md)：微架构。
3. [DDR/AXI](understand/DDR_AXI.md)：总线、存储与跨时钟域。
4. [FPGA 适配](fpga/FPGA_ADAPTATION.md)：PDS 综合、布局布线、时序与位流。
5. [优化](understand/OPTIMIZATION.md)：当前瓶颈、已做取舍与后续方向。

## 源码入口

- `vsrc/core/`：Core。
- `vsrc/soc/`：SoC。
- `vsrc/cpu/`：FPGA 顶层、PLL 与 DDR/视频桥。
- `vsrc/sim_cpu/`：仿真存储模型。
- `tb/`：测试。
- `scripts/`：仿真、PDS、固件与工具入口。
- `software/`：裸机固件与上位机程序。
- `benchmark/`：裸机 CoreMark。

修改 RTL 前先看对应学习文档与测试；功能和性能边界以源码、测试和实测日志为准。
仿真分数、综合估计、布线时序与板上测量分开记录，不互相替代。
