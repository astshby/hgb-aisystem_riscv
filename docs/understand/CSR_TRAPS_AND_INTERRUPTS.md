# CSR、同步异常与机器中断：从指令到退休

本文跟随 s5/cache-up 的 Core 源码阅读。机器模式是当前唯一运行的特权级；枚举里保留的 U/S 异常编号不代表已实现 U/S 模式、分页或 S 模式代理。需要先区分三类事件：某条指令的同步异常、设备电平触发的中断、正常控制流重定向。分支预测错误、普通 FENCE 和 MRET 会改变 PC，却不构成同步异常。

## 先看五个源文件

| 文件 | 现在负责的事 | 阅读时的问题 |
|---|---|---|
| [riscv_priv_pkg](../../vsrc/pkg/riscv_priv_pkg.sv) | CSR 地址、机器中断位、异常/中断 cause 编号 | 编码是什么，哪些只是保留值？ |
| [d1_exception_check](../../vsrc/core/decode/d1_exception_check.sv) | 指令 PC、译码非法、ECALL/EBREAK、JAL 目标 | 这一拍已经知道什么？ |
| [ex_exception_check](../../vsrc/core/execute/ex_exception_check.sv) | CSR 权限、访存对齐、条件分支/JALR 目标 | 哪些值要等操作数与 ALU 算出？ |
| [wb_stage](../../vsrc/core/writeback/wb_stage.sv) 与 [trap_controller](../../vsrc/core/writeback/trap_controller.sv) | 等响应、补 access fault、选 Trap/MRET/FENCE 重定向 | 谁能修改架构状态？ |
| [csr_file](../../vsrc/core/csr/csr_file.sv) 与 [interrupt_entry](../../vsrc/core/control/interrupt_entry.sv) | CSR 状态、设备中断资格、恢复 PC | PC 与 MIE/MPIE 在哪个沿更新？ |

CSR 指令的旧值在 EX 读取；csr_bypass 处理较老在途写，csr_warl 将软件拟写值限制到当前实现位，WB 在正常完成后才真正写 csr_file。EX 预先计算不等于提前提交。异常指令进入 WB 时，commit_packet 可以有效并报告 exception，但 GPR/CSR 普通写端口必须关闭。

## 同步异常为何在几级分别发现

IF 收到取指错误后，把发生请求时的 PC 与错误一起保存。D1 先检查 PC 对齐，再按取指错误、非法译码、ECALL、EBREAK、JAL 目标顺序产生 exception_t。既有异常优先，不能因为返回数据碰巧像非法指令，就把取指访问错误改成非法指令。ECALL 在当前机器模式产生 cause 11，EBREAK 为 cause 3；处理器通过 Trap 入口交给软件，不用它们直接给仿真测试报 PASS。

访存有效地址、CSR 访问是否合法以及分支/JALR 实际目标要到 EX 才知道。EX 检查自然对齐；本项目在此把非对齐 Load/Store 变成 cause 4/6，ma_data 没有做透明拆分。访存请求若已有异常就不会发出。若合法请求已发出，Load 和 Store 都要在 WB 等完成响应；错误响应此时追加 cause 5/7，mtval 保留原始有效地址。缓存写回失败时，当前触发逐出的访问得到错误；更早退休的 Store 无法被改写成事后精确异常，故障 beat 地址另留在 SoC 状态寄存器。

WB 是正常退休、Trap 与 MRET 的共同边界。同步异常以故障指令 PC 写 mepc、cause 写 mcause、附加地址或指令值写 mtval，转向 Direct mtvec。指令没有正常退休，不增加 MINSTRET；MRET 自身没有异常才恢复状态并跳回 mepc。ECALL 处理程序若要越过该指令，应由软件明确修改 mepc；直接 MRET 会回到同一 ECALL。

## mie、mip 与 mstatus 各回答一个问题

mip 的 MSIP、MTIP、MEIP 分别反映机器 Timer 的软件位、MTIME 比较器和外部汇聚控制器输出。它们是设备电平的投影；向 mip 写 CSR 不能清除设备原因。mie 的 MSIE、MTIE、MEIE 决定各类中断是否允许。mstatus.MIE 是机器模式总开关；只有全局使能、对应 mie 位和 mip 设备电平同时有效，csr_file 才给出 irq_pending。当前选择优先级是机器外部 > 机器软件 > 机器定时器。

进入 Trap 时，旧 MIE 复制到 MPIE，MIE 清零，MPP 保持机器模式；MRET 用 MPIE 恢复 MIE，设置 MPIE。mcause 的最高位区分中断和异常，低位是对应编号。mtvec 只支持 Direct 模式。mcycle 每拍计数，minstret 只计正常退休的指令；中断进入本身没有一条“中断指令”可计数。RV32 的 MCYCLEH/MINSTRETH 可读写高 32 位；RV64 没有这些半宽地址。

## 中断从引脚到处理程序

外设把同步后的 irq_software、irq_timer、irq_external 送进 Core。irq_pending 只关闭新的 IF 请求。此前已被接受的取指、已进入流水的指令、Store 响应和 MDU 运算按顺序继续。interrupt_entry 仅在流水排空且中断仍有效时产生 interrupt_take，然后 trap_controller 以保存的后继 PC 写 mepc 并转向 mtvec。软件清设备源后返回时，PC 指向应执行的下一条指令。

后继 PC 要来自真正退休的 commit_packet.next_pc。已退休 JAL、JALR 或取真条件分支时，该值可以是目标地址，固定用 pc+4 会把中断返回点放错。同步异常和 MRET 的 WB 重定向也会覆盖保存的正常后继。若排空期间中断电平消失，或者 CSR 关闭对应 mie/MIE，就继续原指令流，不制造一个已经撤销的 Trap。

以 DMA 完成为例：DMA 写完最后一个目标 beat 后 STATUS.done 置位；IRQ_EN 令源 ID 7 升高；外部控制器按 PRIORITY、ENABLE、THRESHOLD 把 MEIP 送 Core。处理程序读 CLAIM，检查 BYTES/FAULT/CODE，向 DMA STATUS 写 1 清 DONE/ERROR，再 COMPLETE ID 7。若仍保持电平就可能重新挂起。相关寄存器见 [SoC 外设接口](../SOC_PERIPHERALS.md)。

## 过去的错误及复现入口

| 旧问题 | 实际错误机制 | 现在的约束与测试 |
|---|---|---|
| irq_pending 同时清 IF | 中断排空期间若撤销，已接受但尚未交给 D1 的指令被丢弃；PC 却已推进 | pending 只停新取指；真正 Trap 重定向才清旧路径；tb_core_interrupt 覆盖撤销与 CSR 屏蔽 |
| 中断恢复点写 pc+4 | 跳转已退休后，pc+4 与应执行目标不同 | interrupt_entry 记录 commit_packet.next_pc；中断定向测试覆盖跳转 |
| 把 MINSTRET 当普通 CSR 前递 | 较老 NOP 正常退休会隐式加一，单纯旁路先前写值会读到旧计数 | MINSTRET 访问在较老指令排空前等待；tb_core_minstret 独立统计提交流 |
| RV32 写 MINSTRET 半字时先自增 | 写低半部把高半进位留下；写高半部又多加低半 | 该指令的显式写替代整个计数增量，未写半部保持；tb_csr_file 检查边界 |
| 把 request ready 当完成 | 访存请求已接受，错误响应尚未回来就退休，会漏掉 access fault | WB 以响应有效位决定完成；tb_core_bus_contract 测延迟 Store/Load 与错误 |

[历史修复记录](CPU_IRQ_COUNTER_FIX.md) 给出三个相关缺陷当时的分支和测试结果。本表按当前源码陈述机制；旧文中的“Cache 尚未实现”等话仅属于当时阶段。

## 自己检查一条 Trap

可以从 tb_core_trap 的一条 ECALL 开始：记录进入 D1 时的 PC，看异常包经过 EX/MEM、MEM/WB，确认 WB 无 GPR/普通 CSR 写入、csr_file 更新 mepc/mcause/mstatus，然后 mtvec 处的处理程序修改 mepc 并 MRET。接着用 tb_core_interrupt 比对异步路径：没有异常指令包，先停止新取指、完成老事务，再保存实际 next_pc。最后在 SoC 软件测试中观察设备 W1C/claim/complete 与 mip 电平变化；只写 mip 无法替代清设备原因。

命令从仓库根目录执行：make test XLEN=32、make test XLEN=64 覆盖模块和整核定向；make soc-software XLEN=32/64 运行真实设备中断处理程序；make soc-riscv-tests XLEN=32/64 检查机器级 ISA 与统一内存路径。文档示例是读波形的步骤，异常原因与优先级仍以对应源码为准。
