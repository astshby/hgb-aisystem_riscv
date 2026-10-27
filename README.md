# hgb-aisystem

RV32 优先的双发射 Core 与多时钟 SoC。RV64 跟随共享 RTL 做功能和 ISA 验证。
当前公共候选采用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0；
正常 ALU/Load/DSP 路径为 8/10/10 级，C 扩展尚未实现。

## 四个发布分支

| 分支 | 内容 | 常用入口 |
|---|---|---|
| main | 无 NPU 四域系统、分层裸机 CoreMark、独立 RT-Thread | `make score`、`make rt-thread` |
| baseline-yolo | 同一 Core/SoC，加 YOLO 128-MAC 与软件；无 CoreMark/RT | `make yolo` |
| baseline-minimind | 同一 Core/SoC，加 MiniMind 算子和原作者软件；无 CoreMark/RT | `make minimind` |
| baseline-all | 上述全部源码，RT-Thread 只有一份；每次选择一种加速器或无加速器 | 上述入口均提供 |

本树为 **baseline-all 公共候选**。main 的内容通过 PR 交由维护者合并。
两种加速器共用 `0x20000000` 设备窗口，分别实例化；`0x10050000` 始终用于 Flash 控制。
Core/SYS/DDR 用户口/外设目标为 **100/80/125/25 MHz**，加速器独立域目标为 **100 MHz**。
这些数值是配置目标；综合估计和布局布线结果分别记录。

## 使用

设置 `RISCV_TOOL_ROOT` 为 RISC-V 交叉编译器 bin。外部 FPGA 工具分别由
`PDS_HOME`、`PDS_WORK_ROOT` 指定。运行 `make help` 查看本分支实际保留的入口。

```bash
make check XLEN=32
make check XLEN=64
SOFTWARE_OPT=O3 make score COREMARK_PLATFORM_OUT=build/score-O3
make rt-thread-fetch
make rt-thread XLEN=32
make yolo XLEN=32
make minimind XLEN=32
```

`SOFTWARE_OPT=O2|O3|Ofast`，默认 O3。CoreMark、RT-Thread、YOLO、MiniMind 分别编译和运行，
RT-Thread 不参与 CoreMark。MiniMind 的锁定模型需先按其说明恢复；RT-Thread 使用锁定 v5.2.2。
旧细粒度测试保留供定位故障，公共验证入口收敛为 `check` 与各应用入口。

本轮 O3 M0 64 次为 **3.590617/3.570731 CoreMark/MHz**（performance/validation）。
真实 TCM 的两次短测为 **3.052755/3.035846**；DDR cold/warm 为 **2.381312/2.395887**。
M0 使用一周期 TB 存储；其他层使用实际 TCM/Cache/总线。每层分母都是 Core 周期，
不能把 M0 数值套给 DDR 或加速器并发场景。短仿真不满足正式十秒测试时长。

RT-Thread 双宽通过四域 DDR 系统运行、Timer 切换和 DMA 热代码搬运。
YOLO 双宽完成卷积核对，并观察到 28 个 MAC 工作沿与独立 DDR DMA 重叠。
MiniMind 双宽通过五域单层 38 命令、运行库和并发 DMA；尚未完成本轮全模型多 Token 验证。
本轮只运行标准综合，不运行布局布线或上板。

目录、测量和边界见[项目介绍](docs/PROJECT_INTRO.md)，系统结构见[文档索引](docs/README.md)，
FPGA 流程见[适配说明](docs/fpga/FPGA_ADAPTATION.md)。
