# 项目仿真与上板说明

## 环境与入口

所有命令从仓库根目录运行。主要工具为 Verilator 和 RISC-V GNU 工具链，不使用
Cocotb。默认配置：

```text
VERILATOR=verilator
RISCV_TOOL_ROOT=/opt/riscv/bin
RISCV_TESTS_DIR=tb/riscv_tests/vendor/riscv-tests
XLEN=32
MUL_IMPL=0
DIV_IMPL=0
```

`XLEN` 是构建时选项，同一份 RTL 分别生成 RV32 和 RV64 实例，不支持运行时切换。
`MUL_IMPL=0/1/2` 对应 DSP 推断、Booth-Wallace、移位乘法；`DIV_IMPL=0/1` 对应
移位除法、Radix-4 SRT。Make 将选择导出给全部 Verilator runner，lint 也使用同一
选择。例如 `make test XLEN=64 MUL_IMPL=1 DIV_IMPL=1`。普通 runner 会覆盖相同
位宽的旧日志，不要并发运行同一位宽的不同配置；六组合矩阵使用独立目录。

## 源码清单

- `scripts/rtl_files.f`：Package、Core 和可综合功能模块。
- `scripts/sim_files.f`：引用 RTL 清单并加入仿真存储器和 `sim_cpu_top`。
- `scripts/soc_files.f`：引用 RTL 清单并加入可移植 ROM/TCM/互连/外设和 `soc_top`。
- `scripts/cpu_files.f`：引用 RTL 清单并加入复位同步与 `cpu_top`。

Package 必须先于使用者编译。Verilator 和 Vivado 共用 `rtl_files.f`，避免两套工程
的源码顺序漂移。

Core 与存储器的时序契约详见 [存储器握手解读](understand/MEMORY_HANDSHAKE.md)。

## Make 目标

| 命令 | 作用 |
|---|---|
| `make` | 因为 `lint` 是首个目标，所以只执行默认 RV32 lint |
| `make lint XLEN=32` | 分别 lint `core`、`sim_cpu_top`、`cpu_top` |
| `make unit XLEN=32` | 遍历并运行全部 `tb/unit/tb_*.sv` |
| `make directed XLEN=32` | 遍历并运行全部 `tb/core/tb_*.sv` |
| `make test XLEN=32` | 依次运行 lint、unit、directed |
| `make riscv-tests XLEN=32` | 编译并运行 A4+B 适用的 MI/UI/UM 回归；不属于 `make test` |
| `make benchmark-smoke XLEN=32` | 验证裸机 C、硬件 M、宽整数 helper 和 64 位周期读取 |
| `make coremark XLEN=32` | 执行 CoreMark 校准、performance 与 validation；不属于 `make test` |
| `make mdu-backends XLEN=32` | 先运行正式 ISA 回归，再运行六种 MDU 配置各 5 项 M 整核测试和全部 UM |
| `make soc-lint XLEN=32` | lint 可移植 SoC 顶层 |
| `make soc-test XLEN=32` | 两种互连仲裁、ROM/TCM 和外设 MMIO 测试 |
| `make soc-software XLEN=32` | C 程序验证全部设备 IRQ、MRET 和同步访问错误 |
| `make soc-smoke XLEN=32` | ROM 启动、I/D-TCM 布局的裸机 C 冒烟 |
| `make soc-riscv-tests XLEN=32` | 统一物理 I-TCM 执行 MI/UI/UM，包含 fence_i |
| `make soc-coremark XLEN=32` | 在 I/D-TCM 上运行 CoreMark performance/validation |
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
make mdu-backends XLEN=32
make mdu-backends XLEN=64
```

当前两种 XLEN 各 42 项 unit PASS，directed 各 16 PASS、1 非适用位宽 SKIP。
unit 包含全部六种 MDU 配置的算术/握手测试、8 位穷举和独立 SRT QDS/在线转换测试。
MDU 整核矩阵另存于 `logs/mdu-matrix-rv<XLEN>/`；构建位于
`build/verilator/mdu-matrix-rv<XLEN>/m<MUL_IMPL>d<DIV_IMPL>/`。

新访存接口与 SoC 协议测试已纳入标准回归，详见
[SoC 访存契约](SOC_BUS_CONTRACT.md)。SoC 回归独立于 `make test`，两种位宽均须运行。

## 单元与整核测试

`run_unit.sh` 为每个单元 TB 建立独立的 Verilator `--binary` 工程，生成目录为：

```text
build/verilator/unit-rv<XLEN>/<tb_name>/
```

运行生成的 `V<tb_name>` 后，脚本要求日志中存在 `PASS <tb_name>`。由于脚本启用
`set -euo pipefail`，编译失败、仿真非零退出或没有 PASS 标记都会使回归失败。
所有仿真构建显式启用 `--assert`；runner 还检查 `%Fatal/%Error/Assertion failed`，
即使进程返回 0 或已经打印 PASS，存在致命错误也不能算通过。成功路径先跳出 TB
采样循环，之后统一 `$finish`；只有未完成才执行超时 `$fatal`。

`run_directed.sh` 使用完整 `sim_cpu_top` 运行 `tb/core/` 的短程序。指令由
`tb/common/rv_asm_pkg.sv` 的 `enc_addi`、`enc_jal`、`enc_csrrw` 等函数直接编码，
适合精确定位流水、访存、预测和异常问题。

## riscv-tests 为什么能够运行

当前流程没有修改上游汇编测试，而是提供与本 Core 匹配的执行环境：

```text
tb/riscv_tests/vendor/riscv-tests/isa 中 MI/UI/UM 的 .S
  → GCC 使用 rv32im_zicsr/rv64im_zicsr 编译
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
ECALL/EBREAK/MRET、机器 CSR 和地址未对齐异常的 MI 测试，以及全部 RV32UM/RV64UM
乘除测试。它不会要求 A/C/F/D、
PMP、S/U 模式或异步中断。

本地环境已经定义 RV32U/RV64U 宏，但继续以 M-mode 承载 UI 基础指令测试。runner
显式维护 MI/UI 清单，使用 `-march=rv32im_zicsr`/`rv64im_zicsr`，并统一使用 reset、
链接布局、Trap handler、超时和 `tohost` PASS/FAIL。不能通过修改 Core 识别测试魔数。

ECALL/EBREAK 不只是 Decoder 识别：测试还需要精确保存 `mepc/mcause/mtval`、清除
年轻副作用、跳转 `mtvec`，并由 handler 执行 MRET 返回。当前正式 machine 测试已
覆盖这条路径。退出 ECALL 使用 `a7=93` 区分，因此 `scall` 的被测 ECALL 仍进入其
自定义 handler。上游 `breakpoint`、`ma_fetch`、PMP、用户计数器别名等测试因为超出
A4 边界而没有纳入。

Core-only 结果为 RV32 `58/58`（MI 10 + UI 40 + UM 8）、RV64 `78/78`
（MI 13 + UI 52 + UM 13）。两种
位宽均明确跳过 `fence_i` 和 `ma_data`：前者属于 Zifencei 和可写指令存储一致性，
后者要求未对齐访问直接完成；二者均不是 CoreMark 依赖。完整交互过程和边界由
[软件测试栈解读](understand/SOFTWARE_TEST_STACK_GUIDE.md) 维护。

## SoC 镜像与测试

`make soc-software` 使用 `tb/soc/irq_crt0.S` 和 `peripheral_smoke.c`；
UART/GPIO 在 TB 引脚侧环回，软件实际配置设备、接收中断、claim/complete 并 MRET，
不是绕过 UART 状态机或伪造 CSR。普通 `soc-smoke`/`soc-coremark` 不打开外设 IRQ。
镜像测试均保留 tohost 被动监视；benchmark 字符输出仍是 RAM 镜像，不声称经过 UART。

`benchmark/bsp/link_soc.ld` 将代码放 `0x01000000` 的 I-TCM、数据和栈放
`0x01100000` 的 D-TCM，各 64 KiB；ROM 从 0 跳到 I-TCM。
`tb/riscv_tests/env/link_soc.ld` 将 ISA 的代码和数据都放 I-TCM，允许 fence_i 执行数据段代码。
镜像转换使用 `--base`，RV64 I-TCM hex 为 64 位字，不再假定指令镜像总为 32 位。

SoC ISA：RV32 59/59（MI 10/UI 41/UM 8）、RV64 79/79（MI 13/UI 53/UM 13），
仅 SKIP `ma_data`；旧分离 I/D harness 仍 SKIP `fence_i` 和 `ma_data`。
SoC 路径和旧路径使用独立 `-soc` 构建/日志，避免覆盖彼此镜像。
外设寄存器、访问格式及中断边界见 [SoC 外设接口](SOC_PERIPHERALS.md)。

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
  +IMEM=build/riscv-tests/rv32/mi/csr/imem.hex \
  +DMEM=build/riscv-tests/rv32/mi/csr/dmem.hex \
  +TOHOST=00001000 \
  +TEST=csr +TRACE
```

`build/` 和 `logs/` 可重建，不应参与功能审阅。重命名测试后旧 build 子目录不会
自动消失；需要清理时再显式运行 `make clean`。

## CoreMark 仿真

上游 `riscv-tests/benchmarks/` 不是 CoreMark。A5 将官方 EEMBC `v1.01` 固定在
`benchmark/coremark/vendor/coremark/`，其被测源码不作修改；启动、链接、计时、
输出和软件算术分别放在 `benchmark/bsp/` 与 `benchmark/coremark/port/`。
当前默认用 `rv32im_zicsr/rv64im_zicsr` 重新编译，直接执行硬件 M；软件 helper
仍保留以满足 RV32 的 64 位算术等 ABI 需要，不修改官方 benchmark 源码。

`make coremark` 先以一次 performance 迭代校准，再把正式迭代数放大到约 11M 个
计时周期。performance 和 validation 使用各自规范 seeds，内存均为 2000 bytes，
两次运行都必须输出 `Correct operation validated`。仿真按 1 MHz 对周期归一化：

```text
CoreMark/MHz = Iterations × 1,000,000 / Total ticks
```

当前默认 `MUL_IMPL=0 DIV_IMPL=0`、固定迭代数的结果为 RV32
`32 × 1,000,000 / 11,045,355 = 2.897145 CoreMark/MHz`，RV64
`28 × 1,000,000 / 10,854,767 = 2.579512 CoreMark/MHz`。
当前独立测量的 SoC I/D-TCM 路径得到相同的计时区间周期与分数，ROM 启动额外 6 拍
不在 CoreMark 测量区间；两个路径仍保留各自日志，不能用一致分数替代协议验证。
非默认后端尚未做正式 CoreMark 跑分，不能借用这些分数。
运行日志位于
`logs/coremark-{performance,validation}-rv<XLEN>-m<MUL_IMPL>d<DIV_IMPL>[-soc].log`；ELF、map、dump 与镜像位于
`build/benchmark/coremark-rv<XLEN>-m<MUL_IMPL>d<DIV_IMPL>[-soc]/`。可用 `COREMARK_ITERATIONS=N` 固定迭代数；只有
已知实际时钟时才设置 `COREMARK_FREQ_MHZ=F` 估算 CoreMark/s。

benchmark harness 单独把 IMem/DMem 扩为 128 KiB，普通 TB 的默认容量不变。字符输出
是 TB 对 `sim_console` Store 的被动镜像，结束仍使用 ECALL 后写 `tohost`；它不是硬件
UART。更多限制和上板指标由
[CoreMark 指标解读](understand/COREMARK_AND_PERFORMANCE.md) 维护。

## 双平台与上板

首个目标是盘古 676-200K Pro，待其 TCM/基础总线/外设完成板级闭环后再适配
Zynq-7020；两板共享 Core 的 ready/valid 契约，IP、时钟与约束分别实现。平台边界
见 [平台适配](PLATFORM_ADAPTATION.md)，Cache/TCM/DMA 总线分层见该文档链接的设计草案。
目前均未完成上板，以下 Vivado 命令只保留历史工作流。

### 盘古 676-200K Pro（先实施）

先核实准确板卡资料、器件/封装、厂商工具、时钟、BRAM/DDR IP 接口和引脚；
然后建立独立厂商工程、TCM/存储器适配、UART/Timer MMIO 与约束。不要复用
Xilinx IP 配置或 XDC，也不要在核实 IP 前假定 DDR 用户接口就是 AXI4。
完成可重建工程、综合、实现、时序和 ISA/CoreMark 上板测试后，才称为平台支持。

### 保留的 Zynq-7020 Vivado 工作流（后适配）

```bash
make vivado-project XLEN=32

vivado -mode batch -source scripts/vivado/synth.tcl \
  -tclargs vivado-workspace/project-rv32/rhbyv_cpu.xpr

vivado -mode batch -source scripts/vivado/impl.tcl \
  -tclargs vivado-workspace/project-rv32/rhbyv_cpu.xpr

vivado -mode batch -source scripts/vivado/program.tcl \
  -tclargs /path/to/rhbyv_cpu.bit
```

现有 Tcl 默认器件为 `xc7z020clg400-1`，`cpu_top` 把存储器 ready/valid
接成零，工程尚未加载 BRAM IP 或 XDC；上述命令不能生成可运行的板级 CPU。
后续需完成存储器适配、时钟、复位、引脚和实现报告。若接入 Zynq 的 PS DDR，
须另定 PS 初始化与 PS–PL 端口方案；只用 PL 的首版不依赖 PS DDR。
