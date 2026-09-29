# 两路 I$：从请求接受到 FENCE.I 失效

> 版本说明：本文保留 S4 实现及验证记录。S5 已采用 WB/WA、异步维护状态和 FENCE.I 发布屏障；
> 当前软件交接与错误限制以 [S5 解读](S5_CACHE_WRITEBACK.md) 为准，不能照搬旧写穿透流程。

2026-09-29（Asia/Shanghai）。本轮交付既定 Cache 计划的 I$ 部分。
本文保留 I$ 首次交付时的时序说明；随后已加入 D$，当前数据路径与 DMA 规则见
[D$ 实现解读](DCACHE_IMPLEMENTATION.md)。写回、AXI burst、MMU、板级 DDR3 仍未实现。
设计取舍的完整背景见 [S4 Cache 设计](S4_CACHE_DESIGN.md)。

## 放在哪一层

```text
Core I → cache_port → I$ 或直接旁路 → fabric master 0 ┐
Core D ─────────────────────────→ fabric master 1 ├→ TCM / MMIO / DDR 本地端口
DMA ────────────────────────────→ fabric master 2 ┘
DDR 本地端口 → local_to_axi → AXI RAM 仿真模型 / 未来板级控制器
```

Cache 在 `vsrc/soc/cache/`，不放进六级流水。Core 唯一增加的输出是准确的
`fence_i_commit`；load-use、EX/MEM MDU 拼包、WB 等访存完成均不改变。
DMA 不经过 I$；CPU D 口现已接入 D$，不再是本文初次交付时的直连路径。

`soc_top` 参数为 `ICACHE_ENABLE=1`、`ICACHE_BYTES=4096`、
`ICACHE_LINE_BYTES=32`。默认 64 组、每组两路、每行 32 B：
32 位物理地址对应 tag 21 位、组号 6 位、行内偏移 5 位。
`DDR_BYTES=0` 仍表示没有外存，不能因启用 I$ 就访问不存在的 DDR。

## 五个文件怎样分工

| 文件 | 保存的状态与职责 |
|---|---|
| `cache_port.sv` | 原地址合法性、缓存/旁路选择、响应归属、旁路响应缓冲 |
| `cache_data_array.sv` | 两个独立的同步读 32 位 RAM way，不清零数据阵列 |
| `cache_meta_array.sv` | tag、valid、每组一位 LRU；失效优先于安装 |
| `cache_refill.sv` | 原请求快照、逐笔 4 B 填行、错误时仅一次原请求回退 |
| `icache.sv` | LOOKUP/FILL/RESPOND、victim 快照、粘滞 discard、I$ 响应 |

I$ 按指令字整字写入；共享数据阵列已为 D$ 增加 WORD_BYTES 和 byte mask，I$ 使用全掩码。
两种 Cache 都没有 dirty。
`discard_q` 放在 I$ 控制器，不在 refill 内；由它决定填行完成后是否允许安装。
这些模块名称表示职责，不代表 I/D 必须共用所有实现。

## 哪些请求可以命中

先调用现有 `address_decode` 检查完整 XLEN 地址、对齐、访问大小与执行权限，
然后才允许进入 tag 查找。必须同时满足：合法的只读取指、目标是已实现 DDR、
整条缓存行都位于该 DDR 范围内。

ROM、I-TCM 直接旁路；D-TCM/MMIO 取指仍返回原有权限错误。
RV64 高地址不截断成低 32 位以制造命中。最后不足一行的 DDR 空间也旁路，
保留原始地址和大小，不为填行跨越到未实现区域。

## ready / valid 分别承诺什么

- CPU `req_valid && req_ready`：I$ 或旁路接受一个请求，之后必须回应一次。
- 下层 `mem_req_valid && mem_req_ready`：互连接受一笔原请求或填行子请求，
  不代表数据已经回来。
- CPU `rsp_valid`：数据和错误已经可用；若 `rsp_ready=0`，必须稳定保持。
- 下层响应：`cache_port.mem_rsp_ready` 恒为 1。缓存路径由 refill 接收；
  旁路路径立即转交 CPU，CPU 反压时保存进一项缓冲。

为什么下层 ready 不跟着 CPU ready？原 SoC 就需要这个响应缓冲来切断
IF 反压、共享 bank、MEM ready 与重定向之间的组合反馈。此处是搬迁保留，
不是又在旧缓冲之外叠加一份。Core 每端口一笔在途，因此不会覆盖未消费响应。

接受时锁存通路归属，不能根据下一条请求的地址来选择旧响应。
旁路允许旧响应消费与下一请求接受同沿发生，不增加 TCM 空拍；
缓存路径首版不做这个重叠，便于查找和填行避开 RAM 读写冲突。

## 一次 hit 与 miss

对于 hit：

```text
T0 上升沿：接受请求，同步读取两路数据，进入 LOOKUP
T0 → T1 ：以同一请求的 tag 比较 valid/tag，选择命中 way
T1 上升沿：寄存响应，进入 RESPOND
T2 或以后：CPU ready 后消费响应，返回 IDLE
```

所以这不是每拍接收一条请求的高吞吐 I$。同步 RAM 与稳定响应是首版目标，
后续可以单独评估取消额外响应寄存、流水化 lookup 等优化，不能把它们当成已实现。

miss 先选择无效 way；两路都有效时选 LRU。被替换行先失效，再逐字写入，
整行成功后才写 tag/valid。两路只需一位精确 LRU：触碰 way 0 后 way 1 为候选，
触碰 way 1 后 way 0 为候选。

RV32 和 RV64 的取指子请求都固定 4 B，一行共 8 笔，不发 AXI burst。
RV64 下层返回 8 B，每笔用该子请求地址的 bit 2 选高/低指令字；
不能沿用原始 CPU 地址来选择所有填行响应。hit 时将指令放回原地址对应的
总线 lane，SoC 再提取 32 位指令。其他 lane 不作为该次取指的有效数据。

## 为什么填行错误还要再读一次

CPU 要的是地址 A 的指令，整行读取还访问 A 周围的地址。邻近字失败不能证明
A 本身取指失败。因此任意填行 beat 错误后：

1. 不安装该行，停止后续未发子请求。
2. 按原始 A、大小和 execute 属性向下层发一次请求。
3. 仅用这次响应决定 CPU 的数据或访问错误，不递归填行。

即使之前已经读到 A，也采用同一回退规则。半条成功的行始终无效，未来访问
会重新 miss。原请求地址由 Core 的 IF 包保留，错误不会把邻居地址替换成异常 PC。

## FENCE.I 为什么不直接 reset Cache

`fence_i_commit` 只来自无异常 FENCE.I 的退休。普通 FENCE 不触发它，普通
分支重定向也不整缓存失效。预测器清除和 I$ 失效复用这一个准确事件。

FENCE.I 同拍清所有 valid，并对正在处理的缓存请求设置粘滞 `discard_q`。
即使失效发生在最后一笔响应或安装那拍，也不能重新置 valid。
当前实现让剩余填行继续完成，然后仍向 IF 回应一次；IF 已将旧请求标记为 killed，
接收后丢弃。新请求等旧响应排空再进入缓存。

如果简单 reset 状态机，IF 会一直等待那笔已接受却永远不返回的请求。
因此“使缓存行无效”和“取消总线事务”是两件不同的事。系统 reset 则要求
Core、Cache、互连和从端协调复位；它不承诺撤销已经发生的外存写入。

## CPU/DMA 改代码的顺序

当前 D$ 为写穿透且无写缓冲，CPU Store 必须等下层完成；DMA 必须等 DONE。
随后执行 FENCE.I，再跳入新代码。DMA 不会自动更新 I$，普通 FENCE 也不是
invalidate API。软件要避免 DMA 写目标代码时 CPU 仍在执行或修改同一范围。

`tb/cache/icache_smoke.c` 真正将代码写到 DDR 并执行：

- 反复执行返回 37 的函数，预热 I$。
- 执行 DDR 内部的条件分支循环，验证热代码与控制流。
- CPU 把函数改成返回 43；普通 FENCE 后本实现仍读到缓存的 37，FENCE.I 后得到 43。
- DMA 再改成返回 59，等 DONE、FENCE.I 后得到 59。

“普通 FENCE 后仍为 37”是本实现的定向检查，不是所有 RISC-V 实现都必须观察旧值。
已加入的 D$ 使用独立 MMIO 全失效契约；如果 DMA 改写的代码还要通过数据口读取，
也要维护 D$，不能声称 FENCE.I 或写穿透天然解决 DMA 数据一致性。

## 验证入口与边界

```bash
make cache-test XLEN=32
make cache-test XLEN=64
```

以下是 I$ 首次交付的 4 个配置单测及 1 个 SoC C 程序；当前入口另含 D$ 测试，总计 11 PASS：

| 配置 | RV32 检查数 | RV64 检查数 |
|---|---:|---:|
| 128 B I$ | 59 | 60 |
| 默认 4 KiB I$ | 59 | 60 |
| I$ 关闭 | 10 | 11 |
| DDR 未启用 | 10 | 11 |

覆盖冷/热访问、LRU、所有指令字 lane、每个 beat 的错误及失效、安装同拍失效、
响应反压、保持响应时失效、旁路同拍交接、在途复位、区域尾部和 RV64 高地址。
SoC C 程序通过真实互连与单拍 AXI 桥，统计到每个位宽 99 次 hit、40 笔 DDR 取指、
4 次 FENCE.I。该统计属于固定小程序，不是一般性能结论。

双位宽完整回归仍包括 Core unit/directed、Core-only/SoC riscv-tests、C smoke、
CoreMark 两模式、SoC 外设与 DMA。具体结果记录在 [修改记录](../COMMIT.md)。
原 CoreMark 的 text/data 在 TCM，成绩不用于证明 I$ 加速。尚未进行 DDR CoreMark、
厂商综合、BRAM 映射或 FPGA 时序/上板验证。
