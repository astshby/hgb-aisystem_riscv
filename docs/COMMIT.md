# 设计调整记录

## 2026-09-27（Asia/Shanghai）— S0 访存完成、访问错误与排序契约

- Core 新增访问大小和 I/D 响应错误；Store 与 Load 都在 WB 接收一次完成响应。
  WB 输出补充总线异常后的提交包，错误访问不写寄存器，年轻 MEM 不产生副作用。
- IF 携带取指错误及 PC；D1 优先保留访问错误。FENCE/FENCE.I 在 D1 序列化，
  排空旧访存后从 WB 顺序 PC 恢复；FENCE.I 清除旧 BTB/PHT 与待训练项。
- 新增三个 SoC package（无函数）、地址译码和错误从设备；DDR 默认为关闭。
  TCM、外设及中断尚未接入，不能把 S0 说成完整 SoC。
- 新增地址/错误握手单元与统一内存整核测试，覆盖延迟写响应、三类访问错误、
  阻止年轻 Store、自修改代码及已训练的旧 BTB；同步旧 TB 的新接口与 Store ack。
- rhbyv 最终 RTL 回归：双位宽各 41 unit PASS、15 directed PASS / 1 SKIP；
  ISA RV32 58 PASS、RV64 78 PASS，各 SKIP fence_i、ma_data，FAIL 0；
  六后端矩阵分别 78/108 PASS，C smoke 为 3317/358 周期。
- CoreMark m0d0、BTB64，固定 RV32 32 迭代、RV64 28 迭代：
  performance 分别 11045355/10854767 ticks，2.897145/2.579512 CoreMark/MHz；
  performance/validation CRC 均正确，与 S0 修改前的同参数基线完全一致。
- hgb 同步后的 vsrc、tb、scripts、benchmark 与已测 rhbyv 快照逐目录比较一致；
  本轮未重复声称在 hgb 独立执行完整回归。未执行 FPGA 综合、时序或上板。
- 同步接口规范、硬件路线、目录和握手说明；README 功能简介更新暂被自动审核阻止，
  已请求维护者明确确认，尚未修改 README。

## 2026-09-27（Asia/Shanghai）— MDU 跨级实例与 MEM 内部拼包

- 以维护者修改并验证的 rhbyv 工作区为硬件同步来源；不在 package 中定义函数。
- `muldiv_unit` 移至 `core` 独立实例；`ex_mdu` 留在 EX 管理请求与 `issued_q`，
  `mem_mdu` 内化于 `mem_stage` 接收结果、拼包与前递，不增加结果寄存拍。
- EX/MEM 分别根据自己的流水包判断 M 指令，不跨级复用实时 `selected`。
- 保留 `issued_q`：WB 反压期间已接收的请求无需重复发射，随后 EX 可推进元数据。
- 保留维护者移除 `busy` 的接口调整；同步 TB 层级路径和独立 MDU 实例。
  MEM 单元测试增加结果未到、反压前递、响应握手与无效/异常包检查。
- 同步硬件路线、目录说明；hgb README 独立更新，软件路线与许可证不变。
- 前轮同架构回归：RV32/RV64 各 40 unit PASS、14 directed PASS / 1 SKIP；
  ISA 分别 58/78 PASS，各 2 SKIP（`fence_i`、`ma_data`），FAIL 0。
  六后端整核矩阵分别 78/108 PASS；C 冒烟和 CoreMark performance/validation
  两位宽 CRC 均通过。本次两仓库最终版本独立复跑 test 与 ISA，结果均与上述一致。
- 不包含 hgb 工作区中与同步无关的 `wb_stage.sv` 注释改动；该改动原样保留。
- 未执行 FPGA 综合、时序分析或上板；PR 由维护者审阅，不自行合并 main。

## 2026-09-25（Asia/Shanghai）— README 规约与 Cache/TCM/DMA/总线预案

- 两仓 `README.md` 均可在专用分支维护：rhbyv 保持简洁，不容纳理解文档、
  提交记录或当前阶段流水账；hgb README 随硬件事实更新，完整记录保存在此目录。
- 先以盘古 676-200K Pro 为板级目标，Zynq-7020 后适配；保留既有 Vivado Tcl，
  不假定盘古 DDR IP 为 AXI，也不把 Zynq PS DDR 视作无需 PS 初始化的纯 PL 资源。
- [设计草案](understand/THINKING.md) 区分 CPU I/D 接口、TCM、Cache、DMA 主/从端、
  内部互连和外部 AXI4 桥；写响应、DMA/Cache 一致性与 FENCE.I 是明确待审门槛。
- 本次只修改文档和 rhbyv 的 `.gitignore` 白名单，没有改 RTL、TB 或构建脚本；
  因此没有重新声称本次执行了仿真或板级验证。

### 上一轮两次提交：逐文件目的

以下是已完成的大轮次，而非本次架构预案新增 RTL。rhbyv 的提交依次为
`98373fe`、`42f6ee9`；hgb 的对应提交为 `f60fa61`、`d31ebbe`。

`98373fe`：修复 WB 慢 Load 时 MEM 已就绪前递被错误关闭、MDU 抓取旧操作数的问题；
没有前移 load-use 或改变六级边界。

| 文件 | 修改目的 |
|---|---|
| `scripts/verilator/run_mdu_backends.sh` | 将新增 M 前递整核用例纳入六后端矩阵。 |
| `tb/core/tb_core_m_forward.sv` | 新增慢 Load、MEM/WB 同名写入与 M 操作数回归。 |
| `tb/unit/tb_mdu_issue_control.sv` | 覆盖 MEM 优先于 WB 和未就绪生产者的发射许可。 |
| `tb/unit/tb_mem_stage.sv` | 验证 WB 反压时 MEM 已算好结果仍可前递。 |
| `tb/unit/tb_wb_stage.sv` | 验证 Load 响应等待与正常/异常提交条件。 |
| `vsrc/core/control/hazard_unit.sv` | 删去 D1 已转成异常后的重复 illegal 门控。 |
| `vsrc/core/core.sv` | 接入 MEM 前递的 MDU 就绪判断，精简预测更新推进门控。 |
| `vsrc/core/csr/csr_access_check.sv` | 去除被地址位只读规则覆盖的冗余 CSR 比较。 |
| `vsrc/core/execute/M_extension/ex_mdu.sv` | 澄清仅在依赖的前递结果未就绪时阻止请求。 |
| `vsrc/core/execute/M_extension/mdu_issue_control.sv` | 按最近的 MEM→WB 生产者判断两个 M 源操作数。 |
| `vsrc/core/execute/ex_exception_check.sv` | 复用统一的 EX 控制流判定函数。 |
| `vsrc/core/execute/ex_stage.sv` | 统一分支分类和有效门控，简化预测更新/重定向判断。 |
| `vsrc/core/frontend/if_stage.sv` | 合并重定向/flush 取消条件及顺序 PC 计算。 |
| `vsrc/core/lsu/mem_stage.sv` | 分离“结果可前递”与“包可推进”，删冗余请求判定。 |
| `vsrc/core/writeback/trap_controller.sv` | 复用无异常 retire 条件确定 MRET。 |
| `vsrc/core/writeback/wb_stage.sv` | 合并 Load 等待、正常提交与异常提交条件。 |
| `vsrc/pkg/core_types_pkg.sv` | 增加 EX 控制流分类辅助函数。 |

`42f6ee9`：EX 接受 M 请求时先将元数据寄存至 EX/MEM，MEM 等结果后拼包；
WB 反压时结果仍由 MDU 保持，不添加额外结果寄存拍。

| 文件 | 修改目的 |
|---|---|
| `scripts/rtl_files.f` | 将新增 `mem_mdu` 纳入可综合源码清单。 |
| `scripts/verilator/run_mdu_backends.sh` | 把边界用例纳入六后端整机矩阵。 |
| `tb/core/tb_core_m_boundary.sv` | 新增 EX/MEM 拼包、反压、前递边界整核测试。 |
| `tb/core/tb_core_m_trap.sv` | 适配 M 请求与提交分离后的 Trap 时序检查。 |
| `tb/unit/tb_ex_stage.sv` | 检查 EX 请求接受、元数据推进及 M 结果输出。 |
| `tb/unit/tb_mem_mdu.sv` | 新增 MEM 拼包/等待/响应握手单元测试。 |
| `tb/unit/tb_pipeline_ctrl.sv` | 验证 MEM 结果等待对年轻 EX 控制事件的优先级。 |
| `vsrc/core/control/pipeline_ctrl.sv` | 将 MEM 请求等待与 M 结果等待统一按年龄仲裁。 |
| `vsrc/core/core.sv` | 接入 `mem_mdu`、MDU 结果通路和 `mem_result_stall`。 |
| `vsrc/core/execute/M_extension/ex_mdu.sv` | 用 `issued_q` 记录已接受但尚未离开 EX 的请求。 |
| `vsrc/core/execute/M_extension/mem_mdu.sv` | 新增 EX/MEM 元数据与寄存 M 结果的无额外拍拼包。 |
| `vsrc/core/execute/ex_stage.sv` | 只推进 M 元数据，结果改由 MEM 拼入。 |

hgb 在上述两次提交还各自更新了 `docs/COMMIT.md`、
`docs/HARDWARE_ROADMAP.md`、`docs/PROJECT_STRUCTURE.md` 和
`docs/understand/M_EXTENSION.md`：同步修改记录、当前硬件边界、文件职责与
M 扩展时序解读；这些发布文档不反向放进 rhbyv。

## 2026-09-25（Asia/Shanghai）— MDU 结果与 EX/MEM 元数据汇合基线

`ex_mdu` 在请求接收后允许元数据进入 EX/MEM，并用 `issued_q` 处理较老指令反压期间
已启动但尚未交付的请求。新增 `mem_mdu`，在 EX/MEM 寄存器输出侧拼接 MDU 寄存结果；
`pipeline_ctrl` 对未完成的 MEM 结果维持年龄优先。更新文件表、模块/整核 TB 和
六后端矩阵，保留同步异常、取消和 ready/valid 的既有提交顺序。

验证：两种 XLEN 各 40 unit PASS、14 directed PASS、1 非适用位宽 SKIP；
riscv-tests 为 RV32 58 PASS、RV64 78 PASS，各 2 SKIP（`fence_i`、`ma_data`）。
六种 MDU 后端矩阵为 RV32 78 PASS、RV64 108 PASS；EX 适配器在两种 XLEN 下各
6 种后端 PASS。C 冒烟、CoreMark 校准、performance、validation 均通过。
固定基线相同迭代数，默认 m0d0、BTB 64：RV32 32 次/11045355 ticks，
`2.897145 CoreMark/MHz`；RV64 28 次/10854767 ticks，
`2.579512 CoreMark/MHz`。未进行 FPGA 综合或板级验证。


## 2026-09-24（Asia/Shanghai）— fix_M 前递修复与组合条件精简

范围：第一阶段基线，保留六级流水与现有 EX 等待 MDU 的寄存边界；不前移 Load-use。

- 修复慢 Load 停在 WB 时，MEM 已完成结果因无法推进而被关闭前递，导致 EX MDU 锁存旧操作数的问题。
- MEM 的 GPR/CSR 前递有效性与向 WB 推进许可分离；MDU 操作数就绪遵循 MEM 优先于 WB，支持较新同名写入覆盖。
- D1 负责将非法指令转换为异常；清理后级重复 illegal 检查，合并 WB 完成条件、EX 分支分类、IF 当前路径取消条件及 CSR 冗余只读比较。
- 保留模块说明、中文功能块与协议注释；没有改变 Load-use 位置、乘除法算法或请求/响应状态机。
- 新增 `tb_core_m_forward` 七场景；扩展 MEM、MDU 发射和 WB 真值测试，后端矩阵纳入新定向测试。
- 涉及 `vsrc/core/{control,execute,frontend,lsu,writeback,csr}`、`core.sv`、类型包、上述 TB 与后端矩阵脚本。

验证：两种 XLEN 各 39 项 unit PASS，14 项 directed 中 13 PASS、1 非适用位宽 SKIP；
三种 top 的 lint 均通过。riscv-tests 为 RV32 58 PASS、RV64 78 PASS，各 2 SKIP
（`fence_i`、`ma_data`）。C 冒烟各 1 PASS，CoreMark 校准、performance、validation 均通过。
默认 `MUL_IMPL=0 DIV_IMPL=0 BTB_ENTRIES=64`：RV32 32 次迭代/11346027 ticks，
`2.820371 CoreMark/MHz`；RV64 28 次迭代/11117855 ticks，`2.518471 CoreMark/MHz`。
六种 MDU 后端矩阵为 RV32 72 PASS、RV64 102 PASS，均无 FAIL/SKIP。
未运行 FPGA 综合或上板。


## 2026-09-02（Asia/Shanghai）— SYSTEM uOp 分类

状态：A0 学习分支上的适应性设计调整，尚未替代后续阶段实现。

### 评估结论

`ECALL`、`EBREAK` 和 `MRET` 使用相同的 `SYSTEM` major opcode，但不是普通
Zicsr read-modify-write 指令。三个 `is_*` 控制位允许无效组合，改用互斥的
`sys_op_e` 更适合作为译码结果：

```systemverilog
typedef enum logic [1:0] {
    SYS_NONE, SYS_ECALL, SYS_EBREAK, SYS_MRET
} sys_op_e;
```

`ECALL/EBREAK` 产生同步异常，trap commit 才更新 `mepc/mcause/mtval/mstatus`；
`MRET` 是特权返回指令，在 commit 恢复 `mstatus` 并重定向到 `mepc`。它们均不
应设置 `csr_valid/csr_write`，也不使用 `csr_cmd_e`。

### 本次调整

- 将 `uop_t.is_ecall/is_ebreak/is_mret` 合并为 `uop_t.sys_op`。
- 增加 ECALL、EBREAK、MRET 的完整 32-bit 编码。
- 增加 `tb_core_types`，检查零值 uOp、SYSTEM 分类互斥性和指令编码。

### 后续适配

A1 及以后阶段的 decoder、异常检测和串行化条件需要分别改为比较
`SYS_ECALL`、`SYS_EBREAK`、`SYS_MRET`。未来实现 S-mode/WFI 时再扩宽枚举并
增加 `SYS_SRET`、`SYS_WFI`，不提前把未实现指令声明为可执行功能。

## 2026-09-03（Asia/Shanghai）— 特权架构定义分层

状态：A0 审核后的适应性设计调整，于 2026-09-04 纳入本地提交。

### 评估结论

- `uop_t` 保存译码后的静态执行意图；`exception_t` 是各流水级可更新的动态状态，两者继续分离。
- `FU_LSU` 表示 Load/Store Unit，与 U-type 指令无关；LUI/AUIPC 复用 ALU。
- 指令编码与特权架构定义分层，避免 `pipeline_pkg` 持有 RISC-V 原因编号。

### 本次调整

- 将 `riscv_isa_pkg` 拆分为非特权的 `riscv_unpriv_pkg` 和特权架构的 `riscv_priv_pkg`。
- `ECALL/EBREAK` 归入非特权指令编码，`MRET`、机器级 CSR 与 trap cause 归入特权架构定义。
- 新增 `riscv_priv_pkg`，收纳特权指令、CSR 地址、trap cause 及机器中断字段。
- 增加 `mie/mip`、`MIE/MPIE`、`MSIE/MTIE/MEIE` 和对应 pending bit 的架构常量。
- Core 参数 assertion 在综合时通过 `` `SYNTHESIS `` 关闭，在 Verilator 仿真/lint 时保留。
- 新增 `tb_riscv_unpriv` 和 `tb_riscv_priv`，对 RV32/RV64 下的非特权/特权编码常量做模块级检查。

### 范围边界

本次只建立架构常量，不表示 A0 已实现异步中断。`mtime/mtimecmp`
属于平台级内存映射设备，后续由 interrupt/trap arbitration 消费 `MTIP`。

## 2026-09-04（Asia/Shanghai）— A0 审核完成

- RV32/RV64 的 core、simulation top 与 synthesizable top 均通过 Verilator lint。
- RV32/RV64 的 `tb_core_config`、`tb_core_types`、`tb_riscv_unpriv`、`tb_riscv_priv` 均通过。
- 本提交作为 A0 已审核基线，后续合并到 `stage/a1-rv32i-six-stage`。

## 2026-09-04（Asia/Shanghai）— A0 合并到 A1

### 合并处理

- 保留 A1 的 IF–D1–D2–EX–MEM–WB 数据通路，不回退为 A0 空框架。
- 同步 A0 审核后的 `sys_op_e`、特权/非特权 package 分层和异常类型归属。
- Decoder 与立即数生成器改为导入 `riscv_unpriv_pkg`。
- 保留已审核的中文学习注释，并保留 A1 的参数断言综合保护。

### 验证

- `make lint XLEN=32` 和 `make lint XLEN=64` 通过。
- `make unit XLEN=32` 和 `make unit XLEN=64` 的全部模块测试通过。
- `make directed XLEN=32` 通过，`tb_core_rv32i` 用 33 个周期完成。
- A1 的 directed test 明确限定 `XLEN=32`；RV64 整核指令行为由 A2 验收。

## 2026-09-10（Asia/Shanghai）— A1 审核改革固化

### 关键修改

- 将流水级控制统一为 `pipeline_actions_t`，按级表达推进、保持和清空，消除旧的分散 `hold/flush/bubble` 组合。
- 重构 IF 请求、响应与单项缓冲；重定向可以杀死在途错误路径响应，并保留后压下的有效指令。
- 将 load 请求发射与返回解耦：MEM 只负责请求，WB 等待响应并在返回后提交，流水线仅在真实内存等待时停顿。
- 按功能拆分核心模块中的组合逻辑和时序逻辑，保留并补充关键中文注释。
- 统一测试时序、具名指令编码和 PASS 判定，新增 IF、MEM、WB、流水线控制、存储握手、cache wait 与 load 流水验证。
- 新增仓库内 `AGENTS.md` 和 `MEMORY_HANDSHAKE.md`，固化代码分块、注释保护和回归规则。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 17 项全部通过。
- `make directed XLEN=32` 通过：cache wait 11 周期、load pipeline 18 周期、RV32I 32 周期。
- A1 仍是 RV32I 阶段，RV64 整核测试在 A2 功能合入后执行。

## 2026-09-10（Asia/Shanghai）— A1/A2 合入 A3

### 合并原则

- 以已审核 A1 的注释、功能分块、IF/MEM ready-valid 握手和 `pipeline_actions_t` 为基线，人工移植 A2/A3 功能。
- 保留 `riscv_unpriv_pkg` 与 `riscv_priv_pkg` 分层，不恢复旧 `riscv_isa_pkg`。
- A3 已包含 A2 历史，因此只将 A1 固化提交合入 A3，避免重复合并 A2。

### 关键修改

- 加入 RV64I 的 LD、SD、LWU、XLEN 位移和 W 类算术/移位，W 类结果统一符号扩展。
- 为 RV64 编码补充带上下文的 funct3/funct6 常量及 `enc_ld`、`enc_addiw`、`enc_addw` 等具名测试编码。
- 接入直接映射 BTB、非推测 GShare 和预测更新仲裁；只有流水级真正推进时才训练预测器。
- JAL/JALR 只更新 BTB，不进入 GHR；条件分支使用取指时保存的 PHT 索引训练。
- BTB miss 输出确定的空目标/类型，避免无效表项数据传播；同索引不同标签按直接映射规则替换。
- 预测器 RTL 按查表、训练计算和时序写入分块，并保留、补充必要中文注释。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 21 项全部通过。
- 两种位宽的 cache wait 均为 11 周期，load pipeline 均为 18 周期。
- 两种位宽的预测整核测试均执行 21 次分支、产生 7 次重定向。
- RV32I 整核测试 32 周期通过；RV64I 整核测试 28 周期通过，非适用位宽均明确报告 SKIP。

## 2026-09-12（Asia/Shanghai）— A3 审核版本检查点

### 固化范围

- 以用户审核和调整后的 A3 工作区为后续 A4 合并基线，不回退模块顺序、功能分块或中文注释。
- 保留 Core、Decoder、ALU、BTB、GShare、IF、Predictor、预测更新仲裁、Store 及 package 中的审核修改。
- 仅清理 6 处行尾空格，不改变 RTL 行为；未跟踪的 `README.md` 与 `riscv-tests/` 不纳入提交。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 21 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 全部通过；cache wait、load pipeline、预测器和两种位宽整核行为均保持原结果。

## 2026-09-12（Asia/Shanghai）— A3 基线合入 A4 验证分支

### 合并原则

- 以用户审核后的 A3 检查点 `11078d5` 为数据通路和注释基线，人工适配正确 A4 的 Zicsr、同步异常和 riscv-tests 功能。
- 保留 A3 的 IF request/response/buffer/kill、MEM 发请求/WB 收 Load 响应以及 `pipeline_actions_t`，没有回退到旧 A4 的 MEM 等响应设计。
- 冲突模块继续按照功能拆分组合与时序块，并保留、迁移或适应性修正已有中文注释。

### 关键修改

- 完成六种 Zicsr 指令、CSR 寄存器/立即数操作、相邻 CSR 旁路和 WARL 合法化；合法值同时用于 EX 旁路与 WB 提交。
- 实现 ECALL、EBREAK、MRET、非法指令、指令/Load/Store 地址未对齐的精确同步异常，以及 `mstatus/mtvec/mscratch/mepc/mcause/mtval/mcycle/minstret`。
- Trap、CSR 写入和退休计数统一由 WB 的真实 `commit_valid` 门控，Load 等待响应时不会提前或重复产生架构副作用。
- 将 D1/EX 序列化纳入 `PIPE_ADVANCE/HOLD/CLEAR`；IF flush 可以杀死在途年轻响应但不提前修改 PC，最终由 WB Trap/MRET 重定向。
- 预测更新仲裁在清除错误路径 pending 的同时保留引发 EX 重定向的老分支训练，A3 预测测试继续保持 21 次分支、7 次重定向。
- 不恢复旧 `riscv_isa_pkg`；非特权编码继续放在 `riscv_unpriv_pkg`，机器 CSR、MRET 和异常原因放在 `riscv_priv_pkg`。
- 测试编码增加 `enc_csrrw/enc_csrrs/enc_csrrc` 及立即数、ECALL、EBREAK、MRET 具名函数；所有 A4 TB 声明时间精度并使用确定性时钟沿采样。
- 新增 `tb_core_trap_wait`，验证延迟 Load 响应、单次请求、年轻 ECALL 顺序、错误路径清除和 handler 的 MCAUSE。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过，覆盖 core、sim_cpu_top 和 cpu_top。
- `make unit XLEN=32`、`make unit XLEN=64` 各 26 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项通过（另一位宽整核 ISA 用例明确 SKIP）。
- `make riscv-tests XLEN=32` 通过 `10/10`；`make riscv-tests XLEN=64` 通过 `13/13`。

## 2026-09-13（Asia/Shanghai）— A4 控制与异常路径模块化

### 关键修改

- 新增 `d1_exception_check` 与 `ex_exception_check`，分别承接译码后已知异常，以及前级异常继承、CSR 非法访问、访存地址和实际控制流目标检查。
- 新增 `csr_bypass`，独立处理 `EX/MEM > MEM/WB > csr_file` 的 CSR RAW 旁路优先级；CSR 提交许可仍由 WB 完整性控制。
- 新增 `serialize_controller`，保存异常/MRET 从发现到 WB 重定向期间的 pending 状态，并控制前端清空和取指请求许可。
- `pipeline_ctrl` 只在序列化事件赢得最老事件仲裁后输出 `serialize_start`，避免被更老重定向杀死的年轻请求错误锁住前端。
- 新增 `gpr_forward_t` 与 `csr_forward_t`，统一表达前递来源的有效位、地址和值；GPR/CSR 旁路均收进 EX 阶段。
- 两类前递结构归入 `pipeline_pkg`，并将仅处理 GPR 的 `operand_bypass` 更名为与 `csr_bypass` 对称的 `gpr_bypass`。
- CSR 的 WARL 合法化只在 EX 执行一次；WB 输出已完成指令的 CSR 提交通道，`csr_file` 只保存合法提交值和处理 Trap/MRET 状态变换。
- `fetch_ready` 与 `mem_issue_enable` 统一由 `pipeline_ctrl` 输出；MEM 许可只依赖更老的 WB 状态，避免经 MEM 前递、EX 重定向形成组合环。
- `trap_controller` 移入 `writeback/`，体现其根据 WB 提交包产生 Trap/MRET 架构副作用和重定向的职责。
- `fetch_enable` 改为语义明确的 `fetch_request_enable`；功能块注释保留说明并移除数字编号。
- 新增五个模块 TB，并扩充 MEM、WB、CSR file 与 `pipeline_ctrl` 对结构体通道、提交条件和控制许可的检查。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 31 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项全部通过。
- `make riscv-tests XLEN=32` 通过 `10/10`；`make riscv-tests XLEN=64` 通过 `13/13`。

## 2026-09-13（Asia/Shanghai）— 项目文档与目录规则整理

### 关键修改

- 将阶段修改记录和存储器握手说明移动到 `docs/`，根目录只保留项目入口文件。
- 重写根 `README.md`，删除旧五级、Nexys A7 和 Cocotb 工作流描述。
- 新增项目目录、硬件路线、软件目标占位及仿真/上板说明。
- 审核嵌套 `riscv-tests` 的实际 dirty 状态，记录适配层边界；该目录不转换、不暂存，并在最终规则中作为只读 clone 忽略。
- `.gitignore` 改为根目录白名单，默认排除 build、logs、Vivado workspace 等生成物。
- 扩充根 `AGENTS.md`，固化注释、审阅、测试、文档同步、分支和 PR 规则。

### 验证

- 本次只修改文档和版本库组织，不改变 RTL 行为。
- `.gitignore` 白名单检查通过，新增 Markdown 没有行尾空白。
- 当前 RTL 最近回归保持：RV32/RV64 lint 通过，各 31 项 unit 通过，directed 通过，riscv-tests 为 RV32 `10/10`、RV64 `13/13`。

### 范围边界

A4 只实现机器模式同步异常。`mie/mip` 及软件、定时器、外部中断的编码已保留在
`riscv_priv_pkg`，但寄存器状态和中断仲裁留待后续阶段，不在本次为通过测试而伪实现。

## 2026-09-13（Asia/Shanghai）— 固定 riscv-tests 并接入 ECALL/tohost

### 关键修改

- 保留并适配用户新增的软件栈目标，当前 FPGA 上板目标继续使用 Vivado 与 Zynq-7020 PL。
- 新增 `docs/understand/SOFTWARE_TEST_STACK_GUIDE.md`，串联上游汇编、环境宏、链接、镜像、Verilator、存储器、流水线、Trap 与 `tohost` 判定。
- 将根目录 `riscv-tests/` 定位为父仓库忽略的只读样本；父仓库不修改或依赖该 clone。
- 将正式回归所需的 MI/UI `.S`、测试宏、`encoding.h` 和许可证固定到 `tb/riscv_tests/vendor/`，记录上游 riscv-tests `933a897` 与 env `6de71ed`。
- 本地环境补充 UI 测试族入口宏；runner 默认使用 vendor 快照，并分别维护 MI/UI 清单。
- PASS/FAIL 改为 `a7=93 + ECALL`，由 M-mode Trap handler 将 `TESTNUM` 写入 ELF 的 `tohost` 符号；普通被测 ECALL 仍交给测试自己的 handler。
- 删除会接管 DMem 地址的 `sim_test_device`；`sim_cpu_top` 只被动导出已握手 Store，TB 的 `store_result_monitor` 负责解释结果。
- directed TB 使用同一被动监视器但不依赖退出 ECALL，保持基础数据通路与 A4 Trap 故障可分离诊断。
- 新建 `docs/understand/` 存放协议和实现链路解读，并将存储器握手说明一并纳入。
- 更新 README、目录说明、仿真说明与 Agent 规则，统一上述边界。

### 验证结果

- `bash -n` 检查三个 Verilator runner 通过。
- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 31 项通过，其中包含新的被动 Store monitor 测试。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项通过。
- `make riscv-tests XLEN=32` 正式通过 `50/50`（MI 10 + UI 40）。
- `make riscv-tests XLEN=64` 正式通过 `65/65`（MI 13 + UI 52）。
- 两种位宽均显式跳过 `fence_i` 和 `ma_data`：前者需要 Zifencei 与可写指令存储一致性，后者要求未对齐访存直接完成。
- 本次没有修改可综合 Core，也没有修改根目录上游样本 clone。

## 2026-09-13（Asia/Shanghai）— A5 CoreMark 与周期性能闭环

### 关键修改

- 固定官方 EEMBC CoreMark `v1.01`（报告版本 1.0）源码和许可证，记录 commit
  `cfa9ab377835911f23d9b0831c7be302ed1f58de`；被测 `core_*.c` 与 `coremark.h`
  保持上游原样，平台适配独立放在 `benchmark/coremark/port/`。
- 新增裸机 BSP：`crt0.S` 设置 `gp/sp/mtvec`、清零 `.bss` 并经 ECALL/`tohost`
  退出；链接脚本、字符 Store、`memcpy/memset` 和软件乘除共同支持无 M 扩展的 C 程序。
- `mcycle/minstret` 改为固定 64 位状态；RV32 新增 `mcycleh/minstreth` CSR 与原子高低高
  读取，RV64 仍从低地址访问完整计数器。CSR 访问检查和两种位宽单元测试同步更新。
- 新增 C 冒烟，覆盖 `.data/.bss`、栈、函数调用、32/64 位软件乘除、Store 与计数器；
  新增通用 benchmark TB，并仅为长程序把仿真 IMem/DMem 参数化扩至 128 KiB。
- 新增镜像构建、仿真构建和 CoreMark runner。runner 先校准迭代周期，再以 performance
  与 validation seeds 各运行不少于 10 个归一化秒，并检查官方 CRC 成功文本。
- CoreMark 长程序发现一处控制缺陷：较老 JALR 重定向清除了错误路径异常，却未清除
  已登记的序列化 pending，导致永久停取指。`serialize_controller` 现由最终选中的任意
  较老重定向完成或取消 pending；新增短叶子返回后紧跟非法填充的定向回归。
- 新增 `docs/understand/COREMARK_AND_PERFORMANCE.md`，区分 CoreMark/MHz、实际
  CoreMark/s、Fmax 和 CoreMark/LUT，并同步 README、目录、软硬件路线和仿真说明。

### 验证结果

- RV32/RV64 的 core、`sim_cpu_top`、`cpu_top` lint 均通过；新增计数器逻辑无宽度警告。
- `make unit XLEN=32/64` 各 31 项全部通过。
- `make directed XLEN=32/64` 各执行 9 项：8 项 PASS，另一位宽 ISA 用例明确 SKIP；
  新的 JALR/序列化取消用例两种位宽均为 18 周期。
- `make riscv-tests XLEN=32` 通过 `50/50`（MI 10 + UI 40）；RV64 通过 `65/65`
  （MI 13 + UI 52）。两种位宽仍只跳过 `fence_i` 与 `ma_data`。
- C smoke 通过：RV32 3945 周期，RV64 2494 周期。
- CoreMark performance/validation 均报告 `Correct operation validated`。RV32 performance
  为 11 次迭代、11,148,066 ticks、`0.986718 CoreMark/MHz`；RV64 为 10 次迭代、
  12,004,387 ticks、`0.833029 CoreMark/MHz`。
- vendor 文件逐字节匹配上游 `v1.01`，四个新增 runner 通过 `bash -n`，`git diff --check`
  通过。Vivado、真实 Fmax、utilization 与上板 CoreMark 未执行，留待 A6。

## 2026-09-13（Asia/Shanghai）— 拆分序列化完成与取消通道

### 关键修改

- 将 `serialize_controller.serialize_complete` 恢复为单一含义：只表示 WB Trap/MRET
  完成自身序列化；新增 `serialize_cancel`，明确表示 D1/EX 较老控制流重定向杀死了
  错误路径上的年轻序列化事件。
- Core 分别连接 `wb_redirect.valid` 与“最终选中且非 WB”的重定向，不再用一个名为
  complete 的端口混合两种原因；控制器内部仍让释放事件优先于同拍开始事件。
- 扩充控制器单元测试，分别验证正常完成、错误路径取消和同时开始/取消的优先级。
- 新增 Taken Branch 后紧跟非法顺序路径的整核测试，与既有 JALR 用例共同覆盖两类
  EX 重定向取消场景。

### 验证结果

- `make unit XLEN=32/64` 各 31 项全部通过。
- `make directed XLEN=32/64` 各执行 10 项：9 项 PASS，另一位宽 ISA 用例明确 SKIP；
  Branch 取消用例两种位宽均为 12 周期，JALR 取消用例仍为 18 周期。
- RV32/RV64 的 core、`sim_cpu_top`、`cpu_top` lint 均通过。
- `make riscv-tests XLEN=32` 保持 `50/50`，RV64 保持 `65/65`；既定的 `fence_i` 与
  `ma_data` 仍明确 SKIP。
- C smoke 保持 RV32 3945 周期、RV64 2494 周期。
- CoreMark performance/validation CRC 均通过，周期和成绩不变：RV32
  `0.986718 CoreMark/MHz`，RV64 `0.833029 CoreMark/MHz`。

## 2026-09-16（Asia/Shanghai）— 阶段 B 启动与设计评估

- 按用户要求暂缓 A6，从 A5 `main` 创建并切换到 `stage/b-rv32-rv64-m`。
- 同步当前开发目标；用户已确认 B 保留六级主流水，先完成 RV32M/RV64M 与
  CoreMark，再恢复 A6 上板，之后依据实测时序考虑加深流水。
- 补充 MDU 请求/响应、操作数锁存、结果反压和按指令年龄取消的设计边界；
  仿真与综合共享可综合 RTL，算法和具体延迟仍待评审，尚未实现硬件 M。
- 补充未来机器模式中断、访存错误和 MMIO 不可重复副作用的目标，不扩展本次 RTL 范围。
- 本次只创建分支和修改目标文档，未修改 RTL、未运行回归、未提交或推送。

## 2026-09-16（Asia/Shanghai）— B 阶段基础 RV32M/RV64M

### 实现与时序边界

- 在 `stage/b-rv32-rv64-m` 保留已审阅的六级主流水与有用注释，新增
  `execute/mul_unit.sv`、`div_unit.sv`、`muldiv_unit.sv`，不依赖厂商 primitive/IP。
- `core_types_pkg` 新增 `muldiv_op_e/muldiv_req_t` 和 uOp M 控制；非特权编码与
  Decoder 启用全部 8 项 XLEN M 指令及 RV64 的 5 项 W 指令，`misa.M` 固定报告为 1。
- 乘法以 16×16 无符号小块乘积、分组求和和最终结果三组寄存器实现，高半积按
  MULH/MULHSU/MULHU 作补码修正；除法采用 radix-2 恢复算法，普通操作迭代有效
  位宽次，W 只迭代 32 次。除零/最小负数除以 -1 返回 ISA 规定值，不产生 Trap。
- 请求在 E0 握手时锁存实际前递操作数：乘法 E2 后响应有效，普通除法 E(L+1) 后
  有效，特殊除法 E0 后有效；交付还需响应握手。Verilator 与综合使用同一数据路径。
- EX 保存单条在途状态，接收请求后撤销 valid，保持完成结果直至 EX/MEM 接收；
  `pipeline_ctrl` 增加 EX 等待与独立发射许可，较老 MEM/WB 无反压时继续排空。
  取消来自会杀死当前指令的较老 WB 重定向，不接受年轻 D1 异常取消。
- Core 在 D2/EX HOLD 时保存 WB 已提交的 GPR 新值，避免较老 WB 排空、旁路消失
  后读到过期操作数；流水包注释同步说明 HOLD 保持指令身份而允许该操作数刷新。

### 测试与文档

- 新增乘法、除法、统一 MDU 和 EX 四个 unit TB，以及全部 M 指令、延迟访存与
  精确 Trap/MRET 三个 directed TB。共享检查器采用独立宽算术参考、固定种子和
  显式求值顺序，覆盖符号、W、输入变化、固定延迟、反压、取消、复位和后端交替。
- 同步 Package/Decoder/CSR/流水控制单元测试及 RTL 清单；从既有 pinned Git
  对象复制 21 个 UM `.S` 与 2 个 Makefrag，逐字节保持上游，补充 vendor 清单。
  根目录 `riscv-tests/` 仅只读访问，不恢复其已有工作树差异，不修改或提交该 clone。
- 全部仿真显式启用 `--assert`。当前 Verilator 会在部分循环内 `$finish` 后落入
  超时 `$fatal`，且可能返回 0：12 个旧 directed/ISA/benchmark harness 改为先跳出
  采样循环，未完成才报超时，最后统一结束；不改变程序或硬件预期。
- unit/directed/ISA/benchmark runner 拒绝含 `%Fatal/%Error/Assertion failed` 的
  日志，不能仅靠进程返回码或 PASS 文本判定成功。
- benchmark 默认改用 `rv32im_zicsr/rv64im_zicsr`，port 编译信息同步；保留
  RV32 宽整数 ABI helper，官方 CoreMark 源码未改动。
- 新增 `docs/understand/M_EXTENSION.md` 与 `docs/PLATFORM_ADAPTATION.md`；同步
  README、项目目录、仿真说明、硬件/软件路线与性能解读。平台目标同时覆盖
  Zynq-7020 与紫光同创盘古 676-200K Pro；厂商工程、BRAM/时钟/IO 与约束在平台层隔离。

### 最终验证结果

- `make test XLEN=32/64` 均通过：每种位宽 3 个顶层 lint、35 unit PASS；13 项
  directed 中各 12 PASS、1 非适用位宽 SKIP。新 M 整核程序为 RV32 33 条退休/
  242 周期、RV64 50 条退休/595 周期；M wait 为 121/185 周期，M trap 为 119/183 周期。
- 最后对固定种子检查器的求值顺序整理后，重新运行两种位宽全部 35 项 unit，均 PASS。
  mul/div/统一 MDU 分别为 RV32 516/516/1060 项检查，RV64 644/1028/1700 项检查。
- `make riscv-tests XLEN=32`：`58/58` PASS（MI 10 + UI 40 + UM 8），FAIL 0；
  `XLEN=64`：`78/78` PASS（MI 13 + UI 52 + UM 13），FAIL 0。每种位宽显式
  SKIP 2 项 UI：`fence_i`、`ma_data`；其他超出当前平台的测试族未纳入。
- `make benchmark-smoke XLEN=32/64` 各 1 PASS：3334/371 周期。
- `make coremark XLEN=32/64` 各完成校准与 performance/validation；四次正式运行
  CRC 均 PASS，计时区间均超过 10M 周期。RV32 performance 为 28 次迭代/
  11,067,231 ticks、`2.529991 CoreMark/MHz`；validation 为 11,094,314 ticks。
  RV64 performance 为 26 次迭代/11,406,036 ticks、`2.279495 CoreMark/MHz`；
  validation 为 11,456,652 ticks。
- `SYNTHESIS` 宏下 RV32/RV64 Core lint 均通过；这不是 FPGA 综合。当前没有新的
  WIDTH/LATCH/UNOPTFLAT/MULTIDRIVEN 警告，既有未使用信号/参数等告警仍保留。
- 负向诊断确认故意失败的断言和 1 周期 ISA 超时均非零退出；正向最终日志无致命
  错误。23 个新增 vendor 文件逐字节匹配 pinned commit；全部 runner `bash -n`
  与 `git diff --check` 通过。
- 未执行 Vivado、盘古厂商工具、DSP 映射、实现时序或上板，不能将仿真分数当作
  FPGA Fmax/板级成绩。本次留在开发分支工作树，未提交、合并或推送。

## 2026-09-18（Asia/Shanghai）— M 扩展可选算法与统一握手

### 范围与接口

- 按本次授权在 `stage/b-rv32-rv64-m` 继续完善，沿用用户已整理的
  `execute/M_extension/`，保留有用注释与功能分块。未恢复或提交本轮开始已有的
  无关工作树改动；未修改上游 riscv-tests、CoreMark vendor 或厂商工程。
- 保留 `core_types_pkg::muldiv_req_t`：它描述跨周期请求快照；组合 ALU/branch
  继续使用显式端口。新增 `ex_mdu`，集中请求拼接和 EX 发射/等待适配，移除
  `ex_stage` 中的 MDU pending 寄存器及直接握手组合块。
- `muldiv_unit` 唯一拥有 IDLE/RUN/RESULT、ready/valid、busy 和最终结果保持。
  `mul_unit/div_unit` 改为共用 ISA 语义层，算法使用 start/done；下层不再复制
  外部反压状态机。取消/复位清除全部计算有效状态，优先于接收和交付。

### 算法与时序

- 乘法保留先算 U×U、再按 MULH/MULHSU 修正高半积的方式。新增 `mul_dsp`
  （16×16 `*` 部分积）、`mul_booth_wallace`（Radix-4 编码与真实 3:2 压缩树）、
  `mul_shift`（逐位移位加法）；`wallace_tree` 负责压缩到两行。
  原来的位权分组加法保留在 DSP 后端，明确它不是 Wallace 树。
- 除法先处理除零/最小负数除以 -1，再 abs、无符号幅值运算、符号恢复和 W
  扩展。新增 `div_shift` 与 `div_srt4`，数据路径均不使用 `/` 或 `%`。
  SRT 包含有符号部分余数、完整精度 QDS、Q/Q-1 在线转换及末余数修正；
  `div_srt4_qds/div_srt4_otf` 独立成模块。采用固定二进制缩放和较宽通路，
  尚未优化归一化、截断 QDS 或 carry-save 余数，也未推断 FPGA 性能优劣。
- `MUL_IMPL=0/1/2` 选择 DSP/Booth-Wallace/移位；`DIV_IMPL=0/1` 选择移位/SRT。
  默认 0/0，Make 和所有 Verilator runner 同步参数，编译时只实例化选中后端。
  厂商 IP 留待未来评估，平台目标仍为 Zynq-7020 与盘古 676-200K Pro。
- 请求 E0 握手后，DSP/Booth 乘法 E3、移位乘法 E(XLEN+1)、移位除法 E(L+1)、
  SRT E(L/2+3)、特殊除法 E1 后 rsp_valid 有效，L 为有效除法位宽；实际交付
  还需下一个 ready 上升沿。统一结果寄存器使默认乘法/特殊除法各多一拍。
  六级主流水和原有按指令年龄处理等待/取消的规则不变。

### 验证与测试适配

- `make test XLEN=32/64` 均通过：每种位宽 3 顶层 lint、38 unit PASS、
  directed 12 PASS / 1 非适用位宽 SKIP。
- `tb_muldiv_backends` 六种组合各完成 RV32 1576、RV64 2536 项独立算术及
  协议检查，覆盖全部适用指令、随机大小除数、W、精确延迟、快照、反压、
  乘法/除法各自的运行中与结果待交付时取消/复位，以及交替后端。
- `tb_mdu_unsigned` 穷举 65536 对 8 位输入：乘法 196608 次、非零除法
  130560 次比较，五种 SRT 商位与末余数正负两条路径均覆盖。
  `tb_div_srt4_components` 另完成 QDS 130815 次、在线转换 5120 次检查。
- 标准 riscv-tests：RV32 58 PASS（MI 10 + UI 40 + UM 8），RV64 78 PASS
  （MI 13 + UI 52 + UM 13），各 FAIL 0；各 SKIP `fence_i`、`ma_data` 两项。
- 新增 `make mdu-backends` 与 runner：先生成正式 ISA 镜像，再对六种组合各跑
  三个 M 整核 TB 和全部 UM。最终 RV32 66/66、RV64 96/96 PASS。
  矩阵初次在移位乘法下发现旧 TB 固定九拍 Load 无法覆盖“MDU 结果等待 WB”，
  因而将该配置 Load 延迟延长为 XLEN+9；没有删除覆盖断言或改变 RTL。
  修改后完整重跑两个位宽的六组合整核/UM 矩阵，全部通过。
- C smoke 两种位宽均 PASS，3335/372 周期。默认 CoreMark performance/validation
  四次 CRC 均通过：RV32 28 迭代、performance 11,330,319 ticks、validation
  11,357,402 ticks、2.471246 CoreMark/MHz；RV64 25 迭代、performance
  11,202,057 ticks、validation 11,250,847 ticks、2.231733 CoreMark/MHz。
  分数变化来自真实延迟，旧分数作为历史结果保留。非默认算法未做正式 CoreMark 跑分。
- 两种位宽 × 六种配置的 `SYNTHESIS` 宏 Core lint 通过；未执行实际 FPGA
  综合/实现/上板。修改过的 runner `bash -n` 与 `git diff --check` 通过。
- 同步 README、硬件路线、目录、仿真/上板、平台适配、M 扩展解读与性能说明。
  本次未提交、合并或推送，供后续逐模块审核。

## 2026-09-22（Asia/Shanghai）— B 阶段 MDU 完善与双仓库发布分工

### RTL 与接口

- `mul_dsp` 化简为单个完整 `*`，不再手工构造 16 位部分积；Booth 编码、Wallace
  3:2 压缩树和最终进位传播加法继续保持独立模块边界。
- `muldiv_unit` 在后端 `done` 当拍直接给出响应，仅在 EX/MEM 反压时进入 RESULT
  保留结果，消除统一包装器原有的额外完成周期。除零和有符号溢出仍在请求沿保存
  ISA 规定结果，不启动真正除法器。
- Radix-4 SRT 改为归一化除数、显式 PD 表、截断 carry-save QDS、3:2 余数压缩、
  Q/Q-1 在线转换和最终余数修正；RV64 W 形式只迭代 32 位有效宽度。
- 新增依赖感知的 `mdu_issue_control`。接口命名为 `mdu_operands_ready`，只阻止依赖
  尚未返回 WB Load 的 MDU；无依赖运算可以与存储器等待重叠，写入 x0 不构成依赖。
- `pipeline_ctrl` 显式输出 `d1_flush`：WB/EX 重定向和 EX 序列化清除年轻 D1 更新，
  D1 自身重定向/序列化不会误杀自己的训练；predictor arbiter 同步清除 pending D1，
  同时保留引发 EX 重定向的老分支训练。
- M 扩展按 `mul/booth-wallace`、`div/srt4` 重新组织，源码清单按子模块先于顶层排列。

### 验证

- `make test XLEN=32/64` 均通过：每种位宽 39 unit PASS；13 项 directed 中
  12 PASS、1 个非适用位宽用例 SKIP。SRT 组件完成 QDS 134870、CSA 4096、
  OTF 5120 项检查；8 位无符号后端穷举 65536 对输入全部通过。
- 六种乘除后端整机矩阵全部通过：RV32 66 项、RV64 96 项。标准 riscv-tests
  保持 RV32 58/58、RV64 78/78，各自明确跳过 `fence_i` 与 `ma_data`。
- benchmark smoke 为 RV32 3318 周期、RV64 365 周期。CoreMark performance 与
  validation CRC 全部正确；默认 0/0 得分为 RV32 `2.821267 CoreMark/MHz`、RV64
  `2.490061 CoreMark/MHz`。SRT 配置得分相同，说明该负载不足以区分除法器。
- `git diff --check` 通过；未执行 Vivado、盘古综合、实现、时序分析或上板。

### 仓库职责

- `rhbyv-cpu-forlinux` 保留硬件 RTL、测试、工具脚本和硬件工作流文档，不再包含
  `docs/COMMIT.md`、`docs/understand/` 或软件路线图，也不把这些内容并入 README。
- `hgb-aisystem_riscv` 成为协作发布和未来软件栈仓库，接收硬件快照、修改记录与
  理解文档。rhbyv 的重大提交先在 hgb 创建对应分支并通过 PR 审阅；hgb 的软件侧
  修改默认不反向同步到个人硬件仓库。
