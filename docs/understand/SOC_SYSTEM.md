# SoC 系统与程序生命周期

all联合入口soc_all_system同时连接YOLO和MiniMind：YOLO0x20000000/64KiB，MiniMind0x20010000/4KiB；
PLIC原1–7号不变，两个原生sticky done/error状态经各自输出和两级同步作为8/9号源。控制与数据沿现有
AXI CDC包装跨域，原算子数学/RAM不改。MiniMind DDR主端与可选视频主端按独立读/写owner公平轮询后
接现有第四主口，CPU两主口和DMA不变，全局ID宽度不增加。此拓扑只做联合仿真；旧单NPU入口仍用于
各自小测试，不应把保存全源码或单核二选一误写成双核功能已经通过。


## 结构

```text
Core 域：双发射 Core ── SSM 本地请求队列/双 bank 仲裁 ── ITCM / DTCM
                         └─ I$ / D$ ── AXI CDC ─┐
SYS 域：系统 DMA ───────────────────────────────┼─ AXI fabric
加速域：选定加速器 ── 请求/响应 CDC ─────────────┤   ├─ TCM 系统端口
                                               │   ├─ ROM / Flash 控制
                                               │   ├─ AXI-Lite CDC ── 外设域 UART/Timer/GPIO/IRQ
                                               │   └─ AXI CDC ── DDR 域桥/控制器/PHY ── DDR3
```

SSM 是 `scoreboard_soc_memory` 的简称，负责 Core 侧存储路由、TCM、Cache 和响应归属。
统一系统总线是 `axi_system_fabric`。两个模块职责不同：Core 的本地命中无需经过系统总线，
Cache miss、DMA、设备控制和外部主设备通过系统总线。TCM 与 Cache 当前仍和 Core 同域。

| 区域 | 地址 | 启动/运行用途 |
|---|---|---|
| Boot ROM | 0x00000000 | 固定复位入口，跳转到 ITCM |
| ITCM | 0x01000000，64 KiB | 启动、小程序、频繁中断代码 |
| DTCM | 0x01100000，64 KiB | 热数据、异常栈、装载暂存 |
| CLINT | 0x02000000 | mtime/mtimecmp/软件中断 |
| UART/Timer/GPIO | 0x10000000 起 | 低速 MMIO，具体偏移见 `soc_addr_pkg` |
| IRQ 控制 | 0x0c000000 | 中断挂起、许可与领取 |
| DMA 控制 | 0x10030000 | 源/目的/长度/状态 |
| SoC 信息/Cache 维护 | 0x10040000 | 容量、时钟发现、DMA 所有权维护 |
| Flash 控制 | 0x10050000 | Flash 命令和数据访问 |
| 可选加速器 | 0x20000000 | YOLO 或 MiniMind 控制窗口 |
| DDR | 0x80000000 起 | 大程序、模型、输入、输出 |

## 上电后程序在哪里

FPGA 配置 Flash 保存 bitstream。板上配置电路在上电后把它送入 FPGA 配置端口，
恢复逻辑、连线、BRAM 初始化内容；这一步不由 RISC-V 软件执行。
bitstream 可以包含 Boot ROM 与 TCM 初值。CPU 复位后从 ROM 跳到 ITCM 启动代码。
DDR 需先完成控制器/PHY 初始化；程序检查就绪、基本读写和镜像校验后才使用 DDR。

大程序与权重可保存在另一 Flash 分区，由 CPU 配置 Flash 控制器和 DMA 搬到 DDR。
仿真也可直接预装 ITCM/DTCM/DDR，必须在结果中注明。Cache 初始有效位清零，
CPU 第一次访问 DDR 代码/数据时自动取行；无需“把整个程序写入 Cache”的指令。
程序主体始终有 DDR 后备存储，Cache 只保留最近使用的副本。

## DMA 的控制和结束

CPU 写源地址、目的地址、长度、方向，再发启动。DMA 独立发 AXI 读写，数据经内部
双槽缓冲，可边读下一块边写上一块。它可访问获准的 TCM、DDR 和设备数据窗口；
地址许可由总线目标和设备适配器核对，不自动获得所有 MMIO 控制权限。
DMA 用状态/错误寄存器和既有 IRQ 通知 CPU；软件确认最后响应、检查错误，再交还缓冲区。
NPU 完成与 DMA 完成分别处理，数据搬完不等于计算结束。

CPU 写回缓存中的数据交给 DMA/NPU 读取前，先 clean；DMA/NPU 写完再交给 CPU 读取前，
按缓冲区所有权 invalidate。可用不缓存 TCM 或专用缓冲区减少维护成本，但不能省略所有权规则。

## 延迟和吞吐

AXI 的 valid 表示有请求，ready 表示本拍可接收；只有两者同时为 1 才转移所有权。
请求接受后保留目的、ID 和响应 owner，背压时保持载荷。请求队列、返回缓冲与 CDC FIFO
切断长组合路径，并允许容量未满时持续接收。优化优先消除重复译码和空拍，
不直接删除必要寄存边界。CoreMark、DMA 持续带宽、错误/取消排空和综合频率分别检查。

## 两种可选加速器

YOLO 使用 128-MAC 卷积核，CPU 配置，DMA 搬权重/激活及输出数据，独立第五域 100 MHz。
本轮通过两个卷积及实际 MAC 与 DDR DMA 重叠测试，尚未完成完整 YOLOX 网络。
MiniMind 保留原作者整数运行库和算子，控制经 SYS→NPU CDC；算子读写通过 NPU→SYS
AXI 主口访问共享 DDR。38 命令单层与参考一致，完整八层/多 Token 尚待验证。
两者使用替代配置，不同时实例化，关闭加速器的 main 保留通用总线接口。
