# SoC 系统与程序生命周期

## 结构

```text
Core：双发射 Core → cpu_memory_adapter → ITCM / DTCM BRAM
                              └→ I$ / D$ → AXI CDC ─────────┐
SYS：系统 DMA（主端2）─────────────────────────────────────┼→ AXI fabric
     视频读 DMA（主端3，4个ID）─────────────────────────────┘     ├→ ROM / TCM / Flash
                                                              ├→ AXI CDC → DDR用户域 → DDR3
                                                              ├→ AXI CDC → NPU域
                                                              └→ AXI-Lite分流
                                                                   ├→ SYS视频控制
                                                                   └→ CDC → 外设UART/Timer/GPIO/IRQ
DDR像素 → SYS读回重排 → 2048字双像素异步FIFO → 148.5MHz扫描 → RGB/HS/VS/DE
外设域 → 400kHz I2C → MS7210；板级视频PPLL另由27MHz参考产生像素钟
```

当前生产顶层是 `soc_system.sv`：`cpu_memory_adapter` 保存 CPU 请求队列、存储路由、Cache 和响应归属，
`tcm_bram` 单独提供本地 RAM 端口。`scoreboard_soc_memory`（SSM）保留在旧接口和测试中，
不作为本轮生产总线。统一系统总线是 `axi_system_fabric`。Core 的本地命中无需经过 SYS 总线，
Cache miss、DMA、设备控制和外部主设备通过该总线。TCM 与 Cache 当前仍和 Core 同域。

| 时钟域 | 实际包含的逻辑 | C6 无 NPU目标 | C7 YOLO目标 |
|---|---|---:|---:|
| Core | 取指、双发射/执行/退休、存储适配、ITCM/DTCM、I$/D$、CDC 的 Core 侧 | 100 MHz | 90 MHz |
| SYS | AXI 仲裁/返回、系统 DMA、ROM、Flash 读取、视频读 DMA/控制、桥的 SYS 侧 | 100 MHz | 100 MHz |
| DDR-user | DDR AXI 桥和控制器用户接口；PHY 内部还有其它时钟 | 125 MHz | 125 MHz |
| 外设 | UART、Timer、GPIO、IRQ、DMA/Flash 控制寄存器、HDMI I2C | 60 MHz | 60 MHz |
| NPU | YOLO 计算、本地存储、目标接口及其 CDC 侧 | 无 | 100 MHz |
| 视频 | 双像素 FIFO 读端、1080p 扫描和输出寄存器 | 无 | 148.5 MHz |

系统 `pango_soc_pll` 使用一颗 GPLL 为 Core/SYS/外设/NPU 分频；DDR 保留控制器自己的 PLL。
视频另用 `pango_video_pll` 的 PPLL：27/1×2×33/12=148.5 MHz，不从外设钟直接分频。
视频失锁并入整机协调复位，SYS/外设/像素侧一起异步置位、各自同步释放；PPLL 自身只受板级复位控制。

SYS 与 Core 并行，SYS 不包含 Core、TCM 或 Cache。每域 Fmax 取本域最差路径，SYS 可以高于 Core。
2026-10-30 无 NPU C6 最终布线 Fmax 为 Core 87.3057、SYS 98.2415、DDR-user 122.5490、
外设 72.2201 MHz，0 未布通；配置目标仍为 100/100/125/60，Core/SYS/DDR 存在负 setup 裕量。
新增视频和交互固件未布线。提高 SYS 频率会改变 miss/DMA 等待拍数，不直接提高 Core 时序上限。

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
| 视频控制 | 0x10070000，4 KiB | SYS 域配置、COMMIT、FRONT/FRAMECOUNT/错误 |
| 可选加速器 | 0x20000000 | YOLO 或 MiniMind 控制窗口 |
| DDR | 0x80000000 起 | 大程序、模型、输入、输出 |

## 上电后程序在哪里

FPGA 配置 Flash 保存 bitstream。板上配置电路在上电后把它送入 FPGA 配置端口，
恢复逻辑、连线、BRAM 初始化内容；这一步不由 RISC-V 软件执行。
bitstream 可以包含 Boot ROM 与 TCM 初值。CPU 复位后从 ROM 跳到 ITCM 启动代码。
DDR 需先完成控制器/PHY 初始化；程序检查就绪、基本读写和镜像校验后才使用 DDR。

大程序与权重可保存在另一 Flash 分区，由 CPU 配置 Flash 控制器和 DMA 搬到 DDR。
当前 YOLO 固件检查预载 DDR 模型的 CRC、完整图和 NPU 后才发布；模型 UART 分块命令也可加载。
这条预载检查不代表 Flash→DDR 冷启动已实现，尚无板上约 5 MB 模型全传结果。
仿真也可直接预装 ITCM/DTCM/DDR，必须在结果中注明。Cache 初始有效位清零，
CPU 第一次访问 DDR 代码/数据时自动取行；无需“把整个程序写入 Cache”的指令。
程序主体始终有 DDR 后备存储，Cache 只保留最近使用的副本。

## DMA 的控制和结束

CPU 写源地址、目的地址、长度，再发启动；搬运方向由源/目的地址决定。DMA 独立发 AXI 读写，数据经内部
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

YOLO 使用已有 128-MAC 核，NPU 目标 100 MHz，控制/数据请求通过 SYS/NPU FIFO 跨域。
CPU 决定层次和分块；当前完整驱动逐寄存器装载权重/激活，再取回 INT32 结果，非卷积层由 C 执行。
系统 DMA 可访问受许可的数据窗口，不能代替 CPU 写 START 或调度整张网络。

截至 2026-10-30，真实 RV32/RV64 Core 各执行 3 个生产驱动小卷积、核对 171 输出和 5 个量化值。
完整 416 模型的 83 Conv/266 节点已由电脑 C + 真实 AXI/CDC/NPU RTL 执行，耗时 33 分 28.7 秒；
共同 I/O 平台进一步接真实 UART、DMA、DDR 行为模型和视频，两轮上传/回读及 A/B 完整帧 CRC 通过。
共同平台没有 RISC-V Core 或 CPU Cache，Core 90 MHz 只作为软件发现元数据，不产生 CoreMark 或 CPU 性能成绩。
320 模型完整应用联合仿真也已通过：真实 UART 收入 192×144 RGB，C 预处理到 320，
真实 NPU 执行 83 Conv，逐项核对 5,775,300 个 INT32 输出，返回 3 框和画框图，再完成 1080p 扫描并回 READY。
耗时 11,638.68 秒、峰值 RSS 78,476 KiB；第二次 DETECT 使用缓存结果，完整网络实际执行一次。
该运行没有 Core、CPU Cache 或 Flash，DDR 使用行为模型；没有完整 RV32 整网或板上 HDMI 结果。
构建记录的提交为 `6008bc5`；实际源文件已保存于 `a91c795`，逐文件 SHA256 与运行快照一致。
命令和哈希见 `logs/demo-software-20261029/yolo-full/app320-full-rtl-v2/result.json` 及同目录 `sourceidentity.json`。

| 演示 DDR 分区 | 容量/格式 | 所有权 |
|---|---|---|
| 图 `0x81000000` | 最大 1920×1080 RGB888 | 收图期间不可计算，整帧 CRC 成功后发布 |
| 模型 `0x82000000` | 16 MiB | 预载或 MODEL 命令写入，校验后只读 |
| 显示 A/B `0x83000000` / `0x83800000` | 各 8 MiB；1920×1080 XRGB8888，stride 7680 | CPU 只写 inactive，vblank 原子切换 |
| arena `0x84000000..0x88000000` | 64 MiB | 按 tensor last_use 释放并合并复用 |

共同 I/O 平台的 DDR 后台为 `0x80000000..0x88000000` 共 128 MiB，所有分区使用同一块内存。
扫描经真实 AXI/CDC 从 DDR 读回，最多 4 拍/128 B、不过 4 KiB，4 个 ID 回读后按发出顺序送像素 FIFO。
遇到欠载，本帧余下像素输出黑色并记录错误；换帧先排空旧 AXI owner，再重用 ID，不单侧复位 FIFO。
软件等待 COMMIT 完成、FRONT_BASE 确认且下一帧完成后才返回 READY。
证据位置见[项目介绍](../PROJECT_INTRO.md#环境与命令)。
