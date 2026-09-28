# D$：写穿透、MMIO 旁路与 DMA 数据交接

2026-09-29（Asia/Shanghai）。本轮在 `s4/cache` 的 I$ 基础上加入两路阻塞式 D$。
设计基线见 [S4 方案](S4_CACHE_DESIGN.md)，I$ 时序见 [I$ 解读](ICACHE_IMPLEMENTATION.md)。

## D$ 是不是 I$ 加 MMIO

两者共享 tag/valid/LRU、同步数据阵列、填行与端口路由的基础设施，但 D$ 不缓存
MMIO。MMIO 是必须直接下传的访问类别，另有一个 MMIO 寄存器用于维护 D$。

```text
CPU I → I$ / 旁路 ─────┐
CPU D → D$ / 旁路 ─────┼→ 原互连 → ROM / TCM / MMIO / DDR 桥
DMA ──────────────────┘
系统 MMIO 全失效命令 ─────→ D$ valid / discard
Core FENCE.I 退休事件 ────→ I$ valid / discard / 预测状态
```

如果 UART 接收寄存器进入 Cache，第二次读取可能不访问 UART，读清除副作用就丢了；
如果写寄存器被缓存，设备可能迟迟收不到命令。因此当前只缓存合法 DDR 数据，
ROM、TCM、MMIO、高位地址错误和不足整行的 DDR 尾部都保留原始旁路语义。

## 当前策略与参数

- 两路、物理地址、阻塞式；默认每个 D$ 4 KiB、32 B 行、64 组、一位精确 LRU。
- Load hit 返回完整 XLEN 对齐字，原来的 Load 单元负责 lane 选择和符号扩展。
- Load miss 填充整行：RV32 8 笔 4 B，RV64 4 笔 8 B，不使用 AXI burst。
- Store write-through：写命中或缺失都把原始请求交给下层，必须等写响应。
- Store no-write-allocate：写缺失不读填行、不占新 way，也不淘汰其他有效行。
- 没有 dirty、Store buffer、提前写确认、写回或硬件 DMA 一致性。

SoC 参数为 `DCACHE_ENABLE`、`DCACHE_BYTES`、`DCACHE_LINE_BYTES`；
DDR 容量仍由 `DDR_BYTES` 配置，默认 0 表示外存不存在。Cache 开关不能让不存在
的物理内存变得可用。六级流水、load-use、MDU 和 WB 完成规则均未改变。

## 文件分工与和 I$ 的复用

| 文件 | D$ 使用方式 |
|---|---|
| `dcache.sv` | 读查找/填行、写命中快照、等待写完成、维护 discard |
| `cache_port.sv` | `INSTRUCTION=0` 选择数据访问，复用权限检查、旁路与响应归属 |
| `cache_data_array.sv` | `WORD_BYTES=DBUS_BYTES`，支持逐字节写；I$ 仍为 4 B/全掩码 |
| `cache_meta_array.sv` | 原有两路 tag/valid/LRU 与全失效，不添加无用 dirty |
| `cache_refill.sv` | `WORD_BYTES=DBUS_BYTES`；I$ 保持 4 B，不改变 RV64 取指规则 |
| `soc_info.sv` | 维护寄存器和只读能力查询，产生寄存后的全失效信号 |
| `soc_peripherals.sv`、`soc_top.sv` | 传递维护信号、参数与 CPU D 接口 |

I/D 分开保存状态，未把两种控制流程塞进一个大参数状态机。Package 未增加 function。
数据阵列不复位，只有 valid/LRU 与协议状态复位；实际 BRAM 推断仍需后续综合确认。

## 读写如何完成

Load 路径为 `IDLE → LOOKUP → RESPOND`，miss 则在中间进入 `FILL`。
接受沿读同步 RAM，随后比较 tag 并寄存结果。当前不支持连续每拍接受缓存请求。
旁路不经过 LOOKUP，允许旧响应与下一请求同沿交接。

Store 路径为 `IDLE → LOOKUP → STORE_SEND → STORE_WAIT → RESPOND`。
LOOKUP 保存是否命中以及命中 way，之后下传原 addr、size、wdata、wstrb。

写成功时，只有先前命中且没有经历失效，才按 byte strobe 更新那一个缓存字；
写错误时失效先前命中行。为什么不能保留它？外设/总线错误不保证写操作完全没有
副作用，物理内存可能部分改变，保留旧 Cache 会掩盖实际状态。

写响应消费才是完成；CPU 请求接受、AXI AW 接受、W 接受都不是完成。
`soc_top.dmem_store_fire` 仍只观察 CPU 请求接受，不是新的 DDR 写完成通知。

Cache 数据与错误响应必须保持到 CPU ready。共享端口的下层响应始终可接收，
旁路受反压时保存一份；阻塞的一笔在途保证缓冲不会被第二个响应覆盖。

## 填行错误与窄 Load

CPU 的 LB/LH/LW 可能被填行扩宽成 XLEN 读取。即使扩宽读失败，原来的窄读也
不一定失败。因此填行任一 beat 报错时，不安装该行，按原始请求仅回退一次。
只用回退响应决定数据或错误，不能把填行 size 或邻近地址当成原 CPU 故障访问。

单测同时覆盖了每个 beat 报错、原始读取也失败，以及“扩宽读取失败但 BYTE 读取
成功”。写请求永远不走填行回退路径，避免错误后重复写入产生第二次副作用。

## 维护寄存器为什么不需要 busy

系统寄存器基址 `0x10040000`，访问宽度为对齐 32 位：

| 偏移 | 意义 |
|---|---|
| `0x20` | 写 bit 0=1，全 D$ 失效；读恒 0 |
| `0x24` | bit 0 表示 D$ 已启用且 DDR 容量非零 |
| `0x28` | D$ 配置字节数，默认 4096 |
| `0x2c` | 缓存行字节数，默认 32 |

有效写掩码中的保留位非零报 SLVERR；零写掩码/写 0 不触发维护。
关闭 D$ 时维护命令仍可接受，效果为空操作。它不是标准 Zicbom 指令。

```text
T0：系统 MMIO 接受维护写，寄存维护信号，并产生可保持的写响应
T1：D$ 清 valid；CPU 最早在同一沿消费该写响应
T1 后：后续数据访问重新查找/填行
```

本 Core 的 D 端口只有一笔在途，维护写能走到 MMIO 时，较老 D$ 请求已经完成。
全体 valid 一拍清除，所以首版不需要多周期 busy/ack 协议。维护信号必须寄存，
不能把“这个 MMIO 请求握手”组合反馈给阻止该请求握手的 Cache invalidate。
响应被反压时脉冲也只发生一次。

模块自身仍防护任意时刻的 invalidate：全失效优先于安装，用粘滞 discard 禁止
旧填行或写命中恢复有效副本；已接受的请求继续排空并回应一次，不复位 FSM 丢响应。
未来写回、多核或独立维护主端口需要重新设计 busy/ack，不能直接继承此简化假设。

## DMA 的软件所有权约定

写穿透只解决 CPU 的已完成写入送到下层，不解决 DMA→CPU 的旧 Cache 副本。
DMA 不穿过 D$，也不自动修改其 tag/data；本次没有限制 DMA 的合法 DDR 地址范围，
没有建立地址别名或强制固定 uncached pool。

CPU→DMA：先完成源数据写入，做编译器/访存排序，再启动 DMA；工作期间不要修改
交接的缓存行。这里没有脏行，所以不需要 clean。

DMA→CPU：等 DONE 或 ERROR，再全失效 D$，然后才读目的区。ERROR 也需要维护，
因为前面已经完成的写不能假装回滚。维护影响整个 D$，不是仅一个缓冲区。
TCM 不缓存，不需要 D$ 维护；可以访问与 DMA 缓冲区不重叠的 CPU 私有区域。

```c
/* 等待 DMA 的 DONE/ERROR 后；实际项目还应检查状态、完成长度与故障地址。 */
__asm__ volatile("fence rw, rw" ::: "memory");
*(volatile uint32_t *)(uintptr_t)0x10040020u = 1;
__asm__ volatile("fence rw, rw" ::: "memory");
/* 现在才读取可能被 DMA 修改的 DDR 数据。 */
```

普通 FENCE 只排序；FENCE.I 维护指令视图，不替代 D$ 全失效。DMA 改代码后若既要
执行又要把它当数据读取，需要分别考虑 FENCE.I 和 D$ 维护。WT 模式的 CPU 自修改
代码已写到 DDR，FENCE.I 不需要先做 D$ clean。

## 验证与性能边界

`make cache-test XLEN=32/64` 每个位宽为 11 PASS、0 SKIP：I$/D$ 各四种配置，
I$ DDR 改码软件，以及 D$ 开/关的两组软件。D$ 单测检查数：

| 配置 | RV32 | RV64 |
|---|---:|---:|
| 128 B | 111 | 112 |
| 4 KiB | 111 | 112 |
| 关闭 D$ | 13 | 14 |
| 没有 DDR | 13 | 14 |

覆盖两路 LRU、所有合法宽度/byte lane、零 strobe、NWA、写延迟/错误、部分写副作用、
每个填行 beat 错误、安装沿失效、写响应沿失效、响应反压、旁路同拍交接和协调复位。
写下传载荷独立比对 CPU 原始请求，避免 Cache 与内存模型同时犯错却相互验证。

`dcache_smoke.c` 从真实 AXI DDR 读取、改写数据；检查 DMA 能看见 CPU 的 WT 写入，
DMA 修改预热目的区后通过 MMIO 刷新，以及 DMA 第二笔写报错时第一笔数据仍然可见。
轮询期间还访问独立 DDR 区域，与 DMA 争用下层端口。每个开启配置观察到 30 次
D$ 命中、2 次维护；关闭配置为 0 hit，仍执行两次空维护。

这个小程序开启 D$ 不一定更快：全行冷填充和维护后的重新填行会增加事务。
本版先保证协议正确，不承诺所有工作负载加速。Core/TCM CoreMark 成绩不退化也不能
证明 DDR Cache 的收益。独立 DDR CoreMark、I/D/DMA 三方持续压力、AXI burst、
更高命中吞吐、厂商综合和 FPGA 时序均留待后续。
