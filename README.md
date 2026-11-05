# hgb-aisystem_riscv

面向紫光 FPGA 的 RISC-V 双发射 SoC，集成片上存储、Cache、AXI 总线、DMA、DDR3 与外设，提供 CoreMark、YOLO、MiniMind 和 RT-Thread 软件。

## 项目功能

| 模块 | 已实现功能 |
|---|---|
| 处理器 | RV32/RV64 IM+Zicsr，双取指、双发射、双退休，支持机器态异常和中断 |
| 执行与提交 | Scoreboard 跟踪数据依赖，ROB 保存结果与程序顺序；整数、访存分队列，完成与退休分离；双 ALU、双 AGU |
| 分支预测 | BTB、全局/局部预测与锦标赛选择；当前关闭 RAS 和有限整数乱序选项 |
| 片上存储 | Boot ROM、64 KiB ITCM、64 KiB DTCM；TCM 使用双端口 BRAM，独立指令与数据 Cache |
| 总线与外设 | AXI 仲裁与缓冲、DMA、UART、GPIO、Timer、PLIC、MMIO；异步 FIFO 传输跨域请求和响应 |
| 外存 | DDR3 控制器适配、Cache 行传输、DMA 块搬运 |
| CoreMark | 理想存储、真实 TCM、SoC+TCM、SoC+Cache+DDR 分层测量；UART 接收命令、返回周期和 CRC |
| YOLO | 128-MAC INT8 卷积加速器、YOLOX-Tiny 网络调度、UART 图片收发、HDMI 显示链路 |
| MiniMind | 整数算子加速器、原作者 C 程序、模型与分词器、常驻文本交互程序 |
| RT-Thread | BSP、DDR 运行测试和独立串口终端应用，仅保存在 `all` |

Core 常用配置为 ROB16、整数队列 8 项、访存队列 4 项、LQ4/SQ4，ALU/Load/DSP 路径分别为 8/10/10 级。RV32 用于性能优化，RV64 保留功能验证；未实现 C、F、V 扩展和 MMU。

四个分支共用本说明，硬件与软件按用途分别保存：

| 分支 | 硬件 | 软件与用途 |
|---|---|---|
| `main` | 无 NPU 的四域 SoC | 分层 CoreMark、串口 CoreMark 演示 |
| `yolo` | SoC、YOLO NPU、HDMI | YOLO 程序、模型、测试图片与上位机工具 |
| `minimind` | SoC、MiniMind 加速器 | 原作者软件、整数模型、文本交互程序 |
| `all` | SoC 与两套加速器 | 全部软件、一份 RT-Thread，联合仿真 |

## 项目结构与目录

```text
vsrc/core/       处理器流水线、队列、执行单元与退休逻辑
vsrc/pkg/        指令、总线与控制类型
vsrc/soc/        ROM、TCM、Cache、AXI、DMA、MMIO 与跨域接口
vsrc/cpu/        FPGA 顶层、PLL、复位与 DDR 桥
tb/             单元、CPU、SoC、ISA 适配与应用测试
software/       启动代码、驱动、应用、模型与软件测试
benchmark/      CoreMark 算法与仿真端口（main、all）
third_party/    YOLO RTL、RT-Thread 等分支依赖
scripts/        构建、仿真、串口工具与 PDS 脚本
constr/         FPGA 约束说明
ip/             厂商 IP 接口与生成说明
docs/           项目配置、微架构与 FPGA 适配文档
```

应用目录随分支保留。`scripts/branch_profile.json` 列出当前应用，`scripts/hardware_profile.json` 保存公共参数；`make software-list` 和 `make help` 列出当前分支的执行入口。

```bash
git clone git@github.com:astshby/hgb-aisystem_riscv.git
cd hgb-aisystem_riscv
git branch -a
git switch yolo  # 也可选择 main、minimind、all
```

## 项目验证

Linux/WSL 使用 Python 3.10 及以上、Make、C/C++ 编译器、Verilator 和裸机 RISC-V 工具链。已使用 GCC 16.1.0、Verilator 5.052；工具链需支持 `rv32im_zicsr/ilp32` 与 `rv64im_zicsr/lp64`。

```bash
export RISCV_TOOL_ROOT=/path/to/riscv/bin
make boot-count-test XLEN=32
make boot-count-test XLEN=64
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
```

`make test` 检查公共功能，ISA 测试单独运行。软件依赖、模型准备、固件构建与各应用仿真命令见[软件说明](software/README.md)。

| 验证对象 | 已完成结果 |
|---|---|
| 四分支公共启动 | 各分支 RV32/RV64 计数与启动测试各 9 PASS；独立多域启动各 4 PASS |
| main 功能与 ISA | RV32/RV64 功能测试各 82 PASS、2 SKIP；ISA 分别 58/78 PASS，各排除 2 项 |
| CoreMark | RV32/RV64 的 performance、validation 与真实 SoC UART 命令循环通过；周期、CRC、DONE/READY 和电脑解析已检查 |
| YOLO | 同一 C 程序在电脑执行调度，与真实 NPU、总线、UART、显示 RTL 联合仿真通过；另完成 RV32/RV64 驱动短测 |
| MiniMind | 双宽单层算子与参考对照、DMA 并发通过；原生整数 C 程序完成八层推理与连续请求测试 |
| all 与 RT-Thread | 双宽联合 SoC 地址、中断、仲裁和复位测试通过；RT-Thread 双宽 DDR 运行测试通过，独立终端完成构建与命令测试 |

CoreMark/MHz 按 `iterations × 1,000,000 / Core计时区周期` 计算。M0 使用测试台一周期存储；`core_tcm`、`soc_tcm`、`soc_ddr` 分别测量真实 TCM、SoC+TCM、SoC+Cache+DDR。其他域的等待计入 Core 周期，RT-Thread 独立测试。

历史 O3、64 次迭代仿真中，M0 的 RV32 performance/validation 为 **3.590617/3.570731 CoreMark/MHz**，RV64 为 **3.145656/3.133377**；真实 Core+TCM 的 RV32 为 **3.095736/3.081770**。分层配置与实验数据见[优化总结](docs/understand/OPTIMIZATION.md)。正式 CoreMark 成绩还需计时至少十秒。

完整板端 YOLO 推理与 HDMI 显示、MiniMind 全模型 RTL/板端运行尚未完成。MiniMind 多写 RAM 综合和模型装载仍需修正；启动计数修复后的网表与板上 READY 尚未重新测量。

## FPGA 配置

| 项目 | 配置 |
|---|---|
| 工具与器件 | Windows Pango PDS 2025.2 ADS，PG2L200H-6IFBB676 |
| 完整系统顶层 | `vsrc/cpu/pango_200hp_top.sv`；`all` 使用联合仿真顶层 `soc_all_system` |
| 存储参数 | ITCM/DTCM 各 64 KiB；已有完整系统测量选 I$16 KiB、D$8 KiB、32 B 行、D$ bank XOR mask2 |
| Cache 参数传递 | 构建时显式传入 16/8 KiB 与 mask2；通用接口默认仍为 4/4 KiB、mask0 |
| Core 域 | Core、TCM 与 Cache 命中逻辑 |
| SYS 域 | 总线仲裁与 DMA；DDR 用户域、外设域分别跨域连接 |
| 加速器与视频 | NPU 独立时钟；YOLO 视频使用独立 148.5 MHz PPLL |
| 系统时钟 | 一颗系统 GPLL 产生 Core/SYS/外设/NPU 时钟；DDR 用户钟由 DDR IP 提供 |
| 实现策略 | `timing-v2`：8 线程、fanout64、retiming 开、算术资源共享关、布局双输出 LUT 合并关、布线时序权重 80；normal 布局/布线，开启 recovery 与 route_optimize |
| 运行内存 | 启动及 dev_map/place/route/route_optimize 阶段，Windows 可用物理内存、可用提交内存均至少 6 GiB |

| 分支与时钟档 | Core / SYS / DDR-user / 外设 / NPU，MHz |
|---|---|
| main，C9 `main_margin2` | 88.75 / 98.611111 / 125 / 68.269231 / 无 |
| yolo，C10 `yolo_sys` | 83.806818 / 102.430556 / 125 / 65.848214 / 92.1875 |
| minimind，C1 `target` | 100 / 80 / 125 / 25 / 100 |
| all | 按所选仿真时钟配置；两套加速器分别接入时钟与复位 |

表中频率为配置值。历史 main C9 布线 Core Fmax 为 90.3702 MHz，YOLO C10 为 85.9387 MHz；两者均早于本次启动计数修复。各分支的诊断时钟、PLL 分频、完整 PDS 命令、时序与资源结果见 [FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。

`PDS_HOME` 指定工具安装目录，`PDS_WORK_ROOT` 保存生成 IP、原生工程、网表与报告。固件和 IP 重新构建后，依次运行综合、CDC 绑定、布局布线与位流生成；执行脚本在 `scripts/pango/`。

详细目录与配置见[项目介绍](docs/PROJECT_INTRO.md)，微架构见[设计文档](docs/understand/README.md)，其他文档见[文档索引](docs/README.md)。
