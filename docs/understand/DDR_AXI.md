# DDR 与 AXI 学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。当前 scoreboard SoC 使用统一 AXI4；legacy 旧通路保留供回归。

## 1. 当前层次

```text
CPU I/D 的标量访问与 Cache 行 ─ 各自 cache_axi_adapter ─ CDC ─┐
DMA 双缓冲与头尾访问 ─────────── dma_axi_master ────────────┤
可选外部主端 ─────────────────────────────────────────────┘
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

2026-10-30条件候选保持AXI请求/响应和TCM访问拍数：仅系统TCM开启`REGISTER_LOCAL_ADDR`，
在原AR/AW接纳、局部响应和beat完成边沿更新读写游标；其他AXI标量目标默认保留原行为。
TCM系统入口直接用本地窗口/权限译码，BRAM先逐客户端比较同字写冲突，再由独热grant选冲突位，
CPU专口、辅助轮询、双读与写碰撞串行语义不变。SYS控制桥沿原AW接纳预存合法WSTRB mask，
W阶段继续逐拍检查WLAST和错误并排空突发。双宽TCM26项、SYS2项对照通过，未删除CDC/FIFO边界。
比较范围为有效握手与合法载荷；末W之后的无效游标和错误响应未定义RDATA可能不同，错误码及禁止BRAM访问保持一致。

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

Pango wrapper 仍共用 125 MHz 用户时钟；真实 DDR PHY、独立复位启动和管脚
未在本轮验证。元数据桩的离线展开不能代替 IP 行为或 PDS。

## 4. Cache 和 DMA

Cache 行通过 `cache_axi_adapter` 的独立本地 ID 访问系统总线。32 B 行一拍外部
AXI 数据，内部安装仍逐 word；脏行先收集、写回成功才 clean，填充成功才安装。
失败回退和维护契约保持。命中路径在 core 域，不经过 CDC。

DMA 保留双 128 B 缓冲、读下一块/写上一块重叠、源/目的共同页界拆分、成功
前缀和错误排空。统一模式将宽块扩展到合法 TCM/Flash/DDR 路径，非对齐头尾
也从同一 AXI 主口发出。Flash 只作源，当前没有外设 FIFO 或 NPU SRAM 搬运。

CPU 在 MMIO 下单，命令从 periph 整包送 sys；最终完成/错误/成功字节数整包
返回，BUSY 覆盖全过程。Cache 与 DMA 没有硬件一致性，CPU 必须执行维护。

## 5. 测试与剩余工作

双宽各 6 项互连场景，每项四主端完成 128 写/128 读，包含标准/原生 DDR、
同频/异频、深度 2/8、目标阻塞和持续 W。另各 2 项 CDC 复位/回绕与 1 项
DDR 原生目标测试；DDR 测试包含 11 个检查，覆盖时钟停止时拒绝、W 先于 AW、
长 R/B 反压、非法 burst、早/晚 LAST 和错误后复用。

完整 SoC 软件通过实际 CPU 指令操作 DMA/Cache，含 Flash→DDR→执行、
4 KiB 拆分、非对齐尾部、成功前缀与故障地址。测试入口见 [SoC 系统](SOC_SYSTEM.md)。
旧 Cache/块桥/外设回归继续保留。日志与 manifest 在 `logs/p2/unified-bus/final/`。

后续按 M2 数据评估：SPI 连续读取减少重复头部、TCM 系统宽口、DDR owner 周转、
Cache 安装和 refill 等待。M2 cold/warm、M2-B 并发带宽和等待须独立测量；
当前没有真实 DDR 板级带宽、ECC 或硬件 Cache 一致性结果；综合域内估计另列。
