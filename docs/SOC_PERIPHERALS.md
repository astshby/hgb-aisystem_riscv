# SoC 与外设接口

## 实现范围与层次

`soc_top` 组合 Core、复位 ROM、两个 64 KiB TCM bank、互连和
`soc_peripherals`。Core 保持六级，不包含 BRAM 或 MMIO 设备。
外设采用可移植 RTL，尚未完成厂商综合、资源/时序检查和板级连接。
DMA 已实现；外存仅有可配置的本地端口和仿真 AXI RAM，尚无板级 DDR 控制器。
DDR 两路 I$/D$ 已接入，MMIO/TCM 保持旁路。
MMU、S/U 模式、WFI 不在本版范围；Cache 契约见 [访存接口](SOC_BUS_CONTRACT.md)。

地址、权限和错误契约见 [SoC 访存契约](SOC_BUS_CONTRACT.md)。
普通 MMIO 仅接受对齐 32 位访问，包括 RV64；不自动拆分有副作用的 LD/SD。
寄存器偏移未实现、只读寄存器写入或格式错误返回 SLVERR。
写掩码按字节生效，读写副作用仅发生在请求接受沿，响应反压不重复执行。

## 存储器与互连

ROM 从地址 0 跳转到 I-TCM `0x01000000`，不包含镜像下载器。
benchmark 的代码放 I-TCM，数据、栈和 tohost 放 D-TCM `0x01100000`。
I/D 访问同一个物理 bank，D-TCM 不可执行；专用 ISA 链接脚本将自修改代码的
`.data` 也放进可执行 I-TCM，因此 SoC runner 可运行上游 `fence_i`。

互连在 SoC 中支持 CPU I、CPU D 与 DMA 三主端口。CPU 顶层使用 `DATA_PRIORITY=1`：
同 bank 优先数据请求，跨 owner 交接隔一拍；不同 bank 并行，同 owner 可每拍传输。
这是为了让 D-ready 不依赖可撤回的 I-valid；CPU D 与 DMA 对同一 bank 轮流获得机会，
避免持续数据访问让 DMA 饥饿。
SoC 另有一项 I 响应缓冲：正常响应直接旁路，IF 反压时保存，互连 I-rsp-ready 恒为 1。
Core 每端口一笔在途保证该缓冲不会被覆盖；它切断共享 bank 的组合反压环，不增加正常取指延迟。
全系统复位统一清除在途状态，RAM 不清零。

## Timer0：机器时间与软件中断

基址 `0x02000000`。MTIME 每个系统时钟增加 1；不是独立的实时时钟域。
MTIME/MTIMECMP 支持 RV64 对齐 64 位访问，也支持 RV32/RV64 的两个 32 位半字。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `0x0000` | MSIP | 32 位，bit 0 置位/清除软件中断 |
| `0x4000/0x4004` | MTIMECMP | 64 位比较值，复位全 1 |
| `0xbff8/0xbffc` | MTIME | 64 位时间，复位 0，可写 |

`MTIME >= MTIMECMP` 产生 MTIP。写 MTIME 的当拍不自增。
RV32 安全写比较值：先写高半字全 1，再写低半字，最后写真实高半字；
读取时间使用 high-low-high 重读。CSR `time/timeh` 别名尚未实现。

## Timer1：通用计数器

基址 `0x10010000`，所有寄存器 32 位。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `0x00` | COUNT | 可读写当前计数 |
| `0x04` | LIMIT | 终点，复位全 1 |
| `0x08` | CONTROL | bit 0 enable、1 periodic、2 IRQ enable |
| `0x0c` | STATUS | bit 0 sticky pending，写 1 清除 |

enable 时每拍计数，当前 COUNT 达到 LIMIT 的沿触发事件并归零。
从 0 起算周期为 LIMIT+1 拍；one-shot 同时清 enable。
新事件与软件清除同拍时，事件优先，不丢中断。

## UART0/1

基址分别为 `0x10000000`、`0x10001000`。
8N1、无流控/奇偶校验/FIFO，各自仅一字节接收缓冲。
RX 使用两级同步并在位中点采样；TX/RX 均用系统时钟计数使能，不产生派生时钟。
DIV 最小 4，TX/RX 启动一帧时分别锁存分频值；波特率约为 CLOCK_HZ / DIV。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `0x00` | TXDATA | 写低 8 位发送；忙时写返回 SLVERR |
| `0x04` | RXDATA | 读出并消费一个字节；空读为 0；不可写 |
| `0x08` | STATUS | bit 0 TX-ready、1 RX-valid、2 overrun、3 frame-error；2/3 写 1 清除 |
| `0x0c` | DIV | 可写分频，复位由 UART_DIVISOR 参数决定 |
| `0x10` | IRQ_ENABLE | bit 0 RX-valid、1 TX-ready、2 error 的电平中断使能 |

接收溢出保留尚未读取的旧字符并置 overrun。
RX 读接受与新字符到达同拍时，可同时返回旧字符并保存新字符。
仅凭数字环回测试不能证明板级波特率容差、CDC 约束或电气连接合格。

## GPIO0/1/2

基址 `0x10020000/0x10021000/0x10022000`，每组 32 位独立 IO。
顶层暴露 input/output/output-enable，具体 IOBUF 留在板级 wrapper。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `0x00` | INPUT | 两级同步输入，只读 |
| `0x04` | OUTPUT | 输出值 |
| `0x08` | OUTPUT_ENABLE | 各位输出使能 |
| `0x0c` | IRQ_ENABLE | 各位中断使能 |
| `0x10/0x14` | RISE/FALL_ENABLE | 上升/下降沿检测使能 |
| `0x18` | PENDING | 边沿锁存，写 1 清除，新边沿优先 |

同步器适用于独立电平或慢速 GPIO，不提供多位总线一致性或窄脉冲捕获保证。

## 外部中断汇聚

基址 `0x0c000000`，七个电平源：ID 1/2 为 UART0/1，3 为 Timer1，4/5/6 为 GPIO0/1/2，7 为 DMA。
使用常见单上下文 claim/complete 布局，但这是精简控制器，不宣称完整 PLIC 兼容。
它没有多 hart、多上下文或可配置触发模式；本实现 claim 与 IRQ 共用阈值筛选。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `4 × ID` | PRIORITY[1..7] | 3 位优先级，0 禁用，复位 0 |
| `0x1000` | PENDING | bit 1..7，只读 |
| `0x2000` | ENABLE | bit 1..6 |
| `0x200000` | THRESHOLD | 3 位，选取 priority > threshold 的源 |
| `0x200004` | CLAIM/COMPLETE | 读领取 ID，写完成 ID；0 表示没有可领取源 |

较大优先级先服务，同级先较小 ID。每源最多一个 pending/in-service。
claim 只在读请求接受时消费；响应被阻塞不再次领取。
处理程序须先清设备中断原因，再 complete；仍为高电平的源会重新挂起。

## DMA 控制器

基址 `0x10030000`，寄存器均为对齐 32 位访问。DMA 同时作为互连的第三主端口；
寄存器是 CPU 配置用的从端，搬运不经 CPU 软件逐字读写。

| 偏移 | 寄存器 | 行为 |
|---|---|---|
| `0x00/0x04/0x08` | SRC/DST/LENGTH | 32 位物理源地址、目的地址和字节长度；busy 时不可写 |
| `0x0c` | CTRL | 写 bit 0 启动；bit 1 保持为 IRQ_EN；busy 时不可写 |
| `0x10` | STATUS | bit 0 busy、1 done、2 error；done/error 写 1 清除 |
| `0x14/0x18/0x1c` | BYTES/FAULT/CODE | 已成功写入的字节、故障地址、结果码，只读 |

结果码 0 成功；1 配置无效；2/3 读 DECERR/SLVERR；4/5 写 DECERR/SLVERR。
DMA 只允许 I-TCM、D-TCM 与启用容量内的 DDR，拒绝 MMIO、零长度、范围重叠和越界。
对齐的整字按 XLEN 宽传输，其余字节逐个搬运；失败不回滚已完成写入。
IRQ_EN 且 done/error 置位时持续请求 ID 7；软件先读结果并清状态，再写 IRQ complete。

## Core 中断入口

`mie` 仅实现 MSIE/MTIE/MEIE；`mip` 相应三位由设备电平驱动，CSR 写忽略，
CSR 旁路也不能用在途的零写入覆盖硬件 pending。
机器中断按 MEI > MSI > MTI 优先；须同时满足全局 MIE、对应 mie 和 mip。
基础语义参照 [RISC-V Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)。

检测到可服务中断后只停止新取指，保留已接受的 IF 请求/缓冲并允许它们继续推进。
只有真正进入 Trap 的重定向才丢弃尚未入流水的旧响应；若中断提前撤销或被 CSR 屏蔽，
继续原指令流，不能因提前清 IF 而跳过指令。已进入流水的指令继续排空。
已接受的 Load/Store、MDU 必须完成；同步异常先提交。
`interrupt_entry` 记录实际退休后继 PC，包括已跳转的分支/JAL/JALR；
排空后将其写入 mepc，mcause[XLEN-1] 置 1，mtval 为 0，进入 mtvec。
MRET 恢复 MIE/MPIE 并从 mepc 继续。mtvec 仍仅支持 Direct 模式。
中断不是退休指令，不增加 MINSTRET；中断延迟受未完成访存/运算影响。

## SoC 信息与验证入口

系统寄存器基址 `0x10040000`，仅接受对齐 32 位访问：

| 偏移 | 寄存器 | 语义 |
|---|---|---|
| `0x00/04/08/0c` | XLEN/CLOCK_HZ/ITCM_BYTES/DTCM_BYTES | 原有只读信息 |
| `0x20` | DCACHE_INVALIDATE | 写 bit 0=1 全失效，读恒 0；零值/零掩码无副作用 |
| `0x24` | DCACHE_ENABLED | 只读 bit 0：D$ 开关开启且 DDR_BYTES 非零 |
| `0x28/2c` | DCACHE_BYTES/LINE_BYTES | 只读配置容量，默认 4096/32 |

维护寄存器有效写掩码中的保留位非零返回 SLVERR，不触发维护；写只读寄存器报错。
命令脉冲寄存一拍，清 valid 的沿不晚于该写响应的 CPU 消费沿。响应反压不会重复触发。
这是项目自定义 MMIO 协议，不是 Zicbom 或普通 FENCE 的隐藏行为。

DMA 完成或报错后，CPU 读取可能被 DMA 修改的 DDR 前须写此命令；错误也可能已有
部分写入。DMA 工作时不得访问或修改交接的缓存行。D$ 为写穿透，无 dirty/clean；
FENCE.I 仅负责代码可见性，不代替 D$ 维护。
CLOCK_HZ 是平台参数，不是测出的 FPGA Fmax。

`make soc-lint`、`soc-test`、`soc-software`、`soc-smoke`、
`soc-riscv-tests`、`soc-coremark`、`soc-dma-software` 均支持 `XLEN=32/64`。
原 Core-only 命令和镜像保留，SoC 镜像/日志使用独立 `-soc` 路径。
见 [仿真与 FPGA 工作流](SIMULATION_AND_FPGA.md)。
