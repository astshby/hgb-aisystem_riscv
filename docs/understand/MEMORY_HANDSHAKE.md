# Core、BRAM 与 Cache 握手说明

本文解释 Core 与指令/数据存储器之间的请求、响应和流水线停顿。当前
`sim_imem`、`sim_dmem` 模拟同步一拍 BRAM；未来阻塞式 I/D Cache 可复用同一组
接口。

## Ready/Valid 基本规则

每个通道都由发送方提供 `valid`，接收方提供 `ready`：

```text
fire = valid && ready
```

只有时钟上升沿出现 `fire`，一次传输才完成。

- `valid=1`：发送方提供的内容有效。
- `ready=1`：接收方当前可以接收。
- `valid=1, ready=0`：发送方必须保持 `valid` 和 payload 不变。
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
- `wb_wait`：Load 请求已接受但响应未返回，`MEM/WB` 保存 metadata，顺序流水线等待。

D-Cache hit 可在 Load 到达 WB 时给出响应；miss 则先接受请求并执行 refill，通过
`wb_wait` 延长等待。当前 Store 在请求被接受后进入 WB，不等待返回数据，因此 Cache
在拉高 `req_ready` 后必须负责保存并最终完成写请求。未来若需要总线错误或精确 Store
异常，应增加 completion/ack 或 Store buffer。

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

- `req_valid && !req_ready` 时，请求地址和 payload 必须保持。
- `rsp_valid && !rsp_ready` 时，响应数据必须保持。
- IF redirect 后，旧响应可以 fire，但不能生成有效 `out_packet`。
- 普通 Load hit 后的无关指令应连续推进；load-use 只产生必要的一个 bubble。
- miss 时应保持 `MEM/WB` 中的 Load，不得重复发送同一请求。
