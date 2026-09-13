# 项目仿真与上板说明

## 环境与入口

所有命令从仓库根目录运行。主要工具为 Verilator 和 RISC-V GNU 工具链，不使用
Cocotb。默认配置：

```text
VERILATOR=verilator
RISCV_TOOL_ROOT=/opt/riscv/bin
RISCV_TESTS_DIR=tb/riscv_tests/vendor/riscv-tests
XLEN=32
```

`XLEN` 是构建时选项，同一份 RTL 分别生成 RV32 和 RV64 实例，不支持运行时切换。

## 源码清单

- `scripts/rtl_files.f`：Package、Core 和可综合功能模块。
- `scripts/sim_files.f`：引用 RTL 清单并加入仿真存储器和 `sim_cpu_top`。
- `scripts/cpu_files.f`：引用 RTL 清单并加入复位同步与 `cpu_top`。

Package 必须先于使用者编译。Verilator 和 Vivado 共用 `rtl_files.f`，避免两套工程
的源码顺序漂移。

Core 与存储器的时序契约详见 [BRAM、Cache 与存储器握手](understand/MEMORY_HANDSHAKE.md)。

## Make 目标

| 命令 | 作用 |
|---|---|
| `make` | 因为 `lint` 是首个目标，所以只执行默认 RV32 lint |
| `make lint XLEN=32` | 分别 lint `core`、`sim_cpu_top`、`cpu_top` |
| `make unit XLEN=32` | 遍历并运行全部 `tb/unit/tb_*.sv` |
| `make directed XLEN=32` | 遍历并运行全部 `tb/core/tb_*.sv` |
| `make test XLEN=32` | 依次运行 lint、unit、directed |
| `make riscv-tests XLEN=32` | 编译并运行 A4 适用的正式 MI/UI 回归；不属于 `make test` |
| `make benchmark-smoke XLEN=32` | 验证裸机 C 运行时、软件算术和 64 位周期读取 |
| `make coremark XLEN=32` | 执行 CoreMark 校准、performance 与 validation；不属于 `make test` |
| `make vivado-project XLEN=32` | 创建 Zynq-7020 Vivado 工程框架 |
| `make clean` | 删除 `build/`、`logs/` 和 `vivado-workspace/` |

共享 RTL 的标准回归：

```bash
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make benchmark-smoke XLEN=64
make coremark XLEN=32
make coremark XLEN=64
```

## 单元与整核测试

`run_unit.sh` 为每个单元 TB 建立独立的 Verilator `--binary` 工程，生成目录为：

```text
build/verilator/unit-rv<XLEN>/<tb_name>/
```

运行生成的 `V<tb_name>` 后，脚本要求日志中存在 `PASS <tb_name>`。由于脚本启用
`set -euo pipefail`，编译失败、仿真非零退出或没有 PASS 标记都会使回归失败。

`run_directed.sh` 使用完整 `sim_cpu_top` 运行 `tb/core/` 的短程序。指令由
`tb/common/rv_asm_pkg.sv` 的 `enc_addi`、`enc_jal`、`enc_csrrw` 等函数直接编码，
适合精确定位流水、访存、预测和异常问题。

## riscv-tests 为什么能够运行

当前流程没有修改上游汇编测试，而是提供与本 Core 匹配的执行环境：

```text
tb/riscv_tests/vendor/riscv-tests/isa 中 MI/UI 的 .S
  → GCC 使用 rv32i_zicsr/rv64i_zicsr 编译
  → 本地 riscv_test.h 提供 reset、寄存器初始化、mtvec 和 PASS/FAIL
  → 本地 link.ld 将代码放到 0x0、数据放到 0x1000
  → objcopy 分离 .text/.data
  → verilog_hex_to_mem.py 生成 IMem/DMem 按字镜像
  → tb_riscv_test 使用 $readmemh 加载
  → sim_cpu_top 执行
  → PASS/FAIL 执行退出 ECALL
  → Trap handler 写 ELF 的 tohost 符号
  → sim_dmem 接收，TB 被动观察 Store
```

正式回归包含适用的 RV32I/RV64I UI 指令测试，以及使用 Zicsr、
ECALL/EBREAK/MRET、机器 CSR 和地址未对齐异常的 MI 测试。它不会要求 M/A/C/F/D、
PMP、S/U 模式或异步中断。

本地环境已经定义 RV32U/RV64U 宏，但继续以 M-mode 承载 UI 基础指令测试。runner
显式维护 MI/UI 清单，保持 `-march=rv32i_zicsr`/`rv64i_zicsr`，并统一使用 reset、
链接布局、Trap handler、超时和 `tohost` PASS/FAIL。不能通过修改 Core 识别测试魔数。

ECALL/EBREAK 不只是 Decoder 识别：测试还需要精确保存 `mepc/mcause/mtval`、清除
年轻副作用、跳转 `mtvec`，并由 handler 执行 MRET 返回。当前正式 machine 测试已
覆盖这条路径。退出 ECALL 使用 `a7=93` 区分，因此 `scall` 的被测 ECALL 仍进入其
自定义 handler。上游 `breakpoint`、`ma_fetch`、PMP、用户计数器别名等测试因为超出
A4 边界而没有纳入。

正式结果为 RV32 `50/50`（MI 10 + UI 40）、RV64 `65/65`（MI 13 + UI 52）。两种
位宽均明确跳过 `fence_i` 和 `ma_data`：前者属于 Zifencei 和可写指令存储一致性，
后者要求未对齐访问直接完成；二者均不是 CoreMark 依赖。完整交互过程和边界见根目录
[软件测试栈与硬件交互解读](understand/SOFTWARE_TEST_STACK_GUIDE.md)。

## 上游源码 Checkout

正式测试不需要根目录 clone：所需上游源码已固定在
`tb/riscv_tests/vendor/riscv-tests/`，随父仓库一起 clone。其版本为 riscv-tests
`933a897`、env `6de71ed`，许可证和来源记录在 `tb/riscv_tests/vendor/VENDORING.md`。

根目录 `riscv-tests/` 仅是可选的只读样本，不会随父仓库自动下载。需要阅读完整上游
工程时可自行准备：

```bash
git clone https://github.com/riscv-software-src/riscv-tests.git riscv-tests
git -C riscv-tests checkout 933a897
git -C riscv-tests submodule update --init --recursive
```

所有环境覆盖、链接布局、镜像转换和 Verilator harness 都保存在父仓库的
`tb/riscv_tests/` 或 `scripts/verilator/`。`RISCV_TESTS_DIR=/path/to/clean/checkout`
只用于临时对照另一个上游版本。

## 生成物和调试

每个上游测试生成：

- `.elf`：最终可执行文件；
- `.map`：链接段和符号布局；
- `.dump`：`objdump -d` 反汇编；
- `.vhex`：objcopy 输出的按字节 Verilog hex；
- `imem.hex/dmem.hex`：仿真存储器加载镜像。

日志写入 `logs/`。单个 riscv-test 可在已生成镜像后手动打开提交跟踪：

```bash
build/verilator/riscv-tests-rv32/Vtb_riscv_test \
  +IMEM=build/riscv-tests/rv32/csr/imem.hex \
  +DMEM=build/riscv-tests/rv32/csr/dmem.hex \
  +TOHOST=00001000 \
  +TEST=csr +TRACE
```

`build/` 和 `logs/` 可重建，不应参与功能审阅。重命名测试后旧 build 子目录不会
自动消失；需要清理时再显式运行 `make clean`。

## CoreMark 仿真

上游 `riscv-tests/benchmarks/` 不是 CoreMark。A5 将官方 EEMBC `v1.01` 固定在
`benchmark/coremark/vendor/coremark/`，其被测源码不作修改；启动、链接、计时、
输出和软件算术分别放在 `benchmark/bsp/` 与 `benchmark/coremark/port/`。

`make coremark` 先以一次 performance 迭代校准，再把正式迭代数放大到约 11M 个
计时周期。performance 和 validation 使用各自规范 seeds，内存均为 2000 bytes，
两次运行都必须输出 `Correct operation validated`。仿真按 1 MHz 对周期归一化：

```text
CoreMark/MHz = Iterations × 1,000,000 / Total ticks
```

当前结果为 RV32 `11 / 11,148,066 = 0.986718 CoreMark/MHz`，RV64
`10 / 12,004,387 = 0.833029 CoreMark/MHz`。运行日志位于
`logs/coremark-{performance,validation}-rv<XLEN>.log`；ELF、map、dump 与镜像位于
`build/benchmark/coremark-rv<XLEN>/`。可用 `COREMARK_ITERATIONS=N` 固定迭代数；只有
已知实际时钟时才设置 `COREMARK_FREQ_MHZ=F` 估算 CoreMark/s。

benchmark harness 单独把 IMem/DMem 扩为 128 KiB，普通 TB 的默认容量不变。字符输出
是 TB 对 `sim_console` Store 的被动镜像，结束仍使用 ECALL 后写 `tohost`；它不是硬件
UART。更多限制和上板指标见 [CoreMark 与性能指标解读](understand/COREMARK_AND_PERFORMANCE.md)。

## Vivado 与上板

目标器件是 `xc7z020clg400-1`。当前仅有脚本框架，Vivado 暂不作为 A4 验收项。

```bash
make vivado-project XLEN=32

vivado -mode batch -source scripts/vivado/synth.tcl \
  -tclargs vivado-workspace/project-rv32/rhbyv_cpu.xpr

vivado -mode batch -source scripts/vivado/impl.tcl \
  -tclargs vivado-workspace/project-rv32/rhbyv_cpu.xpr

vivado -mode batch -source scripts/vivado/program.tcl \
  -tclargs /path/to/rhbyv_cpu.bit
```

现阶段 `cpu_top` 将存储器 ready/valid 接成零，`create_project.tcl` 也没有加载
BRAM IP 或 XDC，因此只能创建/检查 RTL 工程，不能得到可运行的板级 CPU。A6 需要
完成 BRAM adapter、Instruction/Data BRAM、Clock Wizard、UART、地址映射和 XDC，
并保存综合 utilization、实现 timing 和 bitstream 结果。
