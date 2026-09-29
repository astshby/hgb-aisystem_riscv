# Core、BRAM 与 Cache 握手说明

本文解释 Core 与指令/数据存储器之间的请求、响应和流水线停顿。当前 `sim_imem`、`sim_dmem` 模拟同步存储器；SoC 已把同一组接口接到阻塞式 I$/D$。
二者的响应延迟不同，ready/valid 的所有权规则相同。

## Ready/Valid 基本规则

每个通道都由发送方提供 `valid`，接收方提供 `ready`：

```text
fire = valid && ready
```

只有时钟上升沿出现 `fire`，一次传输才完成。

- `valid=1`：发送方提供的内容有效。
- `ready=1`：接收方当前可以接收。
- `valid=1, ready=0`：响应方必须保持 `valid` 和 payload 不变；请求方在仍发出
  同一请求期间保持载荷。Core IF 允许在未被接受前因重定向撤回请求，不能直接当 AXI 主端口。
- `ready=1, valid=0`：接收方空闲，但当前没有数据。

`ready` 不表示数据已经返回。例如 `imem_req_ready=1` 只表示存储器接受了 PC，
真正的指令由之后的 `imem_rsp_valid` 表示。

## 请求与响应通道

```text
Core                              Memory/Cache
 req_valid + req_addr  --------->
            req_ready  <---------

            rsp_valid  <---------
 rsp_ready             --------->
            rsp_data   <---------
```

请求和响应可以发生在不同周期。当前仿真 BRAM 在请求握手后的下一周期产生响应，
并用一个响应寄存器保存数据：

```systemverilog
req_ready = !rsp_valid || rsp_ready;
```

响应槽为空时可以接受请求；旧响应将在本周期被接收时，也可以同拍接受下一笔请求。

## IF 与 IMEM

`if_stage` 保存三类状态：

- `pc_q`：下一次请求的 PC。
- `request_q`：已经被 IMEM 接受、正在等待响应的 PC 和预测 metadata。
- `buffer_q`：响应已经回来，但 D1 暂时不能接收的指令。

正常命中时序：

```text
周期 N：   imem_req_valid && imem_req_ready，保存 request_q
周期 N+1：imem_rsp_valid && imem_rsp_ready，指令直通 D1 或进入 buffer_q
```

`out_ready` 是 D1 接收 IF 输出的能力，`imem_rsp_ready` 是 IF 接收 IMEM 响应的能力。
D1 暂停而 `buffer_q` 为空时，IF 仍可保存一个响应；buffer 满后必须拉低
`imem_rsp_ready`。

redirect 会使 buffer 中的旧路径指令失效。已经接受但尚未返回的请求无法取消，
`request_killed_q` 因此记录它；迟到响应仍完成握手，但不会进入 D1。I-Cache miss
只会延长该等待，不改变 kill 原则。

## MEM、WB 与 DMEM

MEM 负责地址、Store 字节通道和请求握手。Load 请求被接受后，PC、rd、地址低位、
访问宽度等 metadata 进入 `MEM/WB`，数据由 WB 接收：

```text
周期 N：   Load 位于 MEM，dmem_req fire
周期 N+1：Load 位于 WB，dmem_rsp fire，完成扩展、写回和 WB 前递
```

一拍命中不需要无条件停顿。紧随 Load 的相关指令在 D2 停一拍，随后在 EX 使用 WB
前递：

```text
        N       N+1       N+2
Load    EX      MEM       WB
use     D2      bubble    EX（WB forward）
```

两种等待必须区分：

- `mem_request_stall`：请求尚未被 DMEM/Cache 接受，`EX/MEM` 保持请求内容。
- `wb_wait`：Load/Store 请求已接受但响应未返回，`MEM/WB` 保存 metadata，顺序流水线等待。

D-Cache hit 仍需同步数据 RAM 与 LOOKUP；miss 还要执行 refill，通过
`wb_wait` 延长等待。Store 现在也在 WB 等待一次完成响应；请求被接收只表示
从端取得事务，不能提前宣称写入完成。两种响应均可携带错误，WB 会补充精确异常，
禁止年轻 MEM 发请求，并抑制错误 Load 写回。

FENCE 排空旧访存再恢复顺序执行；FENCE.I 额外丢弃旧取指和旧预测。
取指错误随 IF 请求 PC 传播；被重定向杀死的取指响应即使报错也不能进入 Trap。
详细地址、宽度、错误与复位契约见 [SoC 访存契约](../SOC_BUS_CONTRACT.md)。


## 同名 ready 不能混用

| 信号 | 谁给出 | 谁使用 | 真正表示 |
|---|---|---|---|
| imem_req_ready | 指令存储器/I$ | IF | 当前 PC 请求在本沿可被接受 |
| imem_rsp_valid | 指令存储器/I$ | IF | 已接受的那笔请求有返回值 |
| out_ready | D1/流水线控制 | IF | IF 的输出包现在能进入 IF/D1 寄存器 |
| imem_rsp_ready | IF | 指令存储器/I$ | IF 能消费返回；D1 暂停时可能先放入 buffer |
| dmem_req_ready | 数据存储器/D$ | MEM | 当前 Load/Store 请求可被接受 |
| issue_enable | Core 的流水线控制 | MEM | 老 WB 未阻止此 MEM 指令发访存请求 |
| request_stall | MEM | 流水线控制 | 访存请求有效，但还没有被接受 |
| dmem_rsp_valid | 数据存储器/D$ | WB | 当前最老 Load/Store 的读值或写完成返回 |
| wb_wait | WB | 流水线控制 | 需要 D 响应，但此时还没有返回 |

这里的 issue_enable 不是 load-use 冒险的别名。load-use 由 hazard_unit 看 D2 消费者与 EX Load 的寄存器依赖，在 D2 插入一个 bubble。issue_enable 防止老 WB 等待或重定向时，年轻 MEM 发出无法撤回的外部请求。WB 在等待中持有 metadata，阻止更年轻的访存越过它；这与是否有 load-use 依赖是两个判断。

## 对照两种存储器的时间线

以 MEM 的 Load 在 E0 接受请求为例。sim_dmem/tcm_controller 是同步读、单响应槽：E0 把地址送入 RAM 并锁存响应，E0 后 rsp_valid 可见，WB 最早 E1 消费。E0 进入 MEM/WB 的只有 PC、rd、访问宽度、有效地址等元数据；返回值由 WB 按原地址 lane 和有符号/无符号指令解释。Store 同样要等一次写响应，E0 只说明设备接手。

阻塞 D$ 命中多一个查找过程：E0 同步读 tag/data，E1 查命中并把返回包寄存，E1 后 rsp_valid 有效，WB 最早 E2 消费。缺失则先读完整 32 B 行；脏 victim 先写回，再 refill。等待多久由实际响应决定，不用预置固定的“每个 Load 停一拍”。前述单 bubble 仅解决紧邻 load-use 在操作数尚未可前递时的相关性；缓存等待由 wb_wait 继续保持流水。

同样区分 IF 的两种等待：imem_req_valid && !imem_req_ready 表示 PC 还没有被存储器接受；请求已接受但 imem_rsp_valid 尚未到达时，request_q 记住原 PC 与预测快照。返回后若 D1 不能接收，buffer_q 保存 packet。即使此时 out_ready=0，已保存的 out_packet 仍必须稳定，不能因未被消费就随意清零。

## 反压期间的责任

请求尚未接受时，发送方保持地址和载荷。IF 是例外：重定向可撤回未被接受的旧路径请求；互连和 AXI 桥需要识别这一边界。请求一旦握手，IF 只能给 request_killed_q 记标志；旧响应仍须回来并完成握手，随后丢弃。分支预测失败是控制流修正，不会把旧取指请求当机器异常。

响应 valid 已经出现但 ready=0 时，接收方还没消费；发送方要保持 payload 和 error。sim_imem/sim_dmem 的响应寄存器保存它，if_stage 的 buffer_q 保存不能进 D1 的指令；SoC cache_port 旁路在 IF 反压时保存一个响应，同时向互连提供恒为 1 的下层 rsp_ready，避免 I-rsp-ready 经共享 bank 反向影响 D-ready。这个缓冲的前提是 Core 每端口至多一笔在途；它不能代替多事务 ID。

错误响应也必须遵守保持和归属。IF 已杀死的旧请求即使得到错误，也不能生成新路径 Trap；WB 把当前合法 Load/Store 的错误响应转换为 access fault，未获得响应前不能写 GPR 或错误地提交 Store。响应消费与新请求同沿交接是否支持，取决于各模块实现；TCM/旁路支持，阻塞 Cache 命中路径没有每拍接收新请求的保证。

## FENCE、维护和复位放在哪里

Core 在 D1 发现需序列化的 FENCE/FENCE.I，停止新取指，等旧流水包到 WB。普通 FENCE 只完成已有的请求/响应排序，不强制写回 S5 的 D$ 脏行。FENCE.I 退休时，I$ 与预测状态失效；SoC 阻止新取指，并等待 D$ clean 结束。自动 clean 出错时持续停取指，直到复位。一个软件维护命令经 MMIO 入队后必须先释放那笔 D 请求，再借同一 D 主端口逐行写回；若用命令写响应等待 clean 全完成，会占住唯一端口而无法发出写回。

同步 RAM 的存储内容通常不因复位清零，valid/在途控制状态则复位。D$ 的 dirty 也会清零，因此断电或全局复位前若需保留已退休 Store 的新数据，必须先完成 flush。已经向 AXI 发出的请求，复位时需要桥和外部模型协调处理；单独清 Core 的 valid 位不会让从端自动撤销写入。

## 实际怎么看波形

先选择一条请求，记录请求握手沿 E0 的地址和 size，然后只跟这一笔的响应 owner。针对 I 口观察 pc_q、request_q.valid、request_killed_q、buffer_q.valid、imem_rsp_valid 和 out_ready；针对 D 口观察 ex_mem_q、dmem_req_valid/ready、mem_wb_q、wb_wait、dmem_rsp_valid/ready。若是 RV64 上半字访问，再核对 wstrb 或取指 lane 是否来自 E0 地址。若是 Cache miss，观察 refill 读了多少 beat、tag/dirty 在哪拍安装、失败时有没有再次下传原请求。

tb_if_stage 覆盖 redirect 和响应 buffer，tb_mem_stage/tb_wb_stage 检查请求和返回责任；tb_core_load_pipeline、tb_core_bus_contract 检查连续 Load、load-use、错误与年轻请求阻断。SoC 的 tb_soc_fabric 检查共享 bank 的 owner 与反压；tb_icache、tb_dcache_wb 和 C 改码/DMA 测试检查缓存缺失、维护和故障。先在 RV32 看同一字的字节通道，再在 RV64 看高 32 位 lane，容易发现只在一种位宽出现的错取指。

## FPGA Cache 结构

FPGA 可以综合真实 Cache：Data array 通常放在 BRAM，Tag、valid、dirty 可放在 BRAM
或 LUTRAM，控制器负责比较、替换和 refill。

```text
请求 → 读取 Tag/Data
          ├─ hit  → 下一拍响应
          └─ miss → 选择 victim → 必要时写回 → 下级存储器读取 → 填充 → 响应
```

Cache miss 表示 Tag 不匹配，不是地址越界；refill 仍需要 DDR、AXI RAM 或其他下级
存储器。当前接口适合第一版阻塞式 Cache。若允许多个未完成 miss，则还需要
transaction ID、MSHR 和新的顺序提交设计。

## 波形检查要点

- 未被接受的同一请求保持地址与 payload；IF 重定向撤回不等于取消已接受事务。
- `rsp_valid && !rsp_ready` 时，响应数据必须保持。
- IF redirect 后，旧响应可以 fire，但不能生成有效 `out_packet`。
- 普通 Load hit 后的无关指令应连续推进；load-use 只产生必要的一个 bubble。
- 读写响应等待时保持 `MEM/WB`，不得重复发送同一请求。
