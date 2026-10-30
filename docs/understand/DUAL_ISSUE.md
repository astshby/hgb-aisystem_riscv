# 双发射 Core

当前配置为 ROB16、独立整数 IQ8/内存队列4、LQ4/SQ4、双 ALU、双 AGU，
按序双退休。有限整数乱序关闭，Tournament 保留，RAS 关闭，转发模式 3。
RV32 用于性能优化，RV64 跟随共享 RTL 验证。常规 ALU/Load/DSP 路径为 8/10/10 级；
可选增级上限 12，当前未新增 C 扩展。

取指按 64 bit 成对进入 FIFO；D1 做类型和部分直达控制，后续译码与源操作数绑定分开。
RAT 把源/目的映射到 ROB 标签，scoreboard 记录可用性和相关；同拍 RAW/WAW 按老指令优先处理。
两个指令能否共同发射取决于依赖、功能单元和完成容量，双发射不代表每拍必发两条。

ISS 捕获已经选定的操作数；CMP 保存功能单元完成；ROB 保存结果、异常和顺序。
退休只取最老的已完成项，写架构寄存器并产生 trace。分支恢复取消年轻项，已接受的访存
响应仍按 owner 排空；Store/MMIO 必须得到队头授权，不能因推测执行产生外设副作用。

LQ 与 SQ 分离描述符/有效位/完成状态，`load_store_queue` 管双数据口仲裁与 owner。
两个 AGU 不代表两个任意 Store 可以同时提交；第二数据口按当前优化配置只承担读路径。
共享年龄关系、Store→Load 字节转发和新分配 Load 提前请求减少等待，同时保留请求寄存边界。

2026-10-30条件候选`b94580c`保持8/10/10级与包宽401/625位，调整三个组合边界。
RAT先从`map_q[rs]`选中条目再检查退休，第二槽显式旁路第一槽的新标签；映射更新、
checkpoint和恢复仍按原顺序。D1为合法B/JAL提前计算绝对目标并复用`imm`字段，
scoreboard中的D1和branch_unit配对开启`PC_REL_TARGET_IN_IMM`；JAL沿用原专用快路，
JALR和其他指令继续保存原位移，legacy默认参数为0。IQ/ISS以后解释B/JAL包时须遵循该语义。
ISS的`STATIC_SELECT`用固定两槽压缩/插入替代宽包可变索引，保留原标记、无效槽载荷和复位/flush行为。
这些修改不增加等待拍或状态位；RAT双宽4项、B/JAL与ISS双宽12项对照通过，频率与整体回归另记。

`make scoreboard-test XLEN=32|64` 覆盖 RAT、RAW/WAW、广播、双发射、恢复、退休、LSU 和完成队列；
`make check` 另覆盖 ISA、异常/CSR、SoC 与异频通信。历史实验通过本地 archive 标签和 git log 查询。
