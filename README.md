# hgb-aisystem

`hgb-aisystem_riscv` 是硬件协作发布、理解文档与未来软件栈的仓库；共享的
SystemVerilog Core 是单发射、顺序执行的 RV32/RV64 六级流水线：

```text
IF → D1 → D2 → EX → MEM → WB
```

构建时可选择 RV32 或 RV64，已实现整数基础指令、M 乘除扩展、六种 Zicsr 指令、
ECALL/EBREAK/MRET、机器模式精确同步异常/中断，以及 BTB + 非推测 GShare。
Core 使用独立的指令和数据 ready/valid 接口，不直接实例化 FPGA BRAM。

## 当前状态

- RV32IM/RV64IM 六级流水、GPR/CSR 前递、load-use 检测和存储器反压。
- 单条在途多周期 MDU：统一握手与取消；三种乘法、两种除法可选，默认 DSP 推断乘法 + 移位除法（most easy）。
- JAL 在 D1 解析；条件分支与 JALR 在 EX 解析。
- `muldiv_unit` 独立于流水级：EX 内的 `ex_mdu` 发射请求，MEM 内的 `mem_mdu` 接收并拼接结果；package 仅保留类型与常量。
- 三主端口互连和单通道 DMA 已接入 SoC；AXI4 单拍桥与可变延迟 RAM 完成外存仿真闭环。
- DDR 已接入两路阻塞式 I$/D$（各默认 4 KiB/32 B 行）；D$ 使用 WB/WA，FENCE.I 等待脏代码发布后恢复取指。
- D$ 提供 MMIO clean/flush/invalidate 及状态，DMA 使用显式所有权交接；TCM/MMIO 旁路。
- 脏逐出失败保留缓存数据；FENCE.I 自动写回失败停取指直到复位，不宣称具备机器检查恢复。
- CSR 在 EX 完成读改写与 WARL，WB 执行架构提交。
- SoC：启动 ROM、I/D-TCM、2 路 UART、机器/通用 Timer、3 组 GPIO、外部中断汇聚与 DMA。
- `mie/mip` 接入真实设备电平；中断排空流水，保存实际后继 PC 后进入 Direct `mtvec`。
- Verilator 纯 SystemVerilog 测试，不使用 Cocotb。
- RV32/RV64 各 42 项单元测试；18 项整核定向流程中各 17 PASS、1 非适用位宽 SKIP。
- 适用的 riscv-tests：RV32 `58/58`，RV64 `78/78`，包括全部 8/13 项 UM；
  旧分离存储器路径跳过 fence_i/ma_data；SoC 路径含 fence_i，为 `59/59`、`79/79`，仅跳过 ma_data。
- CoreMark 1.0 performance/validation CRC 均通过；默认 MDU 配置的固定迭代数结果：
  RV32 `2.897145`、RV64 `2.579496 CoreMark/MHz`（Verilator 周期成绩）。

S3 DMA/外存与 S4 WT/NWA Cache 的验收提交保留在 Git 历史；`SOC/all` 使用 S5 的 WB/WA 与维护协议，
Cache 专项 RV32/RV64 各 18 PASS，设计见 [写回与数据交接](docs/understand/S5_CACHE_WRITEBACK.md)。
独立 DDR CoreMark 和三主端口 Cache 压力测试仍待后续。盘古 676-200K Pro、Zynq-7020 的 DDR3 IP 和上板时序验证继续后推。
软件栈和 AI 功能仍是独立后续目标；以上成绩不代表 FPGA Fmax。

## 快速验证

从仓库根目录运行：

```bash
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make benchmark-smoke XLEN=64
make coremark XLEN=32
make coremark XLEN=64
make mdu-backends XLEN=32
make mdu-backends XLEN=64
make soc-test XLEN=32
make soc-software XLEN=32
make soc-dma-software XLEN=32
make soc-riscv-tests XLEN=32
make soc-coremark XLEN=32
make cache-test XLEN=32
# SoC 命令同样须以 XLEN=64 运行。
```

RISC-V 工具链默认位于 `/opt/riscv/bin`。`make test` 包含 lint、单元测试和
整核定向测试，但不自动包含 `make riscv-tests`。生成物写入 `build/`，日志
写入 `logs/`，二者都不进入版本库。

## 目录入口

- `vsrc/core/`：与平台无关的可综合 Core。
- `vsrc/soc/`：可移植 I$/D$、互连、ROM/TCM、DMA、MMIO 外设与中断。
- `vsrc/sim_cpu/`：不可综合的仿真存储器和通用仿真顶层。
- `vsrc/cpu/`：规划中的双平台 FPGA wrapper，优先盘古 676-200K Pro。
- `tb/`：单元、整核和上游 riscv-tests 适配测试。
- `scripts/`：Verilator、工具链和 Vivado Tcl 工作流。
- `benchmark/`：裸机 BSP、C 冒烟程序、固定 CoreMark 源码和本地 port。

## 阅读 SoC 前

先从 [理解文档导读](docs/understand/README.md) 依次读 [M 扩展](docs/understand/M_EXTENSION.md)、[CSR、异常和中断](docs/understand/CSR_TRAPS_AND_INTERRUPTS.md)、[I/D 访存握手](docs/understand/MEMORY_HANDSHAKE.md)。它们解释 EX/MEM 的 M 结果汇合、WB 精确提交，以及请求接受沿与响应返回沿的区别。再沿 [SoC 源码导读](docs/understand/SOC_SOURCE_WALKTHROUGH.md) 查历史阶段的模块和测试。hgb 的 `main` 仍是 Core/M 基线；`SOC/all` 的源码与阶段提交对应关系见 [文档入口](docs/README.md)。

## 文档

- [文档入口与分支范围](docs/README.md)、[理解文档导读](docs/understand/README.md)
- [SoC 访存契约](docs/SOC_BUS_CONTRACT.md)、[外设连接图与寄存器](docs/SOC_PERIPHERALS.md)、[AXI/DDR 边界](docs/SOC_EXTERNAL_MEMORY.md)
- [项目目录说明](docs/PROJECT_STRUCTURE.md)、[硬件目标](docs/HARDWARE_ROADMAP.md)、[软件开发目标](docs/SOFTWARE_ROADMAP.md)、[仿真与 FPGA 工作流](docs/SIMULATION_AND_FPGA.md)
- [历史修改记录](docs/COMMIT.md)、[贡献与 Agent 规则](AGENTS.md)
