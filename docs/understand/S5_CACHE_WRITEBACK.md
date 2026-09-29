# S5：从写穿透升级为写回/写分配

2026-09-29（Asia/Shanghai）。两仓在 `s5/cache-up` 开发；`s4/cache` 保存已验收基线。
本篇解释当前实现，旧 [WT/NWA 解读](DCACHE_IMPLEMENTATION.md) 保留历史设计，不再作为 S5 软件接口。

## 这次改变的到底是什么

Core 仍是 IF/D1/D2/EX/MEM/WB，load-use、MDU 和精确同步异常的位置没有改变。
变化发生在 Core 数据接口下方：原来 Store 等 DDR 真正写完，现在可以由 D$ 接管最新值，
在更新缓存之后回答成功。因此“Store 退休”不再等于“DDR 已经更新”。

| 请求/状态 | 当前行为 | 下层事务 |
|---|---|---|
| Load hit | 返回对齐 XLEN 字，原 WB 负责选择和扩展 | 无 |
| Store hit | 按 wstrb 合并字节，置 dirty，再回答 CPU | 无 |
| Load miss，干净 victim | 填完整行，全部成功才安装 | RV32 8 读 / RV64 4 读 |
| Store miss，干净 victim | 填完整行，再合并原 Store，置 dirty | 同上，不直接写 DDR |
| 任意 miss，脏 victim | 先写回全部旧行，再进行缺失处理 | 8/4 写，再 8/4 读 |
| TCM/MMIO、非法访问、DDR 尾部不足整行 | 保留原访问检查和旁路 | 原请求一次 |

默认仍是两路、4 KiB、32 B 行、64 组、一位精确 LRU、阻塞式、单事务。
脏位不表示数据错误，而是“缓存比 DDR 新，替换前有保存责任”。无效行不能是有效脏行。
写分配读的是整行，所以只写一个字节也能保住其余字节；不是用零填充邻近数据。
零 strobe 的缓存 Store 无副作用，不分配、不置脏。

## 模块分工与同步 RAM

| 文件 | 职责 |
|---|---|
| `pkg/cache_pkg.sv` | 维护操作及错误枚举；没有 function |
| `cache_port.sv` | 可缓存性检查、响应归属、旁路缓冲、维护端口占用 |
| `dcache_meta_array.sv` | tag/valid/dirty/LRU 与扫描 probe |
| `cache_data_array.sv` | 同步读、字节写的数据阵列，复位不清数据 RAM |
| `cache_refill.sv` | 按顺序读一行，支持一次原始 Load 请求回退 |
| `cache_writeback.sv` | 从同步 RAM 读 victim，每字发写请求并等真实响应 |
| `dcache.sv` | CPU 请求、victim 保存、分配、字节合并及全局维护状态机 |
| `cache_maintenance_controller.sv` | 软件命令与 FENCE.I 的归属、排队、状态及停取指 |
| `dcache_wt.sv` | 原 S4 策略的回归参考；S5 SoC 不实例化它 |

写回路径是 `READ → CAPTURE → SEND → WAIT_RESPONSE`：READ 沿启动同步 RAM，
CAPTURE 沿保存读数，SEND 在 req_ready=0 时保持地址、数据和 strobe，随后等写响应。
这里没有假设组合读 BRAM，也没有把“下层接受请求”误当“写入成功”。
每次只一笔子事务，当前 AXI 桥仍是单 beat；写回整行不等于已经支持 AXI burst。

端口有两个维护信号：pending 阻止新 CPU 请求插队，但不能改变旧响应归属；
active 则表示旧 CPU 响应已经排空，维护正式借用 D 主端口。若仅用一个信号立即切路，
很容易把尚未消费的 MMIO/TCM 响应送错对象。测试专门在旧响应反压期间排队维护。

## 为什么维护需要命令和完成状态

系统 MMIO 基址 `0x10040000`，详细位定义见 [寄存器契约](../SOC_PERIPHERALS.md)。

- `+0x20` 写 1=invalidate、2=clean、3=flush，0 为 NOP。
- `+0x24` 当前有效 WB D$ 返回 3：bit 0 启用，bit 1 写回。
- `+0x30` 为 busy/error/fatal/错误码；`+0x34` 为真实故障物理地址。
- clean 发布脏行后保留 valid；flush 发布成功后失效；invalidate 拒绝丢弃脏行。

MMIO 写响应仅确认入队。不能把这个响应一直扣到写回完成：它会占住自己正要借用的
D 主端口，让写回永远发不出去。正确流程是命令入队、释放原事务、等待端口排空、扫描维护。
软件仍须读状态确认 busy=0 且 error=0；当前阻塞实现也可能把状态读反压到维护结束。
坏从端一直不响应时，软件轮询次数不能解决总线本身的永久等待。

本轮没有逐行地址维护，仅全缓存扫描。出错前已经清理/失效的行可以保留效果，
不承诺整个命令原子回滚；出错的脏行仍可重试。新软件命令清除旧错误记录，
自动 FENCE.I 不清历史错误。fatal 只能由协调复位解除。

## DMA：交接所有权，而不是只等 DONE

DMA 直接访问物理 DDR，既不查询也不更新 D$；AXI4 不自动带来一致性。

```text
CPU 生产数据 → clean/flush 并确认成功 → DMA 读取
CPU 交出目的区 → flush 并确认成功 → DMA 写入 → DONE 或 ERROR
              → invalidate 并确认成功 → CPU 再读取
```

如果 CPU 脏行没有提前 flush，DMA 先写了新结果，后来 CPU 的旧脏行被逐出，
就可能把 DMA 结果覆盖回去。事后执行 clean 并不能修复这一错误顺序。
invalidate 遇到 dirty 返回错误，正是为了不悄悄丢弃 CPU 数据，也不擅自覆盖 DMA 数据。
即使 DMA 返回 ERROR，之前成功的写也已发生，仍然需要按部分完成结果做维护。

DMA 在途时不能访问交接的行；当前全局 invalidate 还要求避免产生无关 DDR 脏行。
本阶段例程使用 TCM 代码、栈和控制变量，DMA 期间只访问独立的干净只读 DDR 区。
将来把栈/堆放进 DDR 时，应补逐行维护或受控 uncached buffer，而不是照搬全局流程。
测试辅助代码在 `tb/cache/cache_maintenance.h`，不是正式操作系统 DMA API。

## FENCE.I：先发布 D$，再允许新取指

Core 原有序列化会排空较老指令并清年轻指令，WB 输出准确的 `fence_i_commit`。
SoC 在这个事件同拍失效 I$，同时阻止任何新 I 请求被接受；D$ 全 clean 完成才恢复取指。
在途旧 I 请求仍排空，I$ 的 discard 阻止旧 refill 再安装，IF 丢弃已取消的响应。
因此即使 FENCE.I 已经退休，后继代码也不会在脏代码发布前进入执行。

普通 FENCE 只保证顺序，不自动 clean 或 invalidate；FENCE.I 也不是 DMA 数据 invalidate。
DMA 改码需先完成正确的目的区交接，等 DONE/ERROR 后维护数据视图，再 FENCE.I。
本实现是单 hart；没有远端 hart 指令同步或多核一致性。

## 错误为什么不能照搬写穿透

- 读 refill 错误：不安装部分行，回退一次原地址/size 的 Load；它的结果决定当前异常。
- 写分配读错误：不安装部分行，只回退一次原 Store，以真实写响应决定成功/异常。
- 脏 victim 写错：保留原 valid/dirty/data，停止未发出的 beat。已写的 beat 不回滚。
  当前触发替换的 Load/Store 收到错误；SoC 状态保存真正写坏的 victim beat 地址。
  这不是追溯较早 Store 的精确异常，后者已经退休，现有流水没有这种能力。
- 手动 clean/flush 写错：状态报错，可重试；不永久停取指。
- FENCE.I 自动 clean 写错：fatal，保持停取指直到复位，不能继续执行潜在旧代码。
  这属于当前 fail-stop 限制，不是已实现机器检查 Trap；CPU 此时不能运行软件错误处理器。

复位会丢 valid/dirty，即使数据 RAM 本体没清空也不能再找回所有已退休 Store。
需要保存数据时必须先成功 flush，并协调 Core、互连、桥和从端复位。

## 验证与未承诺的能力

`make cache-test XLEN=32` 和 `XLEN=64` 各 18 PASS、0 SKIP：
I$/S4 WT D$/S5 WB D$ 各四配置，维护控制器 ACTIVE 开/关两配置，
DDR I$ 改码、FENCE.I 写回失败、WB D$ 开/关的 DMA 软件共四项。
WB 单测启用配置分别执行 411/356 项检查，使用独立字节记分板、混合冲突访问、
每个逐出/维护 beat 错误及重试、分配回退、反压、复位、非法地址和区域尾部检查。
软件观测到 clean 前 DMA 仍读旧 DDR，clean 后取得新数据，而不只检查 CPU 自己的命中值。

完整整核/ISA/外设/CoreMark 回归结果记录于 [变更记录](../COMMIT.md)。
现有 CoreMark 是 TCM/Core-only 基线，不证明 WB 对 DDR 工作集有性能提升。
尚未验证真实 DDR3/FPGA 时序、DDR CoreMark、长时间随机三主争用、AXI burst、非阻塞 cache、
逐行 CMO、MMU、ECC、硬件 DMA 一致性或自动机器检查错误恢复。
