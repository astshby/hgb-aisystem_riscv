# 六级流水中的 M 扩展

## 学习入口与指令

当前主流水仍是 `IF → D1 → D2 → EX → MEM → WB`。MDU 内部寄存器不构成新的
主流水级；它一次只处理一条指令，尚不支持每拍发射或乘除融合。

RV32/RV64 均支持 MUL/MULH/MULHSU/MULHU、DIV/DIVU、REM/REMU；RV64 另有
MULW/DIVW/DIVUW/REMW/REMUW。高半积 W 编码和全部 RV32 OP-32 编码保持非法。
W 指令只计算低 32 位，结果一律符号扩展，包括 DIVUW/REMUW。`misa.M` 固定为 1。

建议先看 `core_types_pkg::muldiv_op_e/muldiv_req_t` 和 Decoder，再沿下图阅读。
这些 M 模块均位于 `vsrc/core/execute/M_extension/`，`ex_stage.sv` 留在执行级目录。

```text
ex_stage
└── ex_mdu                  请求拼接、发射许可、EX 等待适配，无自有状态
    └── muldiv_unit          唯一 ready/valid 状态机与结果保持寄存器
        ├── mul_unit        W 输入、MULH/MULHSU 符号修正、结果选择
        │   ├── mul_dsp             编译时三选一
        │   ├── mul_booth_wallace → wallace_tree
        │   └── mul_shift
        └── div_unit        ISA 边界、abs、无符号幅值、商余数符号修正
            ├── div_shift           编译时二选一
            └── div_srt4 → normalize + PD table + QDS + CSA + OTF
```

`muldiv_req_t` 的 operation、op_width、operand_a、operand_b 共同描述一次运算。
它是多周期边界的原子请求；PC、rd、预测和异常 metadata 留在 D2/EX。
ALU/branch 当前是组合单元，显式端口已经清楚，无须为形式一致增加请求结构体。
EX 中剩余的 ALU/CSR 操作数选择、分支判断和输出包组装仍按功能分块保留。

## 唯一握手所有者

`ex_mdu` 只在有效、无异常的 FU_MULDIV 指令且 `mdu_operands_ready` 为 1 时请求运算。
实际前递操作数在 `req_valid && req_ready` 的上升沿锁存。MDU 离开 IDLE 后
busy 为 1，适配器随即撤销 req_valid；不再另存一份 EX pending 状态。

操作数就绪与前递使用相同的最近生产者顺序：先 MEM，再 WB。MEM 已有 ALU/CSR
结果时，即使较老 Load 在 WB 等待，也仍然可以前递；“结果已经可用”不等于
“流水包现在能推进”。MEM 的同名新写入覆盖 WB 的旧写入；只有实际选中的
生产者尚未提供结果才阻止 MDU 启动。x0 和未使用的源不产生依赖。

`tb_core_m_forward` 覆盖慢 Load、MEM 写入、EX 乘除法三者重叠的七种场景，
同时检查两路操作数、覆盖关系、真实 WB 依赖、Load 写 x0 和不重复启动/退休。

| MDU 状态 | req_ready | rsp_valid | 含义 |
|---|---|---|---|
| IDLE | 1 | 0 | 可以接收一个请求 |
| RUN | 0 | `done` | 计算中；后端完成当拍直接给出响应 |
| RESULT | 0 | 1 | 特殊除法或被反压的结果等待 EX/MEM 接收 |

复位或 cancel 时两个握手输出都为 0。RUN 收到 done 后直接尝试交付；若 EX/MEM
当拍不能接收，才把结果锁存并进入 RESULT。特殊除法在请求沿保存规定结果并进入
RESULT。RESULT 在 `rsp_valid && rsp_ready` 时回到 IDLE。不支持同拍交付旧结果并
接收新请求；这与当前阻塞式 EX 一致。

下层使用 `start/done`：start 是请求握手派生的一拍启动脉冲，done 是计算完成的一拍
通知，数据与 done 同时有效。下层没有 ready，也不处理交付背压；计数器或有效位只
记录计算进度。完成当拍未被接收的结果由 `muldiv_unit` 保留。

结果未产生时 `execution_stall=1`：保留前端至 EX；较老 MEM/WB 在无自身反压时
推进，同时清空已排空的 EX/MEM，避免重复提交。结果产生后撤销 execution_stall，
但 rsp_ready 仍由 EX 的真实 advance 决定，较老访存等待不会提前消费结果。

年轻异常不能取消较老 MDU；当前 cancel 来自 WB Trap/MRET 重定向。取消优先于接收、
计算完成和响应交付，并清除各算法的进度/有效位，不能返回旧结果。
EX HOLD 时 Core 仍将较老 WB 已提交值保存到包内操作数，避免前递消失；已经启动的
运算只观察自身快照，不受后来旁路线或输入请求变化影响。

## DSP 推断与 Booth-Wallace 边界

`mul_dsp` 只表达一次完整的无符号 `operand_a * operand_b`，并在请求沿寄存结果；
不再手工拆分 16 位部分积。综合器负责按目标器件的 DSP 原生位宽完成拆分、级联或
逻辑映射，最终必须以综合报告为准。

Booth-Wallace 后端保持独立结构：`mul_booth_wallace` 负责 Radix-4 编码、流水有效位
和最终进位传播加法，`wallace_tree` 只负责参数化的 3:2 carry-save 压缩。递归
`generate` 在 elaboration 阶段根据部分积行数生成固定硬件拓扑，并不是运行时循环。

乘法统一执行：取有效输入位串 → 无符号完整乘积 U → 根据指令修正高半积 → 选择结果。
设原操作数无符号解释为 A、B，高半积为 H，则：

```text
signed_high = H - (A 按有符号解释且为负 ? B : 0)
                - (B 按有符号解释且为负 ? A : 0)    // XLEN 位取模
```

MULH 修正两项，MULHSU 只修正 A 对应项，MULHU 不修正；MUL 只取低半积。
MULW 只使用低 32 位乘积并符号扩展。Booth 内部的负部分积属于编码算法，
不代替上述 RISC-V 有符号高半积处理。

## 三种无符号乘法后端

| MUL_IMPL | 模块 | 数据路径 |
|---|---|---|
| 0（默认） | mul_dsp | 单个完整 `*`，请求沿寄存全积，由综合器推断 DSP |
| 1 | mul_booth_wallace | Radix-4 Booth 部分积寄存 → Wallace 两行寄存 → 最终进位加法寄存 |
| 2 | mul_shift | 每拍查看乘数最低位、条件加被乘数，再移位；迭代 XLEN 次 |

`mul_dsp` 使用可推断 DSP 的写法；名称不保证最终映射，一定要查看对应厂商综合报告。
Zynq 与盘古共享这份 RTL，不硬编码厂商 DSP 位宽或 primitive。

Booth 将重叠三位编码为 0、+A、+2A、−A、−2A，每组权重相差两位。
无符号 B 的顶端补 0 并保留额外一组，避免把最高位误解为负数。
`wallace_tree` 每层把三行变成异或 sum 与左移一位的多数表决 carry，再递归缩减到
两行；层内不做宽进位传播，最后才进行一次宽加法。算法数据路径不使用乘法运算符。

普通移位乘法也是完整硬件算法，没有用固定等待掩盖组合乘法。当前 MULW 仍迭代
XLEN 次，只有输入低 32 位有效；以后可单独评估早停或窄乘法优化。

## 除法语义与两种无符号后端

`div_unit` 先解释 XLEN/W 的有效输入，再检查两个 ISA 边界：

- 除数为 0：商全 1，余数等于被除数。
- 有符号最小负数除以 −1：商等于最小负数，余数为 0。

特殊值不启动算法，也不产生 Trap。普通值再取 abs，并以无符号位串传入算法。
最小负数的幅值可由无符号 XLEN/32 位表示，不依赖有符号 abs 溢出行为。
这些是组合数据依赖的先后，不表示给每个步骤额外增加一个时钟周期。

后端同时返回无符号商、余数；语义层根据指令选择其一，商符号为两输入符号异或，
余数符号跟随被除数，实现向零截断。最后统一处理 W 结果符号扩展。

`DIV_IMPL=0`（默认）的 `div_shift` 为 radix-2 恢复除法，每拍移入被除数一位、
试减并生成一位商；L=XLEN，W 时 L=32。没有数据除法 `/` 或取模 `%` 运算符。

`DIV_IMPL=1` 的 `div_srt4` 为归一化 Radix-4 SRT，每拍生成一个 −2 到 +2 的冗余
商位。部分余数始终保存为 carry-save 两行，QDS 只观察两行相加后的高位截断值和
归一化除数前缀；迭代主体不放置全宽进位传播加法器。较少迭代仍不等于已经获得
更高 FPGA Fmax，必须查看综合时序。

## SRT：部分余数、QDS、在线转换和最后修正

对非零无符号除数 D，先统计前导零并把 D 归一化到最高位为 1；被除数同步左移，
保持商不变。RV64 W 形式再把 32 位有效输入左对齐，但只产生 32 位商。内部按固定
二进制位置缩放 D 和初始部分余数，每拍选择 q、以 3:2 CSA 计算 `P-qD`，非末轮
把 sum/carry 两行同时左移两位。迭代 `L/2+1` 拍。

QDS 对 carry-save 两行最高 11 位做短进位加法，保留两个 guard bit，再用除数最高
4 位索引 PD 表。表给出约 D/2 与 3D/2 的重叠选择边界，得到
`q∈{-2,-1,0,1,2}`。低位截断误差由选择重叠区容纳；组件 TB 穷举归一化 8 位
除数和允许部分余数范围，逐项检查选后收敛界。

在线转换同时保留 Q 和 QM=Q−1。例如 q=−1 时，`Q'=4QM+3`；
q=0 时，`Q'=4Q`、`QM'=4QM+3`。全部通过两位拼接实现，不用在每拍末尾
把正负商位累加器做一次宽减法；`div_srt4_otf` 的五种映射均有独立验证。

末轮才执行一次完整 carry-propagate addition。若余数为负，则商选择 QM、余数加
归一化 D；否则选择 Q。余数随后按内部缩放量和归一化位数右移，得到
`N=DQ+R` 且 `0≤R<D`。这一修正针对冗余商位舍入，与外层有符号 ISA 修正是两件事。

后续仍可重新生成更激进的 PD 表、调整截断位数或评估厂商除法 IP。SRT 理论背景可参阅
[Harris、Oberman、Horowitz 的原始论文](https://pages.hmc.edu/harris/research/SRT.pdf)；
这里的整数缩放与全精度实现是本项目的具体设计。

## 明确的时序边界

请求在上升沿 E0 握手；下表假定响应端保持 ready，L 为有效除法位宽：

| 运算 | rsp_valid 最早有效 | 响应最早握手 |
|---|---|---|
| DSP 乘法 | E0 后 | E1 |
| Booth-Wallace 乘法 | E2 后 | E3 |
| 移位乘法 | E(XLEN) 后 | E(XLEN+1) |
| 普通移位除法/余数 | E(L) 后 | E(L+1) |
| SRT 除法/余数 | E(L/2+1) 后 | E(L/2+2) |
| 除零/有符号溢出 | E0 后 | E1 |

后端完成当拍直接给 `rsp_valid`，消除了统一包装器原有的额外完成周期；背压时才进入
RESULT 保存结果。表中的响应握手按上升沿计，计算延迟与连续请求吞吐不同。特殊除法
在请求沿保存结果并进入 RESULT，因此与 DSP 后端一样至少占用一个请求/响应周期。

## 配置与验证

```bash
make test XLEN=32                         # 默认 DSP + 移位除法
make test XLEN=64 MUL_IMPL=1 DIV_IMPL=1   # Booth-Wallace + SRT
make mdu-backends XLEN=32
make mdu-backends XLEN=64
```

`MUL_IMPL/DIV_IMPL` 经 Make 导出给 Verilator runner；直接调用 Verilator 时使用
`-DCORE_MUL_IMPL=...`、`-DCORE_DIV_IMPL=...`。每次编译只实例化选中的后端，
不会将五种硬件同时放入 CPU。非默认 FPGA 配置也必须显式设置相同宏，不能改变
仿真/综合的算法。当前 Vivado 工程仍使用宏缺省值，厂商 IP 待以后评估。

`tb_muldiv_backends` 并行实例化六种配置，对 RV32/RV64 全部适用指令检查独立
算术参考、精确延迟、输入快照、背压、取消、复位和乘除交替；随机数同时覆盖大、小除数。
`tb_mdu_unsigned` 穷举 8 位输入：三种乘法共 196608 次，两种非零除法共 130560 次，
并要求覆盖五种 SRT 商位与两条末余数修正路径。
`tb_div_srt4_components` 单独遍历 QDS 阈值范围以及在线转换的算术恒等式。

`make mdu-backends` 先运行正式 riscv-tests 生成镜像，再对六种配置逐一运行三个
M 整核 TB 和全部 8/13 项 UM，日志单独保存在 `logs/mdu-matrix-rv<XLEN>/`。
默认完整回归另外包含 EX、A 阶段、MI/UI、C smoke 和 CoreMark。
完成上板后再根据 DSP/LUT、关键路径与实测频率选择算法或加深主流水。
