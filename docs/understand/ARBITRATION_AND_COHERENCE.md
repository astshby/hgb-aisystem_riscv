# 三主端口仲裁、TCM 与未来 Cache 一致性

## 同一物理地址为何会竞争

CPU 的 I 口、D 口与 DMA 是三个请求方。I-TCM、D-TCM 各是一块单端口 RAM bank，
不是“只供 I/只供 D”的两份私有内存：CPU D 能写 I-TCM，DMA 也可读写两块 TCM。
不同 bank 可并行，同一 bank 每拍只能选一个请求。`bus_interconnect` 在接受请求时
记录 owner，响应必须回到这个 owner；不能在响应时根据当前地址重新译码。
每个主端最多一笔在途，反压时锁住目标选择，不能让尚未握手的请求偷换载荷。

SoC 的 `DATA_PRIORITY=1` 使 CPU D 相对可撤回的 IF 请求优先；同时 CPU D 与 DMA
在同一目标间轮流取得授权，以免持续 Load/Store 饿死 DMA。跨 owner 交接隔一拍
是为切断 I 请求撤回与 D ready 的组合反馈，并不是 DDR3 固有时序。IF 另有一项
响应缓冲：Core 当下不能接收时暂存一笔，互连 I 响应仍被消费。以上因果关系在
[`bus_interconnect.sv`](../../vsrc/soc/bus/bus_interconnect.sv) 与
[`soc_top.sv`](../../vsrc/soc/soc_top.sv) 中可追踪。

## TCM 与 DMA 为什么目前不需要 Cache 协议

S3 没有 I$/D$：CPU 和 DMA 访问相同物理 TCM 或仿真外存，不存在私有脏副本。
DMA 完成中断只说明写响应完成，软件随后读目标地址即可见新值；若 DMA 写的是指令，
软件再执行 `FENCE.I`，使旧取指/预测状态失效。它不需要 MMU，也不能由 AXI 总线
自动替代。若 CPU 在 DMA 运行时同时写同一字节，谁覆盖谁取决于接受顺序，软件应
避免这种竞态；DMA 也在启动前拒绝自身源/目的范围重叠。

## S4 两路组相联 Cache 的新增义务

加入 D$ 后，CPU 可能持有脏行：DMA 从内存读会看到旧值；DMA 写内存后，CPU
可能命中旧缓存行。加入 I$ 后，DMA 写可执行代码也不能只靠取指重定向保证更新。
因此 S4 必须先定地址属性（TCM/MMIO bypass 与可缓存外存）、行粒度的清理/失效
操作和软件调用顺序，再测 DMA→CPU、CPU→DMA 与自修改代码。该阶段可先使用
软件管理的一致性策略，不能声称已有硬件 coherent DMA。未来 MMU、S 模式或 OS
会进一步引入虚实地址与页属性，但不改变 S3 的物理总线与一笔在途基本契约。
