# SoC 系统与程序生命周期

## 结构

```text
Core 域：双发射 Core ── cpu_memory_adapter 请求队列 ── ITCM / DTCM BRAM
                         └─ I$ / D$ ── AXI CDC ─┐
SYS 域：系统 DMA ───────────────────────────────┼─ AXI fabric
                                               │   ├─ AXI CDC ── Core 域 TCM 辅助端口
                                               │   ├─ ROM / Flash 读取引擎
                                               │   ├─ AXI-Lite CDC ── 外设域 UART/Timer/GPIO/IRQ
                                               │   └─ AXI CDC ── DDR 域桥/控制器/PHY ── DDR3
```

当前生产顶层是 `soc_system.sv`：`cpu_memory_adapter` 保存 CPU 请求队列、存储路由、Cache 和响应归属，
`tcm_bram` 单独提供本地 RAM 端口。`scoreboard_soc_memory`（SSM）保留在旧接口和测试中，
不作为本轮生产总线。统一系统总线是 `axi_system_fabric`。Core 的本地命中无需经过 SYS 总线，
Cache miss、DMA、设备控制和外部主设备通过该总线。TCM 与 Cache 当前仍和 Core 同域。

| 时钟域 | 实际包含的逻辑 | 当前配置 |
|---|---|---:|
| Core | 取指/预测/译码、寄存器堆、IQ/scoreboard、执行/LSU、完成/退休；CPU 存储适配、ITCM/DTCM、I$/D$；CDC 的 Core 侧 | 100 MHz |
| SYS | AXI 仲裁与返回路由、DMA 搬运引擎、Boot ROM、Flash SPI 读取引擎；各桥的 SYS 侧 | 100 MHz |
| DDR-user | DDR AXI 桥和控制器用户接口；DDR PHY 内部还有其他时钟 | 125 MHz |
| 外设 | UART、Timer、GPIO、IRQ，以及 DMA/Flash 的控制寄存器 | 60 MHz |

SYS 是与 Core 并行工作的系统总线域，不包含整个 Core。综合按各域最差寄存器路径分别估计 Fmax，
因此 SYS 的估计值可以高于 Core。当前 main 采用 C6 的100/100/125/60 MHz目标；
YOLO 与 MiniMind 的专属硬件和时钟测量保存在对应分支。
增加 SYS 频率可能减少 DMA、Cache miss 的等待，但不会提高 Core 域自身的时序上限。

CoreMark 的三个硬件层次是 Core+TCM、SoC+TCM、SoC+Cache+DDR；它们表示接入哪些组件。
时钟域表示哪些寄存器由哪个时钟驱动，两种分类不能互换。CoreMark/MHz 均按 Core 计时区周期计算，
其他域的频率和后台流量通过等待周期影响分数；比较时同时记录各域时钟与存储配置。

当前 TCM 实验使用 `tcm_bram.sv`：ITCM、DTCM 各有两个字交错 bank，每个 bank 使用真正双端口 BRAM。
ITCM 主口固定给取指，DTCM 主口固定给数据口 0；另一物理口在其余客户端之间按 bank 轮询。
同 bank 的两个读可并行；同字且至少一个写时按轮换次序串行，RV32 的 64 位取指同时使用两 bank。
响应背压由各客户端的返回缓冲承接，CPU 读没有新增一级。旧 `tcm_dual_bank.sv` 保留供历史接口测试。

系统写仍经 AXI/CDC 接入辅助口。宽写的 WSTRB/WLAST 合法性每个 AXI beat 寄存一次，随后连续处理本地字；
B 响应等待实际写完成。每个本地字都加一拍的实验曾使 DMA 带宽下降约 30.4%，已撤出组合。
CPU 数据队列在已有入队边界保存静态 TCM/DDR 路由资格，运行时仍检查端口 ready、响应 owner 和 Cache 维护状态。

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
| 预留加速器 | 0x20000000 | main 未挂载；用途分支可映射 YOLO 或 MiniMind |
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

## 当前应用

M0 64 次 O3 为 3.590617/3.570731 CoreMark/MHz；本轮真实 TCM 64 次为 3.095736/3.081770。
两者的存储路径不同，分别记录。RT-Thread 不参加 CoreMark，程序主体在 DDR，热 trap 驻 ITCM。
短 CoreMark 仿真未满足正式十秒要求。

YOLO 使用已有 128-MAC 核，控制和数据请求通过 SYS/NPU FIFO 跨域，NPU 目标 100 MHz。
它在本轮是 AXI 从设备，CPU 配置计算和系统 DMA，DMA 负责读写其数据窗口。
O3 裸机程序已在双宽系统验证卷积、结果核对和 DMA 重叠；这组测试没有运行完整 YOLO 网络。
