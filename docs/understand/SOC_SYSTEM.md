# SoC 系统学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。本文是当前实现的摘要，细节以源码和对应测试为准。

## 1. 从 Core 到 SoC 的层次

`CORE_BACKEND=scoreboard` 选择新双发射 Core 与 `scoreboard_soc_memory`：
IF64、D0/D1、DMA 分别持有事务；两块 64 KiB TCM 各用两个交错 bank，
TCM 响应反压存入客户端缓冲，其他客户端仍可访问 RAM。原生 I$ 命中 II=1，
两个 D$ bank 按缓存行分区并共享外部 DDR 带宽。D$ 总容量和软件维护契约保留，
维护命令须等待两个 bank 完成。测试与当前边界见 [双发射学习](DUAL_ISSUE.md)。
`LOCAL_TCM_ENABLE` 仅选择 legacy 的两种接线；新后端固定使用上述原生 bank 路由。
`555453f` 起，D0/D1 在 SoC 地址解码前各有两项请求缓冲，ready 只依赖寄存容量，
每笔请求增加一拍，稳态各口仍可每拍接受。已接纳的取消读继续外发并排空，
标签由 LSQ 保持；Store/MMIO 的队头授权在进入缓冲之前完成。

下面的单 D 口框图与 local0/local1 时序说明保留为 legacy 控制组说明。

```text
Core I 口 ── I$ / uncached ── I router ─┐
Core D 口 ── D$ / uncached ── D router ─┼─ 热路：local TCM fabric ─ ITCM / DTCM
DMA 窄口 ──────────────────── DMA router ┘
                    各 router 的慢口
                           ↓
                  主端事务寄存槽
                           ↓
                  shared per-target fabric
                  ├─ ROM / error slave
                  ├─ 每个设备请求槽 → MMIO 响应寄存器
                  └─ DDR 请求寄存槽 → DDR 仲裁/桥
DMA 256 位块口 ─────────────────────────────┘
```

- `vsrc/core/`：可移植 Core。
- `vsrc/pkg/`：类型、地址、配置、总线包。
- `vsrc/soc/`：Cache、总线、TCM、ROM、DMA、外设。
- `vsrc/cpu/`：FPGA wrapper、Pango DDR 桥。
- `vsrc/sim_cpu/`：仿真存储模型。

三主端 I/D/DMA 可以同时访问不同目标。每个目标有 owner，同一目标同一时间只接一笔。
主端 ready 不能组合穿透到另一个主端。

## 2. 总线契约

`bus_types_pkg::bus_req_t` 包含地址、读写、大小、写数据、strobe、execute 等字段；
`bus_rsp_t` 包含读数据、错误码、响应。关键规则：

1. `valid && ready` 是接受沿；接受后的请求归下游 owner，不能靠清 valid 撤销。
2. 响应必须按接受时的 owner 返回，不能按当前地址猜。
3. 已展示的 valid 在反压时保持载荷。
4. 错误分为 BUS_OK、BUS_DECERR、BUS_SLVERR；未映射窗口返回 DECERR，权限/大小
   错误返回 SLVERR。
5. Cache 维护、FENCE.I、DMA 和普通访问对同一地址的所有权必须分开处理。

详细接口见 `vsrc/pkg/bus_types_pkg.sv`、`vsrc/soc/bus/bus_interconnect.sv`、
`vsrc/soc/common/bus_transaction_register.sv`。

## 3. 地址与存储

- ITCM：64 KiB，`soc_addr_pkg::ITCM_BASE`，同步读、byte 写。
- DTCM：64 KiB，`soc_addr_pkg::DTCM_BASE`。
- Boot ROM、错误从机、UART/Timer/GPIO/DMA/系统信息等 MMIO。
- DDR：`soc_addr_pkg::DDR_BASE`，容量由 `DDR_BYTES` 参数决定。
- `address_decode` 并行产生互斥窗口命中，保留完整范围、对齐、写权限、MMIO
  word-only 和未映射错误优先级。

`LOCAL_TCM_ENABLE=1` 时，合法 TCM 请求走 hot 路，不经过慢 fabric；`0` 时 TCM
也在慢 fabric 后。两种接线共用同一份物理 TCM RAM。热路仍有本主端 owner 和响应 FF，
不是 1 拍专用口。

## 4. Cache

- I$：2 路、4 KiB、32 B 行，只缓存合法 DDR 取指；TCM/ROM/MMIO 旁路。
- D$：2 路、4 KiB、32 B 行，WB/WA；只覆盖 DDR，MMIO/TCM 旁路。
- 命中路径是 IDLE→LOOKUP→RESPOND；load 命中 II=3，store 命中多一拍。
- miss 先探测 victim，脏行完整写回后才填行；填行成功才安装。
- 填行/写回可走 256 位块口（`CACHE_BLOCK_ENABLE=1`），但 RAM 仍逐 word 写。
- FENCE.I：I$ 失效、D$ clean、旧取指响应排空；维护失败停取指。
- DMA 与 CPU 的数据所有权靠软件 clean/flush/invalidate，不靠硬件一致性。

## 5. 外设与中断

- UART0/1：TX busy 时写返回 SLVERR，RX 只有一字节缓冲，满时 overrun。
- Timer0：mtime/mtimecmp 和机器软件中断；Timer1：通用计数器。
- GPIO0/1/2：32 位输入/输出/输出使能。
- DMA：legacy 单描述符逐字搬运；block engine 用两槽 128 B 和 256 位口。
- IRQ：`irq_controller` 的 pending/in-service/enable/threshold；`irq_register`
  把设备中断同步一拍后送 Core。
- MMIO 端点：请求先寄存，SEND 才执行副作用，WAIT_RESPONSE 消费后回 IDLE。

## 6. 软件测试栈

- `benchmark/`：CoreMark port、裸机 runtime、链接脚本。
- `tb/`：unit、directed、riscv-tests adapter、SoC benchmark。
- `scripts/verilator/`：runner、模型构建、镜像生成。
- RT-Thread v5.2.2：UART loader、TCM/DDR 布局、DMA 热代码搬运。
- 判定：tohost/console 或 Store 成功响应 + 同 ID 正常退休；不能看到请求就宣告 PASS。

## 7. 修改时先查什么

1. 地址常量、目标编码、互连 `PRESENT`、`soc_top`/`soc_peripherals` 连线。
2. 一笔请求的 `req_fire`、`rsp_fire`、旧响应 owner、错误地址、复位处置。
3. Cache 与 DMA 的 clean/flush/invalidate 顺序。
4. FENCE.I 在 miss、写回、维护中的到达时机。
5. RV32 和 RV64 都跑；共享 RTL 不能只测一个宽度。

## 8. 当前边界

- 没有硬件 Cache 一致性；DMA 需要软件维护。
- 没有 MSHR、hit-under-miss、store buffer、early restart。
- 没有异步 CDC；SoC 和 DDR 用户口仍同为 125 MHz 域。
- 没有真实 DDR 颗粒、板上 UART/ILA 或功耗测量。
