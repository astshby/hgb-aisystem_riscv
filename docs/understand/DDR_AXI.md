# DDR 与 AXI 学习


## 1. 当前层次

```text
CPU I/D 的标量访问与 Cache 行 ─ 各自 cache_axi_adapter ─ CDC ─┐
DMA 双缓冲与头尾访问 ─────────── dma_axi_master ────────────┤
视频读 DMA（主端3）───────────────────────────────────────┘
                     axi_system_fabric
                         DDR 目标
                  sys 域 DDR 就绪准入门
                         AXI CDC
                    ddr_axi_target
                   pango_block_bridge
                    Pango DDR 原生口
```

互连其它目标为 ROM、TCM、MMIO、Flash、可选 NPU SRAM。DMA 不再从 CPU
访存适配器穿过；窄访问、宽 beat 和块传输汇入同一 AXI 主口。
legacy 仍使用 `ddr_block_fabric`、`ddr_port_arbiter`、`block_arbiter` 和旧桥，
不能把 legacy 的单事务限制套到新互连，也不能把新互连能力套到 DDR 后端。

## 2. 标准 AXI 合同和延迟

地址 32 位、数据 256 位、ID 4 位（主端 2 位、本地 2 位）。支持对齐 INCR、
1–4 beat，主端负责 4 KiB 拆分。五通道均有入口/目标 FIFO；AR/AW 译码独立
寄存。仲裁按目标轮转，读写分别进行，同 ID 在前笔响应交回入口缓冲后才复用。
被阻塞的选择锁定，载荷不能随新候选改变。

AW 与 W 独立握手。互连保存每主端目标序列、每目标 W owner/长度，不交错不同
owner 的 W。错误目标返回完整读帧，或排空 AWLEN+1 个 W 后返回一个 B。
软件可见写完成依据成功 B；错误路径同样受响应背压约束。

DDR 准入门在 sys 域保存 available 和 owner；DDR 未就绪时本地 DECERR，不依赖
DDR 时钟。正常流量各方向一个活动事务，读写可并行。队列能吸收后继请求，
不代表 DDR 后端增加了多个同时执行的命令。当前有周转等待，应按实测改进。

CDC 默认每通道深度 8，Gray 指针经两级同步，载荷不逐位同步。复位必须协调
两侧；物理 max-delay/bus-skew、亚稳态和时钟配置仍需 FPGA 阶段验证。

## 3. Pango 原生接口

`ddr_axi_target` 将标准 ID、长度、错误和背压映射到已有块协议，
`pango_block_bridge` 处理厂商原生 256 位口：

- 原生读没有 RREADY，桥预留整块缓冲，不能让下游背压丢掉读脉冲。
- 原生写没有标准 B/BRESP，桥根据写数据接受完成；不代表数据已持久化到颗粒。
- 支持命令接受同沿捕获读返回/消费写数据。
- 早/晚 LAST 等畸形返回排空后报告错误，继续请求不能串到上一 owner。
- 未校准准入检查、错误帧和外层 AXI 背压分别验证。

Pango DDR 用户接口为 125 MHz 配置，与 Core/SYS/外设分域。2026-10-30 无 NPU C6 完成
PDS 布线，DDR-user Fmax 122.5490 MHz、WNS −0.160 ns；仍有 PHY/I/O 时序问题，没有板上 DDR 结果。
共同 I/O 仿真通过真实 AXI CDC 接行为 DDR 后台，不使用 Pango PHY；离线封装桩也不模拟 DDR PHY。

## 4. Cache 和 DMA

Cache 行通过 `cache_axi_adapter` 的独立本地 ID 访问系统总线。32 B 行一拍外部
AXI 数据，内部安装仍逐 word；脏行先收集、写回成功才 clean，填充成功才安装。
失败回退和维护契约保持。命中路径在 core 域，不经过 CDC。

DMA 保留双 128 B 缓冲、读下一块/写上一块重叠、源/目的共同页界拆分、成功
前缀和错误排空。统一模式将宽块扩展到合法 TCM/Flash/DDR 路径，非对齐头尾
也从同一 AXI 主口发出。Flash 只作源，不接 UART FIFO。
启用 NPU 时，仅允许 32 位对齐的数据窗口：写 `0x20000060..68`、`0x20000100..180`，
读 `0x20000200..250`；结束地址为开区间，START/状态等控制寄存器不在许可内。
整网驱动当前仍逐寄存器装载，旧算子测试的 DMA 重叠不能当作整网 DMA 加速结果。

CPU 在 MMIO 下单，命令从 periph 整包送 sys；最终完成/错误/成功字节数整包
返回，BUSY 覆盖全过程。Cache 与 DMA 没有硬件一致性，CPU 必须执行维护。

## 5. 视频与共同 I/O 平台

视频控制为 SYS 域 AXI-Lite64，`axil_video_split` 将 `0x10070000` 的 4 KiB 区间送显示，
其余请求仍经原外设 CDC。AW/W 分别接收，静态路由和 B/R owner 保持到响应握手；
32 位 CPU 的高半字 lane、64 位相邻寄存器读取、响应反压均有定向测试。VIDEO=0 完全旁路新分流。

`video_frame_reader` 为主端3，XRGB8888 A/B 在 `0x83000000` / `0x83800000`，
每帧 8,294,400 B。四个本地 ID 各保存一组四拍响应，允许乱序返回、按原顺序送出双像素。
SYS→pixel 的 2048-word FIFO 保存像素、SOF 和 epoch；输出是 1920×1080、总光栅 2200×1125、148.5 MHz。
换帧/欠载时保留未握手 AR 载荷，已接受的旧 R 排空后才复用 ID，FIFO 不做单侧清零。

独立视频双宽仿真各核对 4 个健康完整帧，A/B CRC `b5f021b4` / `3e37611b`，
还检查跨 vblank 的在途请求、随机反压/乱序、黑像素和后续完整帧恢复。
共同平台 `tb/yolo/yolo_demo_io.sv` 接实际 fabric、DDR CDC、MMIO/UART、DMA、NPU 和显示，
DDR 为共享 128 MiB lazy 后台；短测核对真 UART 双向各 1024 字节、DDR 读写、DMA 64 B、NPU 小卷积和完整显示 CRC。
电脑执行 C 的两轮真实 UART/原视频驱动流程也通过；没有 CPU Cache，一致性维护回调不能计为硬件 Cache 一致性测试。

## 6. 测试与剩余工作

原双宽互连回归各 6 项场景，每项四主端完成 128 写/128 读，包含标准/原生 DDR、
同频/异频、深度 2/8、目标阻塞和持续 W。另各 2 项 CDC 复位/回绕与 1 项
DDR 原生目标测试；DDR 测试包含 11 个检查，覆盖时钟停止时拒绝、W 先于 AW、
长 R/B 反压、非法 burst、早/晚 LAST 和错误后复用，历史日志在 `logs/p2/unified-bus/final/`。

实际 RV32/RV64 Core 已执行生产卷积驱动的 3 个小卷积、171 输出和 5 个量化值；
416 全图 83 Conv 部件结果由电脑 C + 真实 NPU/AXI/CDC 取得；320 完整应用也已通过真实 UART 收图、
83 Conv、框/画框图回传和完整 1080p 扫描，最终回 READY。后者逐项核对 5,775,300 个 INT32 输出，
AXI、UART 帧、显示欠载、视频总线和 I2C 错误均为 0。C 在电脑执行，没有 Core、CPU Cache 或 Flash；DDR 为共享行为模型。
入口与收据见[项目介绍](../PROJECT_INTRO.md#环境与命令)。原完整 SoC 的 DMA/Cache 软件测试，
Flash→DDR→执行、4 KiB 拆分、非对齐尾部、成功前缀与故障地址回归继续保留。

后续分别测 M2 cold/warm、M2-B 并发带宽和等待，再评估 DDR owner 周转、Cache 安装/refill 和 SPI 连续读取。
当前没有真实 DDR 板级带宽、ECC 或硬件 Cache 一致性结果；新增视频与交互固件也尚未布线。
