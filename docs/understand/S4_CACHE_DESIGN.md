# S4 Cache：Astra 复核与最简实现设计

> 版本说明：本文保留 S4 实现及验证记录。S5 已采用 WB/WA、异步维护状态和 FENCE.I 发布屏障；
> 当前软件交接与错误限制以 [S5 解读](S5_CACHE_WRITEBACK.md) 为准，不能照搬旧写穿透流程。

> 2026-09-28（Asia/Shanghai）初始设计；2026-09-29 更新实施状态：
> 两路 I$/D$ 已实现并接入 SoC；D$ 采用 WT/NWA 与 MMIO 全失效。
> DMA 数据采用显式维护方案，不限制为固定 uncached pool。见 [D$ 实现解读](DCACHE_IMPLEMENTATION.md)。
> 实际模块、时序和验收见 [I$ 实现解读](ICACHE_IMPLEMENTATION.md)。
> 审核基线：rhbyv `b30d8bc`、hgb `f714fba`，两仓均在 `s4/cache`。
> Astra 独立只读审核后，结合现有总线、流水与测试代码形成以下方案。

## CPU 整体审核后的前置门槛

本轮按用户要求扩展为加入 SoC 前的 CPU 全路径审核，并对比当前 S0/S2 接口变化。
详见 [CPU 整体审核](CORE_ASTRA_REVIEW.md)：已复现 IRQ 撤销丢指令、MINSTRET 读取顺序、
RV32 MINSTRET 半宽写三项功能问题。常规回归通过不等于这些问题不存在。

2026-09-29：三项问题已完成独立修复和六分支双位宽回归，见
[修复与验证记录](CPU_IRQ_COUNTER_FIX.md)。该前置门槛已关闭；I$ 阵列和协议单元可按下述设计继续实施。
维持 IF→D1→D2→EX→MEM→WB，不前移 Load/load-use、不改变 MDU 的 EX 发射/MEM 拼包。
保留 S0 错误响应、Store 完成和 FENCE 行为，不回退到旧提交。
MINSTRET 修复前，Cache 请求/命中/缺失统计采用 TB 被动计数，不用有偏差的 CSR 证明 IPC。

## 首版选择与交付顺序

先独立实现并验收 I$，再加入 D$。两者均采用物理地址、两路组相联、阻塞式访问，
建议每个 Cache 为 4 KiB：64 组 × 2 路 × 32 B/行。该容量是仿真起点，不代表
已确认的 FPGA BRAM 占用或时序结果。每个 Cache 同时只处理一个 CPU 请求；
I/D 两侧可各自存在一次 miss，仍由既有互连仲裁。

D$ 首版使用写穿透（write-through）和写缺失不分配（no-write-allocate），
不设 Store buffer，也不提前确认写入。元数据只有 tag、valid 和每组一位 LRU；
没有脏行，不需要为了未来写回而加入恒为零的 dirty 状态。

后续先评估 AXI burst 和命中吞吐，再考虑写分配、写回。写回要求独立设计脏行
逐出、缓存维护、DMA 交接和延迟写错误，不能作为首版的一个简单参数开关。

## 接入位置：缓存 DDR，直接旁路 TCM/MMIO

```text
CPU I → I$ / 原请求旁路 → fabric master 0 ┐
CPU D → D$ / 原请求旁路 → fabric master 1 ├→ 原互连 → ROM / TCM / MMIO / 外存桥
DMA ──────────────────→ fabric master 2 ┘
```

Cache 位于 CPU 主端口之前，DMA 不穿过 CPU D$。ROM、TCM、MMIO 与指定的
uncached DDR 范围直接旁路。旁路请求不能额外经过 LOOKUP 状态；接受请求时记录
响应属于哪条通路，不能用下一条请求的地址选择旧响应。验证时同时检查单次延迟与
连续请求吞吐，保留 S3 已有的 TCM 时序。

[`soc_top.sv`](../../vsrc/soc/soc_top.sv) 的 I 响应旁路/保持缓冲负责切断组合反压环。
[`bus_interconnect.sv`](../../vsrc/soc/bus/bus_interconnect.sv) 和同步 TCM 的 ready 链
已有对应约束；I$ 接入后不能把 IF 的 rsp_ready 直接传回共享 fabric。refill 的响应
接收由寄存状态决定；非缓存 I 响应继续保留现有的旁路与保持能力。

缓存命中会绕过 fabric，必须在命中前复用
[`address_decode.sv`](../../vsrc/soc/bus/address_decode.sv) 对原始请求的校验。
只有完整 XLEN 地址合法、目标为 DDR、权限与对齐正确，才允许进入缓存命中判断。
不得先截断 RV64 地址再比较 tag。完整缓存行跨越 DDR 容量或缓存属性边界时，
该访问按原地址和大小旁路；不允许填行读入 MMIO 或未实现空间。

## 数组、命中与两路替换

32 位物理地址在上述配置下分为 21 位 tag、6 位组索引和5位行内偏移。
查找同一组的两个 way：`valid && tag_equal` 才是命中。优先选择无效 way；
两路均有效时由一位精确 LRU 选择被替换行。两路不需要复杂的伪 LRU 树。

数据阵列按同步读 RAM 编写，每个 way 独立读出；用于比较的请求元数据必须和
读数据对应同一次访问。tag、valid 与 LRU 先使用触发器，数据 RAM 不整体复位。
Store 更新和下一次 lookup 避开未定义的同地址读写冲突，不能依赖特定厂商 RAM
的隐含行为。BRAM 是否被正确推断须后续综合确认。

I$ 存储和返回 32 位指令。现有地址检查和
[`local_to_axi.sv`](../../vsrc/soc/bus/local_to_axi.sv) 都要求取指使用 MEM_WORD；
所以 RV32/RV64 的 I$ 填行均先用 4 B 请求，32 B 行共8笔。RV64 返回总线仍为
8 B，必须根据这次已接受子请求的地址取高/低32位，不能沿用原始 CPU 请求的 lane。
D$ 按 XLEN 宽数据字组织，填行分别为8笔 RV32 或4笔 RV64 请求；返回完整总线字，
由现有 Load 单元完成字节选择和符号扩展。

所有子请求首版复用 single-beat local bus / AXI 桥，逐笔接受、逐笔完成。
每次接受的 CPU 请求只能返回一次响应，响应被反压时保持数据和错误不变。
不对新接受请求产生同拍即消失的响应：IF 请求槽及 WB 访存包在接受沿之后才生效。
Cache 同步 RAM hit 至少跨一个时钟沿；旁路也必须沿用原有可保持的响应契约。

首版控制可按以下状态职责组织，不把旁路请求强行串入查找状态：

| 路径 | 顺序与持有内容 |
|---|---|
| 可缓存读 | 接受并保存原请求 → 同步阵列查找 → 命中响应，或选择无效 victim/替换行 |
| 读 miss | 发一笔填行子请求 → 等其响应 → 写入无效 victim → 下一笔；全成功才安装 |
| 填行失败 | 停止未发子请求 → 原请求旁路一次 → 返回真实 demand 数据/错误 |
| D$ Store | 查找并记命中 way → 原请求下传 → 等写完成 → 成功更新/错误失效 → CPU 响应 |
| 非缓存 | 原请求直接旁路；锁存通路归属至完成，保留原 TCM 延迟与吞吐 |
| 维护 | 同拍清 valid，阻止旧填行安装；排空已接受子事务及原 CPU 响应后释放 |

已接受的请求描述必须稳定保存到完成，至少包括原地址、访问大小、write/execute、
写数据/掩码，以及命中/被替换的组和 way。填行地址和原请求故障地址独立保存。
不在首版加入多请求队列、MSHR 或 store buffer；保留 Cache 开关用于旁路对照。

## FENCE.I 与在途取指

Core 已有准确事件：

```systemverilog
commit_valid && !commit_exception &&
(commit_packet.uop.sys_op == SYS_FENCE_I)
```

已将它命名为 `fence_i_commit` 并从 Core 导出，预测器清除也复用此事件。
不重新译码 commit trace，也不从 REDIR_FENCE 推断，因为普通 FENCE 与 FENCE.I
共用这个重定向原因。各 wrapper 和直接实例化 Core 的 TB 需补齐该端口。

首版全部 valid 可同拍清零，因而不要求新增 WB 维护等待协议；后续取指由 Cache
的 ready 控制，直到旧事务排空和失效完成。具体优先级如下：

- 失效优先于 refill 安装；尤其最后一个响应与失效同拍时不能重新置 valid。
- 在途 refill 设置粘滞 discard 标记，失效前开始的填行不得随后成为有效行。
- 已被下游接受的事务必须接收响应；未发出的剩余填行可以停止。
- 已经接受的 CPU Fetch 仍须获得一次响应，让 IF 消费并释放被杀请求槽。
  不能简单复位 Cache FSM，使 IF 永远等不到旧响应。
- 普通分支重定向由 IF 丢弃错误路径响应；它不等同于整缓存失效。

当前 IF 的 `request_killed_q` 行为见
[`if_stage.sv`](../../vsrc/core/frontend/if_stage.sv)。FENCE.I 的软件语义是让本 hart
后续取指看到先前可见的代码写入，参考官方 [Zifencei 规范](https://docs.riscv.org/reference/isa/unpriv/zifencei.html)。
写穿透且无写缓冲时，旧 Store 已等到下层响应；以后加入写回 D$，还必须处理尚未
到达取指可见位置的脏代码，届时重新审核维护协议。

## 填行错误与精确异常

整行读取包含原始指令未要求的字节。不能把任意填行 beat 的错误直接归给当前
Load/Fetch；RV64 的窄 Load 被扩宽填行后报错，也不能证明原窄访问一定失败。

首版采用一次回退方案：填行只写无效 victim，完整成功后才安装 tag/valid。
任一 beat 失败则整行保持无效，停止后续未发请求，再按 CPU 的原始 addr、size、
execute 属性发一次 uncached demand。仅这次响应决定返回数据或 access fault。
回退最多一次，不递归进入填行。该策略仅用于普通 DDR RAM；MMIO 始终旁路。

错误路径上的 Fetch 即使最后失败，也仍由 IF 的 kill 机制丢弃；有效 Load/Store
的错误继续在 WB 转为精确异常，不能把行基址或失败邻居的地址替代原始 mtval。

## D$ 写穿透的完成边界

[`wb_stage.sv`](../../vsrc/core/writeback/wb_stage.sv) 要求 Load/Store 等真实响应。
Store hit 时保存命中 way 和原请求，向下游发送原地址、size、数据和 byte strobe：

1. 等最终写响应成功，再按 byte enable 更新该缓存字，随后向 CPU 返回成功。
2. 写错误则失效该命中行并返回错误；不能继续使用可能与外存不一致的旧行。
3. Store miss 直接下传，成功后也不分配缓存行，不触发读填充。

请求被接受、AW 握手、W 握手都不是写完成。错误不承诺回滚外部已发生的副作用。
`soc_top.dmem_store_fire` 仍是被动请求观察信号，不是 DDR 写完成通知。

## DMA：D$ 阶段必须明确的软件契约

写穿透保证已完成的 CPU 写入送到下层，但 DMA 写入不会自动更新 D$ 的旧副本。
DMA DONE/IRQ 也不等于缓存失效。首版 I$ 验收阶段保留 D 通路原状；DMA 写代码
需先完成，再执行 FENCE.I，并避免 CPU 同时执行或修改该范围。

对后续 D$ 首版，原设计讨论的最少硬件选项：数据共享使用 TCM 或固定、整行对齐的
uncached DDR pool。它是现有 DDR 内一个明确物理范围，不建立 cached/uncached
地址别名；具体 pool 范围由配置与软件布局共同定义。CPU 与 DMA 按缓冲区所有权
交接，DMA 工作时 CPU 不访问交接的缓存行。

这会收窄启用 D$ 后可直接复用的 DMA 软件用法，必须公开说明。S3 的 DMA engine
仍允许合法 DDR 地址，不应悄悄增加拒绝条件。如果要在首版 D$ 中继续支持 DMA
更新任意已缓存 DDR 数据，必须同时增加显式 D$ 全失效操作：等 DONE 或 ERROR
后完成失效，才能消费结果；部分失败写入也要覆盖，旧 refill 不得在维护后安装。
普通 FENCE 只按排序使用，不把它暗中作为可移植的 Cache invalidate API。

后续写回策略还要求 CPU→DMA 交接前 clean。clean、invalidate 和 flush 的区别可见
官方 [CMO 规范](https://docs.riscv.org/reference/isa/unpriv/cmo.html)。当前没有实现 Zicbom。

当前选择显式全失效方案，系统寄存器 `0x10040020` 写 1；具体时序、约束和测试见
[D$ 实现解读](DCACHE_IMPLEMENTATION.md)。上面的 uncached pool 是保留的设计选项，并未实现。

## 拟议文件职责

新增 RTL 归入 `vsrc/soc/cache/`，不把 Cache 状态机放进 Core 流水：

| 文件 | 职责 |
|---|---|
| `cache_port.sv` | 缓存/旁路选择、原请求校验、响应归属和外部请求复用 |
| `cache_data_array.sv` | 同步数据 RAM 与逐字节写使能 |
| `cache_meta_array.sv` | tag、valid、两路 LRU 与全失效 |
| `cache_refill.sv` | 单笔子事务、填行进度、失败回退与 discard |
| `icache.sv` | I$ 请求、查找、取指字节通道与 FENCE.I 边界 |
| `dcache.sv` | D$ Load 与 WT/NWA Store；在 I$ 验收后新增 |

边界以实现时实际复用价值为准，避免为一个常量增加空壳模块，也避免把 I/D 所有
行为塞进多参数巨型 FSM。Package 只放常量、枚举和结构体，不放 function。
修改 `soc_top.sv` 做连接；Core 只导出 FENCE.I 事件，六级结构和 load-use 位置不变。

## 验收顺序与真实 Cache 覆盖

| 步骤 | 交付 | 核心验收 |
|---|---|---|
| 前置修复 | IRQ 撤销与 MINSTRET 三项问题 | 定向复现改为 PASS，双位宽 Core/ISA 回归 |
| S4-A | 属性/旁路、同步阵列、I$ 单元 | 冷 miss、热 hit、两路冲突/LRU、RV64 lane、所有填行 beat 错误 |
| S4-B | I$ 接入 SoC 与 FENCE.I | 真正 DDR 循环取指、自修改旧代码、在途及末拍失效、错误路径排空 |
| S4-C | WT/NWA D$ 与明确 DMA 契约 | Load/Store hit/miss、所有 byte lane、延迟/错误写响应、DMA 数据交接 |
| S4-D | Cache/DDR 软件和完整回归 | I/D/DMA 竞争、开关行为一致、冷热访问统计、独立 DDR CoreMark |
| 后续 | burst、吞吐、WA/WB | 每次升级单独验证排序、错误、维护与一致性 |

原 [`link_soc.ld`](../../benchmark/bsp/link_soc.ld) 将代码/数据放在 I/D-TCM，原
soc-coremark 通过只证明旁路回归。新增 DDR 链接与镜像装载路径后，必须证明被测
text/data 位于 cacheable DDR，并实际统计外存请求减少；不能只看软件 PASS。
现有 DMA 软件只首次执行新写入的两条 DDR 指令，需新增“先执行旧函数、DMA 改写、
FENCE.I、再执行新函数”的覆盖。D$ DMA 用例必须包括目的区已预热的情况。

两种 XLEN 均运行规定 Core/unit/directed、riscv-tests、C smoke、CoreMark 与 SoC
回归；Cache 新测试另外覆盖响应反压、每接受一次只响应一次、复位、DDR 禁用、
RV64 高地址、非整行边界、缓存属性边界和 TCM 原时序。保留缓存开关配置作为对照。
FPGA 综合、BRAM 映射、时序和上板仍属后续工作，不计入本轮设计审核的测试结果。

## 初次审核时的变更（历史记录）

本次仅修改 hgb 的审核/设计文档及索引/记录，未修改 RTL、正式 TB、脚本或地址表。
已重跑双位宽 Core 与 ISA 回归，并运行临时诊断；具体 PASS/SKIP 和发现的失败见
[CPU 审核记录](CORE_ASTRA_REVIEW.md)。Cache 尚无 RTL，因此本文件的 Cache 验收项
均是实施计划，不是已经通过的测试。没有执行提交、推送、综合或上板。
