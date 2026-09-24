# hgb-aisystem

`hgb-aisystem_riscv` 是硬件协作发布、理解文档与未来软件栈的仓库；共享的
SystemVerilog Core 是单发射、顺序执行的 RV32/RV64 六级流水线：

```text
IF → D1 → D2 → EX → MEM → WB
```

构建时可选择 RV32 或 RV64，已实现整数基础指令、M 乘除扩展、六种 Zicsr 指令、
ECALL/EBREAK/MRET、机器模式精确同步异常，以及 BTB + 非推测 GShare。
Core 使用独立的指令和数据 ready/valid 接口，不直接实例化 FPGA BRAM。

## 当前状态

- RV32IM/RV64IM 六级流水、GPR/CSR 前递、load-use 检测和存储器反压。
- 单条在途多周期 MDU：统一握手与取消；三种乘法、两种除法可选，默认 DSP 推断乘法 + 移位除法（most easy）。
- JAL 在 D1 解析；条件分支与 JALR 在 EX 解析。
- CSR 在 EX 完成读改写与 WARL，WB 执行架构提交。
- Verilator 纯 SystemVerilog 测试，不使用 Cocotb。
- RV32/RV64 各 40 项单元测试；15 项整核定向流程中各 14 PASS、1 非适用位宽 SKIP。
- 适用的 riscv-tests：RV32 `58/58`，RV64 `78/78`，包括全部 8/13 项 UM；
  Zifencei 与未对齐直接完成用例明确 SKIP。
- CoreMark 1.0 performance/validation CRC 均通过；默认 MDU 配置的固定迭代数结果：
  RV32 `2.897145`、RV64 `2.579512 CoreMark/MHz`（Verilator 周期成绩）。

硬件下一步先规划盘古 676-200K Pro 的 TCM/Cache、DMA、系统互连及外设，再
适配 Zynq-7020。软件栈和 AI 功能仍是独立后续目标；以上成绩不代表 FPGA Fmax。

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
```

RISC-V 工具链默认位于 `/opt/riscv/bin`。`make test` 包含 lint、单元测试和
整核定向测试，但不自动包含 `make riscv-tests`。生成物写入 `build/`，日志
写入 `logs/`，二者都不进入版本库。

## 目录入口

- `vsrc/core/`：与平台无关的可综合 Core。
- `vsrc/sim_cpu/`：不可综合的仿真存储器和通用仿真顶层。
- `vsrc/cpu/`：规划中的双平台 FPGA wrapper，优先盘古 676-200K Pro。
- `tb/`：单元、整核和上游 riscv-tests 适配测试。
- `scripts/`：Verilator、工具链和 Vivado Tcl 工作流。
- `benchmark/`：裸机 BSP、C 冒烟程序、固定 CoreMark 源码和本地 port。

## 文档

- [项目目录说明](docs/PROJECT_STRUCTURE.md)
- [硬件目标与阶段规划](docs/HARDWARE_ROADMAP.md)
- [软件开发目标](docs/SOFTWARE_ROADMAP.md)
- [仿真与 FPGA 工作流](docs/SIMULATION_AND_FPGA.md)
- [BRAM、Cache 与存储器握手](docs/understand/MEMORY_HANDSHAKE.md)
- [软件测试栈与硬件交互解读](docs/understand/SOFTWARE_TEST_STACK_GUIDE.md)
- [CoreMark 与性能指标解读](docs/understand/COREMARK_AND_PERFORMANCE.md)
- [阶段修改记录](docs/COMMIT.md)
- [贡献与 Agent 规则](AGENTS.md)
- [Cache、TCM、DMA 与系统总线设计](docs/understand/THINKING.md)
