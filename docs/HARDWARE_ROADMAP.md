# 硬件目标与阶段规划

## 总体目标

项目目标是构建一个使用 SystemVerilog 强类型 RTL 的单发射、顺序执行 RISC-V
Core。当前基线为六级流水，RV32/RV64 在构建时选择：

```text
IF → D1 → D2 → EX → MEM → WB
```

架构应能沿着 `RV32I/RV64I + Zicsr → M → C → F 或更深流水` 演进。Core 与
具体 FPGA BRAM、UART 和板级 IO 解耦，Verilator 与 FPGA wrapper 共享同一套
ready-valid 存储器协议。

平台目标先覆盖紫光同创盘古 676-200K Pro，再适配 Zynq-7020；Core 和 MDU 不依赖
厂商原语。时钟、BRAM、IO、约束和工程差异在平台层隔离，详见
[平台适配](PLATFORM_ADAPTATION.md)。两块板目前都尚未完成集成与上板验证。

## 当前六级架构（A5 基线 + B 阶段 M）

- IF 查询一套 BTB + 非推测 GShare，并随指令保存预测 metadata。
- D1 完成译码、立即数、非法/SYSTEM 分类、早期异常和 JAL 解析。
- D2 读取双端口 GPR，并准备执行操作数。
- EX 统一处理 GPR/CSR 前递、ALU、分支、JALR、CSR 读改写和动态异常；
  MDU 请求被接收后将指令元数据送入 EX/MEM。
- MEM 发射一次 Load/Store 请求，或将寄存的 MDU 结果与元数据汇合；
  请求未 ready 或运算结果未就绪时保持流水。
- WB 接收 Load/Store 完成响应，作为 GPR/CSR、计数器和 Trap 的架构提交点。
- 同步异常在发现时清除年轻指令，携带 metadata 到 WB 后精确提交。
- JAL 只训练 BTB；JALR 训练 BTB；条件分支训练 BTB、PHT 和 GHR。

当前 RTL 支持 RV32IM/RV64IM、六种 Zicsr、ECALL、EBREAK、MRET、机器模式同步异常、
`mstatus/misa/mtvec/mscratch/mepc/mcause/mtval/mcycle/minstret`；RV32 还可通过
`mcycleh/minstreth` 配合高低高重读获取完整 64 位计数。FENCE/FENCE.I 已实现
序列化、旧访存排空与顺序 PC 恢复；FENCE.I 另清除旧预测并丢弃旧取指响应。
统一地址存储的定向测试已覆盖自修改代码，完整 SoC/TCM 接入留待下一步。

## SystemVerilog 规则

- 使用 `logic`，不用混杂的 `wire/reg` 风格。
- 组合逻辑使用 `always_comb`、blocking `=`，并先给默认值以避免 latch。
- 时序逻辑使用 `always_ff`、nonblocking `<=`；同一寄存器只由一个时序块驱动。
- 使用 `package/import`、`localparam`、`typedef enum logic` 和显式类型转换。
- 流水边界、重定向和前递使用 `typedef struct packed`，避免大量散乱控制线。
- `_t` 表示类型，`_e` 表示枚举，`_q` 表示寄存器当前状态，`_d` 表示下一状态。
- 空流水槽使用 `valid=0`；所有存储器、GPR、CSR 和预测更新副作用都受 valid/commit 门控。
- XLEN 数据使用 `xlen_t`，禁止硬编码 32 位零扩展或固定四字节写掩码。
- 可综合 RTL 不放 `timescale`；TB 使用 `timeunit 1ns/timeprecision 1ps`。
- reset 优先清除 valid、FSM 和必要架构状态，不依赖无效 packet 的 payload 值。

## 模块职责约束

| 模块 | 稳定职责 |
|---|---|
| `if_stage` | PC、取指握手、响应缓冲、预测 next PC、redirect/kill |
| `predictor` | BTB/GShare 查询与训练，不决定架构正确性 |
| `d1_stage` | 译码组织、JAL 控制和 D1 异常序列化请求 |
| `d1_exception_check` | 指令地址、非法指令、ECALL/EBREAK、JAL 目标检查 |
| `d2_stage` | GPR 读取结果与 uOp 打包 |
| `gpr_bypass`/`csr_bypass` | `MEM > WB > committed/original` 数据选择 |
| `ex_stage` | ALU/BRU/CSR 执行、分支验证和 EX 输出打包 |
| `mul_unit` | 选择 DSP/Booth-Wallace/移位后端，并完成 signed 高半积修正和 W 扩展 |
| `div_unit` | 处理 ISA 边界、符号与 W 语义，选择移位恢复或 Radix-4 SRT 后端 |
| `muldiv_unit` | Core 中跨 EX/MEM 的单条在途运算、握手、反压与取消 |
| `ex_mdu` | EX 请求打包与已发射、尚未送入 MEM 的元数据记录，不实例化运算单元 |
| `mem_mdu` | mem_stage 内部拼包寄存的运算结果，等待结果并控制响应接收 |
| `ex_exception_check` | 继承异常、CSR 权限、访存与控制目标对齐检查 |
| `mem_stage` | 内部汇合 M 结果、请求侧访存握手和 MEM 前递，不等待 Load 返回 |
| `wb_stage` | 响应侧握手、写回数据和真实 commit 许可 |
| `trap_controller` | 由最老 commit 产生 Trap/MRET 状态与重定向 |
| `hazard_unit` | 判断数据尚不可用的 load-use 依赖 |
| `pipeline_ctrl` | 按指令年龄仲裁 HOLD/CLEAR/ADVANCE 和 redirect |
| `serialize_controller` | 异常/MRET 排空时停止取指，并区分 WB 完成与较老控制流取消 |
| `core` | 模块连接和级间寄存器，不吸收功能单元实现 |

## 阶段 A

| 阶段 | 内容 | 当前状态 |
|---|---|---|
| A0 | 目录、Package、双 XLEN 构建和空顶层 | 已完成 |
| A1 | 六级 RV32I、前递、冒险、JAL/Branch/JALR | 已完成 |
| A2 | RV64I、W 操作、LD/SD/LWU、64 位总线 | 已完成 |
| A3 | BTB、GShare、预测 metadata 和更新仲裁 | 已完成 |
| A4 | 完整 Zicsr、M-mode 同步异常、MRET、riscv-tests | 已完成并回归 |
| A5 | CoreMark v1.0 仿真、BSP、计时和长程序验证 | 已完成并回归 |
| A6 | 盘古优先的 TCM/总线/外设与上板闭环，再适配 Zynq-7020 | 规划中；两板未上板 |

### A5：CoreMark 仿真

- 固定官方 EEMBC `v1.01` 源码；被测 `core_*.c` 与 `coremark.h` 不作修改。
- 建立 `crt0.S`、链接脚本、栈、`.bss` 清零、ECALL/`tohost` 退出和仿真字符输出。
- 使用 `rv32i_zicsr/ilp32` 与 `rv64i_zicsr/lp64`；乘除由只含基础整数操作的软件
  ABI helper 实现，不伪装硬件 M 扩展。
- `mcycle` 固定为 64 位；RV32 通过 `mcycleh/mcycle/mcycleh` 三次读取避免回绕撕裂。
- 仿真存储器按 benchmark 顶层扩至 128 KiB，普通测试仍保留原默认容量。
- 先运行 C 冒烟，再分别运行 performance 与 validation seeds；脚本自动校准迭代数，
  使计时区间不少于 10 个按 1 MHz 归一化的秒，并检查官方 CRC 文本。
- A5 无 M 基线成绩为 RV32 `0.986718 CoreMark/MHz`、RV64 `0.833029 CoreMark/MHz`。这是
  同步仿真存储器下的周期效率；真实 Fmax、CoreMark/s 和 CoreMark/LUT 留待 A6 上板。

CoreMark 长程序暴露并修复了序列化取消缺陷：较老 JALR/分支重定向现在能取消错误
路径上已登记的异常/MRET 序列化，不会永久关闭取指。加入 M、C、Cache 或修改存储
时序后必须重新测量，不能沿用当前分数。

### A6：双 FPGA 平台

- 先冻结可复用的 IMem/DMem、TCM、MMIO、DMA 与系统互连契约和地址映射。
- 盘古先完成 BRAM/TCM、时钟复位、UART/Timer 等基础 MMIO、工程和约束。
- 在无 Cache 的总线闭环后，先验证 DMA 与 TCM/外存仲裁。
- 再验证阻塞式 I$/D$ 与 DMA 缓存一致性维护。
- 验证 ISA smoke、CoreMark 和 TCM/Cache 两种软件布局，记录资源及实现时序。
- 之后适配 Zynq-7020；保留现有 Vivado Tcl 流程，不直接复用盘古 IP/约束。
- 两板共享 Core、MDU 和软件测试契约；PS DDR 是否使用另行审定。
- 具体分层、通信和验证门槛见 [Cache/TCM/DMA 设计草案](understand/THINKING.md)。

## 阶段 B：基础 M 扩展与验证

2026-09-16：从已验证的 A5 `main` 基线创建 `stage/b-rv32-rv64-m`，进入 RV32M/RV64M
设计评估。已确认 B 阶段保留 `IF → D1 → D2 → EX → MEM → WB` 六级主流水；
先完成 M 与双位宽 CoreMark，再恢复 A6 上板，之后根据实测关键路径评估加深流水。
MDU 内部允许多周期运算或寄存器分段，不等于增加主流水级。

实现 RV32M/RV64M，包括 MUL/MULH/MULHSU/MULHU、DIV/DIVU、REM/REMU 和 RV64
W 形式。正式启用 `FU_MULDIV`，为 MDU 建立请求/响应 ready-valid 与取消协议；
由 `pipeline_ctrl` 处理 EX 等待，较老 MEM/WB 在自身无反压时继续推进。请求握手时
锁存前递后的操作数，完成结果保持至下游接收，不重复发射；取消仅来自会杀死当前
指令的较老事件。Verilator 与 FPGA 使用相同可综合运算与时序 RTL，不用仿真专属
单周期实现，也不以计数等待代替真实数据路径分段。

2026-09-18：M 模块收拢到 `execute/M_extension/`，`ex_mdu` 负责打包与流水适配，
`muldiv_unit` 唯一管理 ready/valid、在途和结果保持；语义层与算法使用 start/done。
无符号乘法可选 DSP 推断乘法、Radix-4 Booth-Wallace、普通移位乘法；除法可选
radix-2 恢复算法、带截断 QDS、carry-save 余数、在线转换和末余数修正的 Radix-4 SRT。
乘法共用 U×U 后高半积修正；除法先处理 ISA 边界，再 abs、无符号计算和符号恢复。
当时默认分块乘法 + 恢复除法；请求 E0 握手后，乘法 E3、普通除法 E(L+1)、
特殊除法 E1 后响应有效（L=XLEN 或 32）。其余后端与交付反压的准确时序见
[M 扩展实现解读](understand/M_EXTENSION.md)。DSP/IP 映射与算法优劣留待实测。

厂商 primitive/IP 不是必需项，
若后续引入，必须隔离后端并验证同一接口的延迟、反压、复位与取消行为。必须验证
除零、带符号溢出、全部适用 M riscv-tests、A 阶段回归、CoreMark 变化，以及 A6 的
两种 FPGA 的 DSP/LUT/时序。RISC-V M 除零与有符号溢出返回规定结果，不产生算术 Trap。

2026-09-18 历史基线：两种 XLEN 各 38 项 unit PASS，13 项 directed 中各 12 PASS、
1 非适用位宽 SKIP；riscv-tests 为 RV32 `58/58`、RV64 `78/78`，其中 UM 为 8/13。
CoreMark performance/validation CRC 均通过，默认配置成绩为 RV32 `2.471246`、RV64
`2.231733 CoreMark/MHz`；真实 FPGA 映射与时序仍待 A6。

2026-09-24 修复基线：MEM 前递与推进许可分离，MDU 按 MEM→WB 选择实际依赖；
清理后级重复非法指令判断与等价组合条件，不改变 EX/MEM 寄存边界。
回归更新为每种 XLEN 39 unit PASS、13 directed PASS 和 1 非适用位宽 SKIP；
ISA 覆盖不变。默认 m0d0、BTB 64 的 CoreMark/MHz 为 RV32 `2.820371`、RV64 `2.518471`。
EX/MEM 结果与元数据汇合另作为后续基线验证。

2026-09-25 EX/MEM 新基线：MDU 请求接受沿，EX/MEM 即保存 M 指令元数据；MEM 在
结果就绪后拼包并进入 WB。`pipeline_ctrl` 让 MEM 的结果等待优先于年轻 EX 控制事件；
WB 反压时，MDU 结果由唯一握手状态机保持，Load-use 的位置不变。
两种 XLEN 各 40 unit PASS、14 directed PASS 和 1 非适用位宽 SKIP；ISA 仍为
RV32 58/58、RV64 78/78，各明确跳过 `fence_i` 与 `ma_data`。六种 MDU 配置矩阵
为 RV32 78 PASS、RV64 108 PASS；EX 适配器各六种后端额外检查通过。
默认 m0d0、BTB 64，固定同一迭代数对比：RV32 32 次迭代/11045355 ticks，
`2.897145 CoreMark/MHz`；RV64 28 次迭代/10854767 ticks，
`2.579512 CoreMark/MHz`。这是仿真周期效率，FPGA 时序与板级频率仍待测量。

## 无 Cache SoC：S0 → S2

- S0：读写完成响应、访问大小与错误、FENCE/FENCE.I 和物理地址表；见
  [SoC 访存契约](SOC_BUS_CONTRACT.md)。
- S1：Boot ROM、I/D-TCM、路由和统一存储器 CoreMark 仿真。
- S2：两 UART、机器/通用 Timer 各一、三 GPIO、机器中断与外设验证。
- S3：DDR 桥与 DMA；S4：盘古 IP/约束和上板。各步骤独立交接。

## 阶段 C：C 扩展

Frontend 增加 16/32 位长度检测、半字对齐缓冲、跨 word 拼接和 decompressor，
随后向 D1 提供 canonical 32 位指令。packet 保留 `seq_pc` 并增加压缩指令长度信息；
BTB/PHT 索引纳入 PC[1]，IALIGN 从 32 改为 16。必须分别处理 RV32C/RV64C 编码，
完成 C 测试、压缩 CoreMark 和 FPGA 回归。

## 后续扩展

- F：增加浮点寄存器、FPU、浮点 load/store、转换和 `fflags/frm/fcsr`。
- 深流水：可拆为 IF1/IF2、EX1/EX2 或 MEM1/MEM2；继续让预测与异常 metadata 随指令传播。
  在 M、CoreMark 与上板闭环后再实施，按指令年龄扩展前递、反压和清除范围，不改变提交语义。
- TCM/总线/DMA：先建立 CPU/DMA 可访问的片上确定性存储区、MMIO 地址译码和外存桥接。
- Cache：在现有 ready-valid 边界外实现 I/D Cache；miss 反压，不侵入 Core ISA 逻辑。
- 操作系统硬件基础：机器定时器、`mie/mip`、软件/外部中断和 UART。Linux 还需要
  S/U 特权级、SBI、原子扩展、MMU/TLB、页表 CSR 与平台中断控制器。
- 机器模式 Trap 与 MMIO 平台：保留精确提交边界，扩展异步中断仲裁和存储器响应错误
  metadata；为不可取消的访存定义完成边界，禁止错误路径 MMIO 副作用或重复握手。
  外设、地址译码与总线适配留在平台侧，不绑定 EX 级数；具体实现另行评审。

## 阶段验收

任何扩展都必须同时满足：新模块测试通过、RV32/RV64 旧回归不退化、适用的
riscv-tests 通过、CoreMark 通过，并在涉及 FPGA 后提供综合、实现和时序报告。
预测状态只允许影响性能，不得影响 ISA 正确性；architectural side effect 必须在
明确 commit 点发生。
