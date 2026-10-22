# 双发射学习

> 写作约束：[regulation.md](../../../regulation.md)。本文描述当前 scoreboard 后端及旧控制组边界。

当前 P1.1a 候选从 `main@094443e` 建立 `core/p1-1a-split-lq-sq`。
LQ/SQ 的控制和数据已拆入两个模块：LQ 持有 Load 描述符、逐字节 Store 转发、
读返回格式化及完成；SQ 持有 Store 描述符、队头写授权、写返回及完成。
两者通过 `lsu_entry_view_t` 共享存活描述符，分别拥有分配容量和状态写使能。
包装层只保留双端口请求仲裁、反压 owner、重复响应路由和两项完成选择。
ROB16/IQ8、按序发射、完整标签、取消排空与 ALU/Load/DSP 的 8/10/10 级边界保持。
`run_lsq_equivalence.sh` 从 P0 提交提取参考 LSU，逐沿检查有效请求、完成、转发、
Store owner、拒绝响应与容量；现有 LSU 测试另覆盖单类队列满时另一类可分配。
完整仿真已通过：RV32 231 PASS/5 SKIP，RV64 267 PASS/5 SKIP，包含各五项
LSU 差分检查。四次 RV32 M0/M1 同镜像比较的 CRC、ROI/TB 周期和全部统计相同。
新镜像由 GCC 11.4 编译，M0/M1 performance 为 2.633659/2.317931 CoreMark/MHz。
DDR IP 已用厂商 HMIC_S 1.10 包自行生成，32/32 DQ 元数据匹配；新完整 SoC 工程
的 228 项输入已校验。P1.1a 标准 PDS 已完成：86.1721 MHz、85 MHz WNS +0.160 ns、
TNS 0、12 类 STA 零失败、零未布通。物理 40,181 LUT、32,188 FF、36 DRM、4 APM；
最差路径仍由 Store 地址经转发、IQ 操作数选择进入分支，20 级、11.135 ns。
结果为 `logs/p1/p1-1a/pds-result.json`，实测源码 `a23b65c`，未上板。
P1.1b 位于 `core/p1-1b-rob32-split-iq`，显式选择 `RETIRE_ENTRIES=32 SPLIT_ISSUE_QUEUE=1`。
`split_scoreboard_queue.sv` 分别保存 int8/mem4 操作数并合并全局最老两项，
保持按序发射，提交 `f547da3` 完整回归为 RV32 228 PASS/5 SKIP、RV64 264 PASS/5 SKIP。
四次同镜像比较通过，M0/M1 为 2.635803/2.335916 CoreMark/MHz，标准 PDS 尚未完成。
P1.2 在 `core/p1-2-limited-integer-ooo` 开发，显式开启 `LIMITED_INTEGER_OOO=1`。
`integer_issue_queue.sv` 使用独立有效位分配空槽，选择最老就绪整数项，不压缩宽包数组。
完整 ROB 标签和已捕获数据保留 RAW/WAW/WAR 语义；忙 MDU 留在 IQ，避免占住 ISS。
内存队列保持 FIFO，未知 Store 地址挡住后续 Load。整数 IQ 中尚未接纳的 CSR/系统
指令阻止年轻候选越过；串行项到 ROB 队头后才进入 ISS，执行时仍要求 LSU 排空。
就绪旁路只允许 ALU/MDU 越过等待项，访存和分支保留接纳顺序。队列暴露最老两个
未发射整数标签，同拍第一条带走老项时仍允许第二条有序访存，容量不借用当拍 pop。
首轮 ISA 的未对齐半字/双字超时来自年轻晚异常先占 ISS，阻塞尚在 IQ 的老分支；
修正上述顺序边界后，十场景精确事件及双宽定向通过；Core ISA 为 RV32 58 PASS/2 SKIP、
RV64 78 PASS/2 SKIP，原三个超时用例均通过。
定向测试覆盖旁路、数据依赖、MDU 忙、串行屏障、空槽复用及回绕恢复，双宽各三项
通过。Core 为 RV32 830 条/492 拍、RV64 832 条/510 拍，各观察到 30 次实际整数旁路；
新增 RAW 消费者与 FENCE 用例，指令流与 P1.1b 的 Core 测试不同，不直接比较拍数。
精确事件十场景通过；快照/PDS 交接/时序工具分别 27/25/18 PASS。
`5963d72` 完整回归为 RV32 229 PASS/5 SKIP、RV64 265 PASS/5 SKIP，四次同镜像比较通过。
M0/M1 为 2.670535/2.378539 CoreMark/MHz，较重建 P0 提高 1.4002%/2.6147%。
performance 全程 RAW 等待为 1,620,773/3,479,525 拍，P1.1b 为 2,342,183/4,942,543 拍；
LSU 等待增至 984,283/1,452,702 拍，ISS 的 MDU 反压计数均为零；该计数不包含 IQ
内部等待，不据此判断全部 MDU 瓶颈。未增加 MDU 或 ALU 流水级。
结果及命令为 `logs/p1/p1-2-precise/regression/summary.json`。
P1.3 在 `core/p1-3-iq-forward-timing` 开发。整数选择改为并行
年龄序位和独热数据选择，新增 6,144 组就绪掩码、年龄排列及资源组合测试。
旧 LSU 早期总线同时包含 Store 转发和合法读返回，现分源并保留原同口返回优先级。
Store 提示仍在同口合法返回有效时关闭；请求、取消、响应和完成握手保持。

| `SCHEDULER_FORWARD_MODE` | 捕获与当拍选择 |
| --- | --- |
| 0 | 保留原全部旁路，作为周期对照 |
| 1 | 分支忽略全部 LSU 提示，其他类别保留当拍旁路 |
| 2 | 分支忽略全部 LSU 提示，其他类别先捕获 LSU 提示再选择 |
| 3 | 合法读返回保留直通，Store 提示先捕获；分支忽略 Store 提示 |

九口旁路分别为两口 ROB 完成、两口 ALU 入 CMP、一口 MDU 入 CMP、两口合法读返回、
两口 Store 提示，均保留完整 ID、取消和错误检查。模式 1/2 对分支的寄存捕获和当拍
视图同时屏蔽；模式 3 分开合法返回与晚 Store 资格。周期结果如下，频率待最终 PDS。
分配时在类型分流之前共享 ROB/广播捕获，bank 不再重复读 ROB，仍各自保存等待状态。
四模式双宽定向各 17 PASS/0 SKIP，包含 6,144 组选择检查、跨 bank 捕获、来源优先级
及十场景精确事件；Core 均为 492/510 拍。新增被动 IQ 统计的计数器双宽各 1 PASS、
解析器 8 PASS，双宽 P0 LSU 差分各 5 PASS/0 SKIP。

`ea3fb0a` 五组、二十次 RV32 固定镜像比较全部通过，镜像均复用 GCC 11.4 重建 P0。

| 转发模式 / predictor / RAS | M0 performance ROI | M1 performance ROI | M0/M1 CoreMark/MHz |
| --- | ---: | ---: | --- |
| 0 / 0 / 0 | 23,965,231 | 26,907,276 | 2.670535 / 2.378539 |
| 1 / 0 / 0 | 26,094,649 | 29,072,228 | 2.452610 / 2.201414 |
| 2 / 0 / 0 | 26,934,277 | 30,152,459 | 2.376154 / 2.122547 |
| 3 / 0 / 0 | 23,970,812 | 26,911,686 | 2.669914 / 2.378149 |
| 3 / 1 / 1 | 21,817,688 | 24,933,959 | 2.933400 / 2.566781 |

模式 0 的四次 CRC、ROI/TB 及全部旧统计与 P1.2 完全相同。屏蔽分支全部 LSU 旁路
增加等待；模式 3 相对 P1.2 的 performance 周期仅增加 0.0233%/0.0164%。选择模式 3
配合 Tournament/RAS，比同镜像 P0 得分提高 11.3812%/10.7359%；validation ROI 为
21,883,523/25,043,117。配置入口为 `source scripts/verilator/p1_core_config.sh`。
原始命令、镜像和结果哈希在 `logs/p1/p1-3/candidate-summary.json`，所有仿真器已封存。

新 IQ 统计使用完整生产者标签区分 RAW 来源，计数可重叠；模式 0 的 M0/M1 全程
MDU 资源等待只有 741/742 拍，Load RAW 为 11,140,475/14,601,178 拍。IQ 无候选
不等于 Core 无发射，访存 bank 同拍仍可能工作；不将这些计数与旧 `no_issue` 分类相加。
本轮保留 ALU/MDU 级数。`8c072c0` 最终回归为 RV32 237 PASS/4 SKIP、
RV64 269 PASS/4 SKIP，RV32 包含八次固定镜像重放。两轮的 CRC、ROI/TB、新旧统计和
镜像哈希逐项一致，也与选定候选一致；原始日志和实际仿真器已封存。
结果为 `logs/p1/p1-3-final/regression/summary.json` 和 `replay-audit.json`。
另外双宽各五项 LSU 差分通过，RTL/TB 与最终提交逐文件相同。
最终原生工程包含 230 项已校验输入、216 个 HDL，全部 FDC 与已通过 P1.1a 的版本逐字节
相同，没有修改 false path。综合为 57,437 LUT、41,497 FF、零 latch、36 DRM、4 APM，
230 项输入及 I/D-TCM 各 64 KiB 初值匹配。首轮标准 place 在 20,193 MB 内存池峰值
时申请 51,145,552 字节失败，没有布线或最终 STA。从综合完成快照复制到全新目录，
283 个文件哈希一致，230 项输入和双 TCM 再次通过。重试启动前物理可用/提交余量
19.988/24.021 GiB，place 仍在申请 92,745,552 字节时失败，内存池峰值 22,191 MB，
耗时 6 分 8 秒；Windows 事件 2004 记录 PDS 提交量 42,237,083,648 字节及虚拟内存不足。
两次均未进入 route，不将工具内存池峰值当作进程提交量。失败收据为
`logs/p1/p1-3-final/retry-place-failed.json`，原工程、网表和日志保留。
用户已要求暂停布局；最终 P1.3 没有 Fmax/WNS、物理资源、最差路径或未布通数量，
代码与仿真结果提交分支 PR，最终物理验收未完成。
P1.1b 中间工程标准布局完成，布线第 13 轮仍有 24,179/69,295 条未布通，已主动终止并
保留全部日志，没有最终 Fmax/WNS。记录为 `logs/p1/p1-1b-drain/pds-cancelled.json`。
以下 r15 数据保持其历史归属。

新 P0 按工作区 [Codex B11](../../../OPTIMIZATION_PLAN.md#b11-core-完善后建立新-p0scoreboard-双发射)
实施。r15 已通过 RV32 完整 SoC 的 85 MHz 内部 STA，用户已决定冻结为新 P0，
发布基线为 `publish/p0-r15`；CMP 的 87.8837 MHz 仅作 7 级 ALU 诊断对照。
历史检查点保留在各阶段分支，当前状态与测量记录见
[HANDOVER.md](../../../HANDOVER.md) 和 [ITERATIONS.md](../../../ITERATIONS.md)。

## 1. 流水与状态所有权

P0 冻结配置为 `CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16 MUL_IMPL=0 DIV_IMPL=1`，
IQ8、LQ4/SQ4、checkpoint4、p0/r0。`CORE_BACKEND=legacy` 保留原控制组。
r15 开发分支 `core/pipe-lsu-forward-format` 基于完成预选测量文档检查点 `57ca4d2`。
已将转发值按 Load 槽提前格式化，再按原选择向量送两个输出；提示有效与载荷分离，
保留全部资格/取消规则和请求/完成时点。双宽 LSQ/Core/events 共 10 PASS，新增
双口不同偏移/类型及旧错误响应同拍的用例。`dffb8a2` 完整测量已完成，RV32
228 PASS/5 SKIP、RV64 功能 264 PASS/5 SKIP；r15 为 85.2464 MHz、WNS +0.034 ns，
85 MHz 通过，比 CMP 87.8837 MHz 低 3.00%；用户已确认冻结当前 8–10 级 P0。
RV32 统一承担性能优化与标准 PDS，RV64 只要求功能、ISA 和 SoC 仿真通过。

已应用完成数据预选与全局清空控制分离，保持 8/10/10 级及原分支罚拍；`180f6fc`
完整双宽回归与八次重放通过，r14b 标准 PDS 为 82.7423 MHz，频率仍未通过。
CMP RTL
`2b49c77` 已完成完整双宽回归和八次固定重放，r12 标准 PDS 达到 87.8837 MHz。
ISS 提交 `85ab1ca` 已通过完整双宽回归与八次重放，r13 完整标准 PDS 为 82.8726 MHz、WNS −0.302 ns、86 个 slow setup 失败端点、零未布通，频率验收失败。

```text
原生 IF64 → 取指 FIFO8 → 两槽译码寄存 → RAT/ROB 双分配 → scoreboard IQ8
                                                          │
                                          两条已就绪的年龄前缀进入 ISS2
                                                          │
                                                寄存操作数后按序执行
                                                ┌─────────┴─────────┐
                                              ALU0/AGU0          ALU1/AGU1
                                                └────共享 BR/MDU────┘
                                                      │
                              ALU0/ALU1、MDU、LSQ 本地双完成口，共五源
                                                      │
                                         每源两项 CMP → 最老两个完成 → ROB16 → 双退休
```

ALU 复用原结果寄存作为 CMP 首项，LSU/MDU 在本地完成与中央选择之间增加一拍。
CMP 单独检查点的 ALU 通路为 7 级。当前独立 ISS 形成实际寄存边界，普通 ALU
通路为 8 级，Load/DSP 乘法为 10 级；外部等待和除法迭代另计。实际边界如下：

| 通路 | 保存边界 |
|---|---|
| ALU，8 级 | 取指请求 → 取指 FIFO → 译码寄存 → IQ → ISS → ALU 完成 FIFO → ROB 结果 → 架构写入 |
| Load，10 级 | 取指请求 → 取指 FIFO → 译码寄存 → IQ → ISS → LSQ 描述符 → LSQ 返回结果 → CMP FIFO → ROB 结果 → 架构写入 |
| DSP 乘法，10 级 | 取指请求 → 取指 FIFO → 译码寄存 → IQ → ISS → DSP 乘积 → MDU 结果 → CMP FIFO → ROB 结果 → 架构写入 |

CMT 只有在合并已有边界后才评估，不能直接把 Load 路径加到 11 级。
除法包含幅值准备和 SRT 迭代状态，单列执行延迟；8–10 级主流水不表示除法、
Cache miss 或外部 DDR 访问都在十拍内完成。MDU 适配器只保存标签，不另存结果。

取指、IQ、长执行和访存含队列及反压，不能用固定拍数描述所有指令。普通整数指令
经过译码寄存、IQ 和执行结果寄存；MDU/LSQ 独立持有事务。发射保持年龄前缀，
年轻指令不能越过未就绪的队首；已发射指令允许先后完成，提交保持程序顺序。

| 状态 | 所有者与作用 |
|---|---|
| 架构 GPR | `regfile.sv`，4 读 2 写，年轻退休写口优先，x0 恒零 |
| 推测寄存器名 | `rename_table.sv`，RAT 将架构寄存器映射到完整 ROB 标签 |
| 待发射指令与操作数 | `scoreboard_queue.sv`，保存标签及已捕获数据，输出年龄前缀 |
| 已就绪待执行指令 | `issue_queue.sv`，两项完整寄存包与分支结果，双出双入、部分消费、取消压紧 |
| 推测结果、异常、退休顺序 | `retire_queue.sv`，16 项 ROB，标签包含槽号与代次 |
| 待中央接纳的完成结果 | `completion_queue.sv`，五源各两项，寄存结果、完整 ID 和异常 |
| Load 事务 | `load_queue.sv`，LQ4、逐字节转发、读返回与取消排空 |
| Store 事务 | `store_queue.sv`，SQ4、队头授权、写返回与取消排空 |
| 访存端口仲裁 | `load_store_queue.sv`，两个请求 owner、响应路由、两项完成选择 |
| 分支恢复 | 四份 RAT checkpoint、ROB 年龄边界和执行/LSQ 取消接口 |

采用 data-in-ROB 重命名，没有额外 PRF/free-list。多个同名写者可以同时在途，
WAW/WAR 假依赖不再按旧唯一写者规则停顿；真实 RAW 绑定最近更老生产者，
等待或按完整标签捕获前递。同组后一条读取前一条新分配的标签。

## 2. 双发射、执行与精确恢复

两个槽都有完整整数 ALU 与 AGU。分支和 MDU 可从任一槽进入各自的共享单元；
同组双分支、双 MDU 按资源冲突串行，CSR/系统指令保持独占和队头授权。
两条访存可以双入队，外部带宽另受内存类型与 bank 冲突约束。

ALU0/1、MDU 与 LSQ 本地两个完成口各接两项 FIFO。来源接纳握手释放本地结果，
中央每拍从已寄存来源选择最老两项；未获选的结果继续保持。FIFO 输入容量只由
寄存占用决定，满时不能借当拍出队位置，切断中央 ready 返回发射的组合路径。
占用一项时可同拍出入，五源总共最多保存十项完成，不改变 ROB 的 16 项容量。
分支恢复逐项取消年轻完成，较老项保留；取消清空前的 busy 参与迟到响应排空和
代次复用保护。未对齐和访问异常的完整归属随结果保存。

IQ 捕获两路中央广播、两路 ALU 与一路 MDU 入 CMP 广播、两路 LSU 返回/转发提示。
提前广播必须满足真实接纳、完整 ID 匹配存活生产者、GPR 写有效、无异常及无重定向。
LSU 提示在 `result_q` 前提供已格式化值，同口返回优先于 Store 转发；没有获得提示
口的值仍经正常完成交付。只捕获操作数，不提前标记 ROB 完成或更新架构寄存器。
IQ→ISS 接纳侧按完整标签旁路当前广播，进入 ISS 寄存器后才供 ALU/AGU/MDU 执行。

共享分支单元在 IQ→ISS 接纳时判定，结果随 ISS 包保持，恢复事件独立寄存且只报
一次，不等待完成 FIFO 和中央仲裁；未对齐跳转仍在执行侧生成精确异常。D1 接纳
JAL 后产生一次前端重定向，低槽 JAL 丢弃高槽年轻指令，WB/已分配分支恢复优先。
保存原预测训练上下文，执行侧记录已修正目标，避免重复恢复同一 JAL。
LSQ 仍有八个物理槽，当前仅本地选出的两个候选进入 CMP；
历史固定槽十一源实现保留在 `0664ea7`，不能套用其源数量描述当前路径。

scoreboard 的 ROB 开启 `REGISTER_RETIRE=1`：完成先写入结果阵列，下一拍才可
退休，切开完成仲裁到异常、分配、取指的反馈。中央广播唤醒与 ROB 写入同时发生，提前广播可更早保存操作数；每拍仍可
完成两条和退休两条；Store 队头等待及整体周期代价按固定镜像单独测量。
旧核保持原有完成到退休旁路。新增定向测试覆盖异常等待、重复完成、分支恢复、
标签回卷与连续 100 拍双退休；整核测试仍连续 129 拍双发射、双退休。

分支后台解析后恢复到自身 checkpoint，保留分支和更老项，取消年轻结果及
副作用。外部已展示且受反压的读继续保持直到接纳，随后排空返回；复用标签前
确认旧 owner 排空。异常、MRET、IRQ 通过有序退休提交；两个 trace 按年龄输出，
Trap/MRET 后继 PC 来自提交时 CSR，IRQ 保存最后实际退休指令的后继。

预测训练接收两条真实退休事件并按序送往预测器。RAS 的 committed 栈先应用
两条退休，再重放存活 ROB；D1 JAL 恢复还按序重放尚未分配的两个 decode 项。
支持 p1/r1 功能测试，P0 模板使用 p0/r0：p0 是 GShare，r0 关闭 RAS。

## 3. 双 LSU 与真实端口边界

| 对象 | 已实现 | 冲突与顺序限制 |
|---|---|---|
| Core 访存 | 双 AGU、两路完整标签请求/响应；中央每拍最多接纳两项完成；跨口乱序返回 | 本地两个完成候选各接 CMP，外部带宽仍为两路；响应按完整 ID 验证 |
| Load | 多笔普通 RAM Load，完整字节覆盖时 Store-to-Load 转发 | 部分覆盖等待；不能跨过未知地址的更老 Store |
| Store | 双 Store 入队，保留各自数据与字节掩码 | 外部 Store 只从端口 0 按 ROB 队头授权，响应后退休 |
| MMIO | 地址/数据/异常归属保持 | 仅队头可外发，不推测读取有副作用寄存器 |
| TCM | 每块 64 KiB，两物理 bank，IF64、D0/D1、DMA 仲裁 | RV32 IF64 同时占两 bank；双数据接受须不冲突且当拍获得 bank |
| I-cache | 4 KiB、两路组相联、32B 行、64 位同步阵列，命中 II=1 | blocking miss，失效/错误填充按协议排空 |
| D-cache | 总 4 KiB，两个各 2 KiB 的两路组相联 bank，地址 bit10 选 bank | 不同 bank 可并行命中；同 bank 串行；单 bank 仍为阻塞式控制器 |
| DDR | Cache 行口与 DMA 块口接原外部通道 | 共享填充/写回所有权，没有增加第二条物理 DDR 通道 |

`555453f` 在两个 Core 数据口进入 SoC 路由前各加二项寄存请求队列，切开
LSQ 选择、地址解码与 Cache ready 的长组合链。请求多一拍，稳态各路 II=1；
满队列不组合借用下游当拍弹出的空位。请求一旦接纳就保持完整标签，取消读仍
外发并排空，LSQ 在真实响应到来前保留 owner。该候选 `555453f` 的 M1 成绩为
RV32 2.142396、RV64 1.911813 CoreMark/MHz；`b98f714` 保留无额外请求拍的对照。
加入 ROB 寄存退休后的当前成绩另列于本节，频率仍待最终布线报告。

TCM 响应受反压时转入客户端缓冲，释放共享 RAM，避免 IF FIFO 满时占住解除
数据停顿所需的 bank。直接消费仍为一拍。I-cache 失败填充逐 word 回退，保留
上下半字的独立取指故障。D-cache 两 bank 唯一拥有各自缓存行；维护命令各发一次，
等待两者返回，保持脏数据、反压和错误归属。

## 4. 验证与测量

当前已测检查点为 `dffb8a2`，完整双宽功能/ISA 和 RV32 四次固定镜像重放通过。
命令、源 SHA、镜像 manifest、CRC、ROI/TB 周期在
`logs/pipeline/forward-format-dffb8a2-20261021/summary.json`；与 CMP 的逐项对照为
同目录 `p0-acceptance.json`。逐项结果如下：

| 检查 | RV32 PASS/SKIP | RV64 PASS/SKIP |
|---|---|---|
| scoreboard 定向 | 17/0 | 17/0 |
| p1/r1 Core/events | 2/0 | 2/0 |
| legacy `make test` | 80/2 | 80/2 |
| Core ISA | 58/2 | 78/2 |
| SoC ISA | 59/1 | 79/1 |
| benchmark-smoke | 1/0 | 1/0 |
| SoC 请求/TCM/I$/D$ | 5/0 | 5/0 |
| DMA 软件/AXI | 2/0 | 2/0 |
| M0/M1 performance+validation | 4/0 | 不作验收；M0 附加 2/0，M1 取消 |

合计 RV32 228 PASS/5 SKIP、RV64 功能 264 PASS/5 SKIP，附加 M0 不重复纳入功能
总数。RV64 M1 按用户范围取消，不计失败；原脚本未完整结束，范围调整收据与
源码/镜像复核分别为 `scope-change.json` 和 `source-check-after-pds.json`。
RV32 的 M0/M1 为 2.859463363/2.494327354 CoreMark/MHz；四次 ROI/TB、CRC 和
全部计数与 r13/r14b 相同。RV64 不设性能门槛，不做 P&R。

legacy 跳过另一位宽和关闭 RAS 的用例，Core ISA 跳过 fence_i/ma_data，SoC ISA
只跳过 ma_data。测试在仓库根目录运行，工具链由 `RISCV_TOOL_ROOT` 指定。

```bash
export CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=16
export MUL_IMPL=0 DIV_IMPL=1 PREDICTOR_MODE=0 RAS_ENABLE=0
bash scripts/verilator/run_scoreboard.sh 32
bash scripts/verilator/run_scoreboard.sh 64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
SOC_PROFILE=full SOC_LOCAL_TCM_ENABLE=0 make soc-riscv-tests XLEN=32
SOC_PROFILE=full SOC_LOCAL_TCM_ENABLE=0 make soc-riscv-tests XLEN=64
COREMARK_REPLAY_DIR=build/frozen/p0-c6-m0-rv32 make coremark XLEN=32
```

历史 ISS 固定 64 次迭代的八次重放均通过 CRC，以下为 performance 模式；相同镜像
的 head 对照等于 `ebeb0db` 起点（该起点 RTL 同 `4da04b6`）：

| 分类 | RV32 CoreMark/MHz | RV64 CoreMark/MHz |
|---|---:|---:|
| M0 Core-only，ISS | 2.859463363 | 2.657868126 |
| M1 full SoC-TCM，ISS | 2.494327354 | 2.346795592 |
| M0 Core-only，CMP | 2.603344859 | 2.447511304 |
| M1 full SoC-TCM，CMP | 2.296600088 | 2.178052749 |
| M0 Core-only，head 对照 | 2.393947741 | 2.092062108 |
| M1 full SoC-TCM，head 对照 | 2.137353767 | 1.896437672 |

M1 保留 512 MiB DDR 译码、完整外设、Cache 与 DMA 块通道，模型只分配低 64 KiB；
CoreMark 在 TCM，DDR 空闲。镜像在 `build/frozen/p0-c6-m{0,1}-rv{32,64}`，
每个 manifest 保存 ELF/HEX SHA。虚拟 1 MHz tick 的 duration_valid 不等于板上
十秒测量，DDR 执行成绩仍待建立。

ISS 的 M0/M1 对 CMP 提升，RV32 为 9.84%/8.61%，RV64 为 8.59%/7.75%；
历史八次重放的逐项对照在 `logs/pipeline/issue-85ab1ca-20261021/summary.json`。
定向测试包括 FIFO 部分接纳/取消、两路及七路操作数广播。每次改动仍需验证
部分接纳、持续双发射、完整标签复用、分支取消、
Store/MMIO 单次授权、异常、IRQ、Cache 错误和 AXI 返回，不以语法通过代替。

统计窗口为复位释放至测试退出，发射/退休统计按实际握手，等待分类互斥；ROB/IQ
满与完成冲突另记，可与未发射原因重叠。历史完整统计在
`logs/p0/c6-metrics-replay-index.json`，不能与 CoreMark ROI 周期混作分母。
CMP、ISS 各草案的对照结果和代价集中记录于工作区 `ITERATIONS.md` 9.6。

## 5. PDS 与旧控制组

PDS staging schema 4 明确设置新后端 i2/ROB16/IQ8/LQ4/SQ4/IF64/双数据口，
标准综合和 place/route 使用独立新目录。以下 r2 至 r14b 为历史记录。RV32 r2 综合为 40,170 LUT、31,381 FF、
36 DRM、4 APM、0 latch；TCM INIT 全字节匹配。标准 place 在 EP_DL 内存失败，
没有有效 Fmax。并行选择版本 r3 的综合最差逻辑深度从 97 降至 24 级，LUT 为 41,088；
标准 place 仍在 EP_DL 内存失败，峰值工具池 17,057 MB。RV32 ≥85 MHz 硬门槛
仍未通过。r3b 的级联选项被器件拒绝；r4 关闭 LUT 拼合、r5 再关闭单元复制，
标准布局仍内存失败，峰值工具池分别为 17,312 / 17,983 MB。
r6 `b98f714` 默认标准 place 也遇到内存失败。r8 `fdb3ffb` 综合为 41,793 LUT、
31,682 FF、36 DRM、4 APM、0 latch；最差综合路径为 19 级、13.177 ns，经过
ROB 队头、LSQ/中央完成选择到 IQ 操作数捕获。默认标准 place 已完成，用时
12 分 6 秒，工具池峰值 7,682 MB。单线程 route 第 8 轮仍有 38,942 个未布通网络，
该轮耗时 818.903 秒，随后人为中断并保留全部日志。在 `r8-route4` 新目录复用
同一布局，228 项源输入、约束、网表、TCM 初值证据及布局数据库哈希均一致，
启动前 Windows 可用提交内存 8.411 GiB。该轮 Normal 模式、4 线程标准布线已中断，没有最终 Fmax。布局复用记录由 `placement-reuse.json` 绑定，报告工具同时
核对原布局和新布线日志；相关 PDS 工具共 48 项测试通过。

r10 `4da04b6` 标准 place 已完成，4 个拥塞窗口、最大 238.31%；route 第 16 轮
19,459 未布通后停止。head `14897f1` 的 r11b 标准 PDS 已完成，Fmax 81.5878 MHz、
85 MHz WNS −0.492 ns、TNS −83.386 ns、644 个 slow setup 失败端点，零未布通，
物理 LUT/FF 为 44,082/31,820，其余已报告 STA 无失败。最差路径为 LSQ 描述符
经本地完成选择、中央仲裁、ROB 标签核对到 IQ 捕获，18 级、11.420 ns。
CMP 的 r12 综合为 44,087 LUT、31,952 FF、36 DRM、4 APM、0 latch；225 项输入
与两块 TCM 的初值通过。完整标准 PDS 为 87.8837 MHz、85 MHz WNS +0.386 ns、
TNS 0、零未布通；slow/fast setup、hold、recovery、removal、MPW、skew 均零失败。
物理 LUT/FF 为 46,457/32,096；最差路径转为 IQ 读指针→操作数选择→DSP 乘法，
7 级、10.015 ns，高扇出 897。ISS 的寄存边界用于进一步分开 IQ 读出与执行。
原始结果绑定在 `logs/pipeline/completion-2b49c77-20261021/pds-result.json`。
ISS `85ab1ca` 的 r13 完整标准 PDS 为 82.8726 MHz，85 MHz WNS −0.302 ns、
TNS −10.871 ns、86 个 slow setup 失败端点、零未布通，其余已报告 STA 无失败。
物理为 40,750 LUT、32,301 FF、36 DRM、4 APM。最差路径从 IRQ pending 经
重定向、CMP 中央选择、标签核对、IQ 当拍旁路到分支判断，16 级、11.438 ns；
逻辑/布线为 3.372/8.066 ns，clock skew −0.325 ns。频率低于 CMP 和 85 MHz，
联合验收失败，证据为 `logs/pipeline/issue-85ab1ca-20261021/p0-acceptance.json`。
分支后移草案的双宽 M0 对 r13 下降约 2.07%/1.76%，先不采用，M1/PDS 未运行。
完成数据预选 `180f6fc` 已让 FIFO 的寄存候选供中央选取完整结果，全局 flush 关闭中央
接纳有效位及 FIFO 握手，保留清空优先级；分支取消仍在预选前屏蔽年轻结果。
ROB 标签/重复结果校验、广播、IQ/ISS 接纳控制不变，正常周期及分支罚拍不变。
修改涉及 `completion_queue.sv`、`scoreboard_core.sv` 和两个定向 TB；双宽完成 FIFO、
Core/events 及 p1/r1 共 10 PASS，清空沿确认预选可见但接纳与发射关闭。
完整 Core 定向仍为 RV32/RV64 483/504 拍；八次重放的 ROI/TB、CRC 和全部计数与
ISS 相同，`cycle-equivalence.json` 保存逐项对照。被动探针的旧名连接已恢复，并由
`default_nettype none` 拒绝隐式信号；双宽真实 bind 与拼错名字的拒绝检查共 3 PASS。
r14b 完整标准 PDS 为 82.7423 MHz、WNS −0.321 ns、TNS −0.759 ns，5 个 slow setup
失败端点，其余 11 类 STA 零失败，零未布通；物理 40,954 LUT、32,318 FF、36 DRM、
4 APM。最差路径为 LSQ 取消状态→Store 覆盖/请求选择→Load 格式化→IQ 旁路→分支
接纳，18 级、11.675 ns，其中逻辑 3.367 ns、布线 8.308 ns。周期保持、频率仍失败。
转发格式化 `dffb8a2` 已提前并行计算各 Load 槽的值，再按原请求选择输出；提示
有效位独立控制接纳，不增加流水级或等待。修改范围为 LSQ 与相应定向 TB。
本轮 `dffb8a2` 的 r15 标准 PDS 已完成：**85.2464 MHz、85 MHz WNS +0.034 ns、
TNS 0、零未布通**，12 类 STA 均无失败，57,382 条网络全部布通。物理为
40,154 LUT、32,318 FF、36 DRM、4 APM、77 IO；比 r14b 少 800 LUT，FF 不变。
相对 r14b，Fmax 提高 3.03%；比 CMP 的 87.8837 MHz 低 3.00%。
用户已确认按 8–10 级结构、CoreMark/MHz 不回退和标准 PDS ≥85 MHz 冻结 r15 为新 P0。
CMP 是 7 级 ALU 诊断点，不作为本次冻结门槛。原 `p0-acceptance.json` 保留当时
与 CMP 比频率的失败记录，原始数值和判据没有改写。发布基线为 `publish/p0-r15`，
发布仅含当前 P0 文件的一次提交，不带开发历史；原开发和历史阶段分支全部在
本地保留。后续 RTL 优化从独立分支开展。
最差路径为 LSQ `descriptor_q[512]` 经地址比较、转发资格、请求选择、提示完整
标签和 IQ 匹配/操作数选择到 `branch_next_pc_q[0][27]`；19 级、11.183 ns，
逻辑/布线为 3.588/7.595 ns，最高扇出 76。标准 place 用时 20 分 20 秒，
内存池峰值 10,058 MB；route 用时 11 分 28 秒，运行中未发生内存分配失败。

每阶段启动前读取 Windows 物理可用内存与提交余量，两项均至少 6 GiB；仿真/编译
与 PDS 分时运行。本次冻结依据为当前 8–10 级结构、RV32 固定镜像周期不回退、
标准 PDS ≥85 MHz、零未布通及全部已报告 STA 通过；I/O 和板级验证仍单列。

Core、TCM、Cache、MMIO、AXI 用户侧目前共用 DDR IP 的 125 MHz 用户时钟。
85 MHz 是独立的约束目标实验，未重新生成 DDR IP、未改变实际板上时钟。
DDR PHY/IO 时钟与整机 STA 需要单独列明。没有拿旧 i1 的 92.3306 MHz 代替新后端。
本轮检查仍有 35 个输入和 73 个输出缺 I/O 延迟约束，未验证板级运行。

旧后端为有限双发射、第二槽普通 ALU、无 RAT、单 LSU、SoC 串行拼接 IF64。
旧矩阵和 q8 性能保留在历史分支 `fpga/i2-core-c5` 及后续 I2 分支；不把它们与
新 scoreboard 的端口、性能或时序混记。第二分支单元、第二 MDU、任意乱序发射、
多路物理 DDR 通道均未实现。P1 至 P6 在新 P0 完成后继续。
