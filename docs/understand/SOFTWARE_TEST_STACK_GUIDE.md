# 软件测试栈与硬件交互解读

本文以当前 riscv-tests 流程为例，解释一份 RISC-V 汇编源码如何经过工具链、链接、
存储器镜像、Verilator testbench 和六级流水 Core，最终得到 PASS/FAIL。本文描述的是
当前 A5 基线中的 A4 ISA 测试实现，不把未来 Cache、中断、操作系统或 FPGA 外设当成
已经完成的功能。

## 三类代码必须分清

| 层次 | 位置 | 归属与作用 |
|---|---|---|
| 上游样本 | `riscv-tests/` | 可选的独立只读 clone，仅供阅读和版本比较 |
| 固定测试源码 | `tb/riscv_tests/vendor/` | 随项目提交的上游 `.S`、编码、测试宏和许可证快照 |
| 本项目适配层 | `tb/riscv_tests/env/` | 启动环境、链接布局和 PASS/FAIL 协议 |
| 构建驱动 | `scripts/verilator/` | 调用工具链、生成镜像并启动 Verilator |
| 仿真硬件 | `vsrc/sim_cpu/` | IMem、DMem 和不解释测试协议的 Core wrapper |
| 可综合硬件 | `vsrc/core/` | 真正执行指令、CSR、异常和流水控制 |

根目录 `riscv-tests/` 不是本项目的可修改或运行依赖。所有与本 CPU 有关的修改必须
进入 `tb/riscv_tests/env/` 或 `scripts/verilator/`；vendor 快照只允许在明确升级上游
版本时整体刷新。别人 clone 本项目会得到 vendor 快照，不会自动得到根目录样本 clone。

## 完整执行链路

```text
vendored test.S + vendored test_macros.h
              │
              ├── 本地 riscv_test.h：启动、mtvec、PASS/FAIL
              └── 本地 link.ld：地址和 section 布局
                              │
                              ▼
                    GCC / assembler / linker
                              │
                              ▼
                    ELF + map + objdump
                              │
                    objcopy 分离 .text/.data
                              │
                              ▼
                       imem.hex / dmem.hex
                              │
                       Verilator $readmemh
                              │
                              ▼
                 sim_imem / sim_dmem / sim_cpu_top
                              │
                              ▼
                  IF→D1→D2→EX→MEM→WB
                              │
                    ECALL → mtvec handler
                              │
                       Store TESTNUM → tohost
                              ▼
                  sim_dmem + TB 被动监视 → PASS/FAIL
```

## 经典 riscv-tests 闭环需要哪些组件

一套可运行的 ISA 测试不只是若干 `.S` 文件，至少需要以下组成：

- **测试源码**：用汇编构造输入、执行目标指令并比较结果；
- **编码和测试宏**：`encoding.h`、`test_macros.h` 提供 CSR 编码与重复测试模板；
- **目标环境**：`riscv_test.h` 提供启动入口、Trap 入口以及 PASS/FAIL 约定；
- **链接布局**：链接脚本使复位 PC、代码、数据和签名区与硬件地址空间一致；
- **交叉工具链**：assembler/linker 生成 RISC-V ELF，objdump/objcopy 用于检查和拆镜像；
- **镜像转换与存储器模型**：把 ELF section 装入仿真的 IMem、DMem；
- **结果通道**：目标程序写 `tohost`，testbench 被动监视普通 DMem Store；
- **仿真控制**：testbench 提供 reset、时钟、超时、日志与最终 PASS/FAIL。

因此，把上游 `.S` 复制进仓库只解决“测试内容”问题；本地 env、链接脚本、runner 和
仿真硬件共同构成了可重复运行的验证闭环。

## Make 与运行脚本

入口命令为：

```bash
make riscv-tests XLEN=32
make riscv-tests XLEN=64
```

Makefile 只把 `XLEN` 传给 `scripts/verilator/run_riscv_tests.sh`。脚本随后完成两件相互
独立的工作：

- 用 Verilator 把 `core + sim_cpu_top + tb_riscv_test` 编译成宿主机可执行文件；
- 逐个把 RISC-V 汇编测试编译成目标机程序，再让上述可执行文件加载并运行它。

“宿主机可执行文件”运行在开发电脑的 x86/Linux 上，但它内部模拟的是 SystemVerilog
CPU；RISC-V ELF 不能直接由开发电脑执行，只能作为被模拟 CPU 的程序镜像。

## 本地环境从哪里来

上游测试通常这样开头：

```asm
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN
```

默认 GCC include 顺序是：

```text
-I tb/riscv_tests/env
-I tb/riscv_tests/vendor/riscv-tests/env
-I tb/riscv_tests/vendor/riscv-tests/isa/macros/scalar
```

因此 `riscv_test.h` 采用本项目版本；`encoding.h` 和 `test_macros.h` 使用未修改的
vendored 上游版本。这是标准 include 覆盖机制，不需要修改测试 `.S`。

本地 `riscv_test.h` 提供以下内容：

- `RVTEST_RV32M/RVTEST_RV64M`：声明当前测试环境的初始化宏；
- `INIT_XREG`：把 x1—x31 清零，消除未知初值；
- `_start/reset_vector`：CPU 从复位地址进入的第一段软件；
- `trap_vector`：区分退出 ECALL，并把其他异常交给测试自己的 `mtvec_handler`；
- `RVTEST_PASS/RVTEST_FAIL`：设置结果和退出 ABI 寄存器，再执行 ECALL；
- `RVTEST_DATA_BEGIN/END`：定义 `tohost/fromhost` 和签名数据区。

这里的“复位入口、寄存器初始化、mtvec、PASS/FAIL”都是软件汇编宏。CSR RTL 不负责
生成这些代码；CSR RTL 只负责正确执行宏展开后出现的 `csrw/csrr/mret` 等指令。

## 上游 `env/p` 与本地环境的区别

上游 `env/p` 是面向“物理地址、单 hart、较完整特权架构”的通用环境，不是为本 Core
量身设计的最小启动代码。它会尝试完成：

- 检查 XLEN、读取 `mhartid` 并停住其他 hart；
- 配置 PMP，使物理地址可读、可写、可执行；
- 初始化 `satp`、`mie`、`medeleg/mideleg` 等状态；
- 根据测试进入 M/S/U 模式；
- 区分异常和中断，并支持 `stvec_handler/mtvec_handler`；
- 通过 ECALL 进入 Trap，再把结果写到 `tohost`。

这些步骤会访问 A4 尚未实现的 PMP、S/U 模式、委托和中断 CSR。直接使用它会让
“环境启动失败”掩盖真正要测的 RV32I/RV64I 指令。

本地环境则只保留当前验证闭环所需的部分：M-mode、寄存器确定化、`mtvec`、同步
Trap、MRET 和 `tohost` 结束口。它更小、更贴合当前硬件，但不能称为比上游 `env/p`
更完整。

## ECALL/EBREAK 是基础测试的必需品吗

要分“被测 ISA”与“测试如何退出”两种用途：

- UI 算术、分支和访存测试本身不需要 ECALL/EBREAK；ECALL 只是当前统一的退出路径。
- 上游 `env/p` 的 `RVTEST_PASS/FAIL` 使用 ECALL，是为了统一进入 Trap 并转交给 host，
  属于退出协议，而不是 ADD 等测试的语义要求。
- 当前本地环境也使用退出 ECALL，并由 Trap handler 写 `tohost`，所以所有正式 UI 回归
  都会经过 A4 的精确异常路径。
- `scall`、`sbreak` 等 MI 测试会明确把 ECALL、EBREAK、`mcause/mepc` 当作被测对象。
- EBREAK 还可服务于调试器，但不是普通整数程序正常运行的前提。

因此本核确实超出了“只够跑 UI”的最小 RV32I/RV64I 数据通路，但完整特权平台仍需
PMP、S/U 模式、中断和委托，不能据此说已经超过上游通用环境。

## 复位和链接布局

`core_config_pkg` 把 `RESET_VECTOR` 定义为 0。IF reset 后令 `pc_q=0`，因此第一笔取指
访问地址 `0x0`。

本地 `link.ld` 同时规定：

```text
ENTRY(_start)
.text 从 0x0000_0000 开始
.data/.rodata/.bss 从下一个 0x1000 对齐地址开始
```

所以硬件复位 PC、软件入口和 IMem 镜像起点三者一致。测试数据被链接到数据地址空间，
由 DMem 加载。若只修改链接地址而不修改硬件地址映射，CPU 会在错误位置取指或访存。

## 从 ELF 到存储器镜像

GCC 参数的含义：

| 参数 | 作用 |
|---|---|
| `-march=rv32i_zicsr` / `rv64i_zicsr` | 禁止生成未实现的 M/A/C/F 等指令 |
| `-mabi=ilp32` / `lp64` | 选择 32/64 位调用约定和数据模型 |
| `-nostdlib -nostartfiles` | 不引入宿主库和通用 crt0 |
| `-mcmodel=medany` | 允许 PC-relative 地址构造 |
| `--no-relax` | 避免链接器改变预期指令序列 |
| `-T link.ld` | 使用本项目的地址布局 |

输出 ELF 同时包含指令、数据、符号和 section 信息。脚本使用 objcopy 分离：

- `.text` → `imem.vhex`；
- `.data` → `dmem.vhex`。

`verilog_hex_to_mem.py` 把按字节的 vhex 转成 `$readmemh` 使用的字宽格式。IMem 永远
按 4 字节指令组织；DMem 在 RV32 按 4 字节、RV64 按 8 字节组织。转换器还将未写区域
补零，并在镜像超过 4096 words 时直接报错。

## Testbench 如何启动 CPU

`tb_riscv_test` 从命令行读取：

```text
+IMEM=<imem.hex>
+DMEM=<dmem.hex>
+TOHOST=<ELF 中的 tohost 地址>
+TEST=<name>
+MAX_CYCLES=<limit>
```

它通过层次路径把两个 hex 文件加载到 `dut.u_imem.mem` 和 `dut.u_dmem.mem`，保持四个
上升沿 reset，再在下降沿释放 reset。runner 使用 `nm` 从每个 ELF 中解析 `tohost`
符号并传入 TB。`store_result_monitor` 只观察已经完成握手的 DMem Store，不参与总线响应。
TB 每个下降沿检查一次提交和锁存后的测试状态，避免与上升沿 nonblocking assignment
发生调度竞争。

若指定 `+TRACE`，TB 会打印每条退休指令的 PC、指令字、rd、写回数据和异常标志。
超过默认 200000 周期仍未写出结果则报告 TIMEOUT。

## 指令和数据怎样进入硬件

`sim_cpu_top` 将 Core 的两个 ready-valid 端口接到独立存储器：

- IF 通过 `imem_req_valid/ready` 发出 PC，再通过 `imem_rsp_valid/ready` 收到 32 位指令；
- MEM 通过 `dmem_req_*` 发出 Load/Store；Load 数据稍后经 `dmem_rsp_*` 到 WB；
- `dmem_req_wstrb` 指明 Store 修改哪些字节。

当前 `sim_imem/sim_dmem` 都是一拍响应模型。它们不是软件数组，也不是 GCC 的一部分，
而是 Verilator 编译后的硬件模型。ready-valid 等待会真实影响流水线 HOLD、load-use 和
提交时机。

## 普通指令测试如何判定

上游 `TEST_CASE` 大致展开为：

```asm
li   gp, test_number
执行被测指令
li   x7, expected_value
bne  result_register, x7, fail
```

`gp` 在此被本地环境定义为 `TESTNUM`。成功执行全部 case 后进入 `pass`；任何比较不等
立即进入 `fail`。测试宏还会插入不同数量的 NOP，覆盖没有旁路、相邻旁路和不同指令
距离，而不仅是检查一次算术结果。

## CSR、ECALL 和 EBREAK 如何交互

以 Trap 测试为例，软件与硬件依次完成：

```text
软件 reset_vector
  └─ la t0, trap_vector
  └─ csrw mtvec, t0
          │
          ▼
EX 执行 CSR 写操作，WB commit 后 csr_file.mtvec 生效
          │
软件执行 ECALL/EBREAK
          │
          ▼
D1 生成同步异常并停止年轻取指
          │
异常 metadata 随流水包前进
          │
          ▼
WB commit：trap_controller 确认最老异常
  ├─ mepc  = 异常指令 PC
  ├─ mcause= ECALL_M(11) 或 BREAKPOINT(3)
  ├─ mtval = 对应异常值
  ├─ 更新 mstatus
  └─ redirect PC = mtvec
          │
          ▼
软件 trap_vector → 测试自己的 mtvec_handler
  ├─ csrr 检查 mcause/mepc
  ├─ 通过：进入 pass，或修改 mepc 后 mret
  └─ 失败：进入 fail
```

关键点是精确提交：检测异常时不能立刻更新 CSR，因为更老的 Load 可能仍在等待；必须
等异常指令成为 WB 最老指令后，才能一次性写 Trap CSR 和重定向。这样错误路径上的
Store、CSR 写和寄存器写都不会泄漏。

MRET 自身不是异常。它只有在正常提交且 `exc.valid=0` 时恢复 `mstatus` 并重定向到
`mepc`；若 MRET 指令本身非法，则应走异常路径，不能同时返回。

## PASS/FAIL 如何离开 CPU

本地 PASS 宏与上游约定一致，先设置退出 ABI 再执行 ECALL：

```asm
li gp, 1
li a7, 93
li a0, 0
ecall
```

ECALL 在 WB 精确提交后跳转到 `mtvec`。公共 handler 只把 Machine ECALL 且
`a7 == 93` 解释为退出，然后把 `TESTNUM` Store 到链接符号 `tohost`。普通被测 ECALL
不会被吞掉，而是继续转交给测试自己的 `mtvec_handler`；这使 `scall` 仍能检查
`mcause/mepc`。

`sim_cpu_top` 不再译码测试地址，Store 与普通数据写一样由 `sim_dmem` 接收。TB 中的
被动 monitor 只观察请求握手：

- 数据低 32 位等于 1：`test_done=1, test_pass=1`；
- 其他编码：`test_done=1, test_pass=0`，其中奇数通常编码失败 case。

TB 观察到 `test_done` 后打印 PASS 或 `$fatal`。所以 PASS 不是 Verilator 猜测寄存器
状态，而是 RISC-V 软件比较结果后，依次完成 ECALL、Trap 和真实 Store 得出的结果。

## 经典 `tohost/fromhost` 是什么

`tohost` 和 `fromhost` 不是 RISC-V 指令或 CSR，而是测试环境与模拟器约定的共享内存
位置：

- `tohost`：目标 RISC-V 程序写，Spike/仿真器等 host 端读取；
- `fromhost`：host 写回，目标程序读取，用于返回请求结果；
- 最简单的 ISA 测试只需向 `tohost` 写 1 表示 PASS，写其他奇数编码失败 case；
- 更完整的 HTIF 会在一个 64 位值中编码 device、command 和 payload。

上游 `env/p` 在 `.tohost` section 中定义两个 8 字节符号。它的 PASS/FAIL 先执行
ECALL，公共 Trap handler 再把 `TESTNUM` Store 到 `tohost`；模拟器轮询该地址结束。

当前项目已经定义真实的 `tohost/fromhost` 链接符号，但只实现 ISA 测试所需的最小
退出语义，没有实现完整 HTIF 的 device/command 双向协议。当前路径是：

```text
RVTEST_PASS/FAIL
  → a7=93 + ECALL
  → trap_vector
  → Store TESTNUM 到 tohost
  → sim_dmem 接收写入
  → store_result_monitor 被动观察
  → tb_riscv_test 结束 Verilator
```

`tohost` 地址来自 ELF 符号表，而不是写死在 Core 或 `sim_cpu_top` 中。directed TB 仍可
直接写测试结果地址，避免普通数据通路测试依赖 CSR/Trap；正式 riscv-tests 则必须走
完整 A4 异常链路。

## 当前 MI 测试为什么通过

正式脚本当前选择 RV32 10 项、RV64 13 项，覆盖：

- 六种 Zicsr 操作和相邻 CSR 依赖；
- `misa/mhartid/mvendorid/marchid/mimpid` 等机器信息；
- ECALL、EBREAK、MRET 和非法指令；
- Load、Store 地址未对齐异常；
- `mcycle/minstret` 的适用行为。

它们使用的功能都落在 A4 边界内。PMP、U/S 模式、异步中断、Debug trigger 和 RV32
高半计数器测试尚未纳入。这些测试通过证明对应路径工作，不代表整个上游仓库都通过。

## RV32UI/RV64UI 当前正式边界

本地环境现已定义 `RVTEST_RV32U/RVTEST_RV64U`，runner 默认使用 vendor 快照并将
适用 UI 用例纳入正式回归：

| 测试族 | 直接通过 | 未通过 | 原因 |
|---|---:|---:|---|
| RV32UI | 40/42 | `fence_i`, `ma_data` | Zifencei/哈佛一致性；未对齐访问策略 |
| RV64UI | 52/54 | `fence_i`, `ma_data` | 同上 |

其余算术、逻辑、移位、分支、JAL/JALR、Load/Store、旁路和 RV64 W 指令全部通过。
加上 MI 测试后，正式结果为 RV32 `50/50`、RV64 `65/65`。runner 每次都会打印两个
排除项及原因，避免把 SKIP 误报成 PASS。

### `fence_i` 为什么失败

当前正式 `-march` 没有声明 `zifencei`，所以汇编器首先拒绝 `fence.i`。临时加入
Zifencei 后仍会运行失败，因为该测试用 Store 改写代码再执行它，而当前 Harvard
仿真中 DMem 写入不会修改 IMem。

可以选择：

- A4 只承诺 `I + Zicsr`，正式排除 Zifencei 测试；
- 未来实现可写代码存储路径，并让 FENCE.I 排空旧取指、清除 IF buffer/预测取指状态、
  使 I-Cache 或 IMem 看到此前的数据写入。

CoreMark 不包含自修改代码，不依赖 FENCE.I。

### `ma_data` 为什么失败

该测试要求未对齐 Load/Store 像普通访问一样完成。当前 Core 选择产生
Load/Store-address-misaligned Trap，因此进入本地 `unexpected_trap` 并失败。

这不等价于普通 LB/LH/LW/SB/SH/SW 实现错误。平台可选择：

- 保持硬件 Trap，由运行时软件拆成字节访问并推进 `mepc`；
- 在 LSU 内拆成两个对齐请求，再拼接 Load 或合并 Store；
- 明确当前执行环境不支持未对齐访问，将该测试列为不适用。

CoreMark 编译器会按 ABI 对齐对象和栈，不应依赖故意未对齐的整数访问。

## 达到目录中全部 UI 用例还缺什么

基础整数测试的环境宏、MI/UI 清单、双位宽汇总和构建产物已经工程化。若目标从
“适用的 RV32I/RV64I”提高到旧 UI 目录逐项 `42/42`、`54/54`，只剩两个平台决策：

- 实现 Zifencei、可写代码存储与 Harvard I/D 一致性，再启用 `fence_i`；
- 决定由 LSU 或 Trap handler 完成未对齐访问，再启用 `ma_data`。

其中 `RVTEST_RV32U/RVTEST_RV64U` 的 U 是上游 UI 测试族命名，当前测试仍运行在
M-mode，并不证明已经实现 U-mode。失败时应检查 ELF、反汇编、map、镜像和
`+TRACE`，不能修改上游快照或让 Core 识别测试魔数。

不要通过修改上游 `.S`、识别测试 PC 或识别测试魔数让 Core 通过。

## CoreMark 与这些能力的关系

上游 `riscv-tests/benchmarks/` 是该仓库自带的旧基准集合，例如 Dhrystone、median、
qsort 等，并不是 CoreMark v1.0。未来 CoreMark 应放在本项目的 `benchmark/coremark/`
（或软件栈成形后的 `software/apps/coremark/`），由本项目维护 port、BSP 和构建入口；
不应写进只读的上游样本或 vendor 快照。

| 能力 | CoreMark 是否需要 | 说明 |
|---|---|---|
| RV32I/RV64I 算术、分支、Load/Store | 必须 | C 编译代码的主体 |
| GPR 前递、load-use、存储器反压 | 必须正确 | 长程序会高频触发 |
| Zicsr | 当前 port 需要 | 使用 `mcycle/minstret` 计时 |
| ECALL/EBREAK | 不要求用于算法 | 可用于退出、调试和异常验证 |
| 精确 Trap/MRET | 建议保留 | 运行时和错误诊断基础 |
| FENCE.I | 不需要 | CoreMark 不修改代码 |
| 未对齐访问直接完成 | 不需要 | ABI 与编译器维持自然对齐 |
| M 扩展 | 非正确性前提 | 无 M 时需要软件乘除 helper，性能较低 |
| C 扩展 | 不需要 | 主要影响代码尺寸和取指效率 |

CoreMark 比 riscv-tests 多出的关键部分是 C 软件运行时：

- `crt0.S` 设置 `sp/gp`、清零 `.bss` 并调用 `main`；
- 新链接脚本安排代码、只读数据、全局数据、堆和栈；
- minimal libc 或至少内存、字符串和输出函数；
- CoreMark port 层提供计时、迭代次数、种子和输出；
- 软件乘除 helper 或匹配 RV32/RV64 ISA 的 libgcc；
- 更大的 IMem/DMem、`tohost`/输出接口和结果 CRC 检查。

riscv-tests 是“每条 ISA 语义是否正确”的短汇编检查；CoreMark 是“编译器、ABI、栈、
长时间流水、存储器和计时能否共同稳定工作”的 C 工作负载。二者互补，不能互相替代。

## 从仿真迁移到 Vivado 上板

当前上板仍以 Vivado 和 Zynq-7020 PL 为目标。软件侧希望尽量保持同一 ELF 与链接
模型，硬件后端替换如下：

| Verilator | Vivado/FPGA |
|---|---|
| `sim_imem/sim_dmem` | Instruction/Data BRAM 与协议 adapter |
| `$readmemh` | BRAM 初始化文件或下载器 |
| TB 对 `tohost` 的被动监视 | UART、状态 MMIO 或调试器的软件输出协议 |
| TB reset | Clock Wizard + reset synchronizer |
| `$display` commit trace | UART 日志、ILA 或 JTAG 观察 |

第一版上板不需要 ARM 核参与，但必须完成 BRAM 地址映射、时钟、复位、XDC 和一个可见
输出通道。`tohost` 是 Verilator 测试协议；上板软件应通过链接脚本或运行时改用真实
UART、状态寄存器或调试接口，不能依赖不存在的 testbench monitor。

## 推荐学习顺序

阅读当前流程时建议按以下路径：

```text
tb/riscv_tests/vendor/riscv-tests/isa/rv*/add.S / scall.S
  → tb/riscv_tests/vendor/riscv-tests/isa/macros/scalar/test_macros.h
  → tb/riscv_tests/env/riscv_test.h
  → tb/riscv_tests/env/link.ld
  → scripts/verilator/run_riscv_tests.sh
  → tb/riscv_tests/tb_riscv_test.sv
  → vsrc/sim_cpu/sim_cpu_top.sv
  → sim_imem / sim_dmem / store_result_monitor
  → decoder / d1_exception_check / csr_file / trap_controller
```

先跟踪普通 `add` 的 PASS 路径，再跟踪 `scall` 的 Trap 路径，最后打开 `+TRACE` 对照
反汇编。这样能把“汇编宏、指令编码、流水线提交和仿真判定”连接成同一条因果链。
