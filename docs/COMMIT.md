# 设计调整记录

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
