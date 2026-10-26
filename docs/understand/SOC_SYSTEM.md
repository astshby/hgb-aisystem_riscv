# SoC 系统学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。当前基线为 `baseline-rv32-soc-20261025`；三组平台仿真和标准综合完成，当前版本布局布线及上板待做。

## 1. 当前结构

2026-10-26 的 `soc/npu128-five-domain` 增加可选 128-MAC NPU，源码固定到
[YOLO-accelerate 47ffb55](https://github.com/astshby/YOLO-accelerate/tree/47ffb558bf35bbe017a136903a7464e93132ea2c)。
计算核和分级 MMIO 七份 RTL 不改字节。下面的基线 Core 配置继续保留，第四组
`soc_npu` 在完整 DDR SoC 上挂 NPU；关闭 NPU 时原三组资源边界不变。

```text
Core + TCM + I/D Cache [Core 域]
        │ CPU I/D AXI CDC
        ▼
系统 AXI [SYS 域] ─── DMA 主端（CPU 配置，完成状态/IRQ）
   ├── DDR CDC ── 控制器用户口 [DDR 域] ── PHY/DDR3
   ├── MMIO CDC ── UART/Timer/GPIO/IRQ/控制寄存器 [periph 域]
   └── NPU AXI CDC（5 通道、各深度 4）[NPU 域]
         └── AXI beat 拆成 32 位访问 ── 分级 MMIO ── 128-MAC + 双激活 bank
```

NPU 域初始目标 100 MHz，原四域目标为 100/80/125/25 MHz。板级候选使用现有
800 MHz GPLL 的 CLKOUT3 /8，独立 BUFG；SYS→NPU 的请求/响应仍经过 CDC。
新增 5 个 FIFO、10 组 Gray 指针交叉，物理端点、偏斜和复位时序待合体报告核验。
不将独立 NPU 的 100 MHz 布线结果直接写成合体结果，也不通过 false path 隐藏路径。

NPU 设备窗口为 `0x20000000–0x2000ffff`。沿用原预留常量名 `NPU_SRAM_BASE`，
目前实际映射为寄存器及暂存区，软件不能把它当成普通 SRAM；`0x10060000` 仍未实现。
控制 ABI 保留上游偏移。DMA 只允许以下完整、四字节对齐区间：

| 方向 | NPU 地址 | 操作顺序 |
|---|---|---|
| TCM/DDR/Flash → 激活暂存 | `0x20000060–67`，8 字节 | CPU 写 bank/index，DMA 完成后 CPU 写 ACT_COMMIT |
| TCM/DDR/Flash → 权重暂存 | `0x20000100–17f`，128 字节 | CPU 写 index，DMA 完成后 CPU 写 WEIGHT_COMMIT |
| NPU → TCM/DDR | `0x20000200–24f`，RAW/INT8 输出 | CPU 确认 OUTPUT_VALID，DMA 读完并核对后 CPU 写 POP |

CPU 是索引、暂存、提交和输出槽的单一所有者。DMA 不写 START/COMMIT/POP；DMA
完成只代表一次搬运结束，NPU DONE 仍可能伴随最后一个未弹出的输出。多像素任务
需要边算边读，先等整任务 DONE 再读会把单输出槽堵住。CPU 对 DDR 缓冲先 clean/flush，
DMA 写回后 invalidate；TCM 不经过 Cache。现有 NPU ABI 采用轮询，未增加专用 IRQ。
AXI 接受后请求不可取消，设备错误返回原 ID；系统硬复位同时清两侧 FIFO，设备
SOFT_RESET 保留自身响应，七份上游 RTL 不变。

已完成双宽两组 CPU/DMA 卷积及各四组异频/背压/复位测试。第四组 CoreMark 增加
`npu_background`：Timer IRQ 服务驻留 4×1、Ci8/Co16 任务，原 DDR 16 KiB DMA 独立
运行，每个 RAW 向量用 CPU 标量公式核对。CoreMark/MHz 仍只除 Core 周期；NPU
开始/输出/忙周期、软件完成任务和结果错误单列。频率组合和完整数值见项目介绍。

复现入口（输出目录需未占用）：

```bash
make npu-test XLEN=32 NPU_TEST_OUT=build/npu-axi/new32
make npu-test XLEN=64 NPU_TEST_OUT=build/npu-axi/new64
RISCV_TOOL_ROOT=/opt/riscv/bin python3 scripts/verilator/run_unified_coremark.py \
  --output build/unified-coremark/new-npu --platforms soc_npu
```

工具链路径是本机参考，其他环境设置 `RISCV_TOOL_ROOT`。RV64 使用 `--functional --xlen 64`。

当前采用 E0u `9a7edd1` 的 Core 和 `7449fe7` 的统一测量入口，固定 RAS0、OOO0、
ROB32、int8/mem4、forward3、Tournament1。核级测试包含真实 TCM；片上组裁掉
Cache RAM 和 DDR；完整组保留 Cache/DDR，按 TCM、DDR cold/warm、背景负载
分别测量。主表和证据位置见[项目介绍](../PROJECT_INTRO.md)。

2026-10-23 的首次集成基于 `origin/main@91e33f7`。P2 保存在
`baseline/p2-before-p1-20261023@f2b33b4`，历史开发分支保留。
当时 84 个 Core/包文件与该 main 一致，在 `0501f10` 上增加可选 I-cache 64 位安装、
各域频率发现和板级独立时钟/复位候选，保留总线、TCM 路由与 D-cache 换单逻辑。

`CORE_BACKEND=scoreboard` 的整机入口为 `soc_system.sv`。`soc_top.sv` 保留
旧端口的同钟兼容包装；legacy 后端仍使用原互连。Core 为 i2、ROB32、
独立 int8/mem4、关闭有限整数乱序、转发模式 3、Tournament、LQ4/SQ4、DSP/SRT4；
ALU/Load/DSP 保持 8/10/10 级。完整参数由 `p1_core_config.sh` 固定，不能只改 ROB 数量。

```text
core 域：Core IF64/D0/D1 -> cpu_memory_adapter -> I$/D$、ITCM/DTCM
                              | I/D miss、旁路
                              + 两个 AXI 主口 -> CDC
sys 域：                  axi_system_fabric <--- DMA 单 AXI 主口
                           ^                  <--- 可选外部主口
                           |
         +-----------------+----------+---------------------+
         |                 |          |                     |
     Boot ROM          SPI Flash    TCM 系统口           DDR 准入门
                                      | CDC                 | CDC
core 域：               同一份 ITCM/DTCM 的第四端口       ddr 域：DDR 目标
         |
         + AXI4-Lite64 -> CDC -> periph 域：MMIO/IRQ/UART/Timer/GPIO
                                              DMA、Cache、Flash 控制
```

图中 TCM 只有两份物理存储，各 64 KiB、两个交错 bank。前三个本地端口供
IF/D0/D1，第四端口供系统访问。DMA 访问 TCM 要经过总线、CDC 和 bank 仲裁；
CPU 的 TCM 命中不绕行系统总线。Cache 命中也留在 core 域。
Core 与 TCM/Cache 进一步分域仅为未来候选。

## 2. 时序与总线契约

系统总线使用 AXI4：32 位物理地址、256 位数据、32 位 strobe，ID 为
2 位主端号加 2 位本地号。四个主端分别为 CPU I、CPU D、DMA、外部主端。
外部主端和可选 NPU SRAM 接口都属于 sys 域，接异频设备时需要独立 CDC。

- 五个通道分别缓冲，入口和目标端为深度 2 的同步 FIFO，ready 取本地容量。
- AR/AW 地址范围检查后再过一层深度 2 的寄存队列，将译码与多主端选择分开。
- 跨域为五组深度 8 的 Gray 指针 FIFO；深度 2 也有定向测试。
- 每个目标独立轮转仲裁，读写独立；同一主端每方向最多占用四个本地 ID。
- AW 保存目标与 W owner，W 严格按该序列发送；AW/W 可独立握手。
- 被反压的 valid、载荷、owner 保持，不能因另一请求到达改换当前事务。
- 支持对齐 INCR、1–4 beat、大小不超过 32 字节；不支持的 burst/权限进入错误目标。
  4 KiB 边界由主端拆分；错误读仍返回规定 beat 数，错误写排空后返回一次 B。
- 每方向的后端 owner 数量由目标决定；DDR 准入门及原生桥各方向一个活动 owner，
  不能把互连四个 ID 槽写成 DDR 能同时执行四个读请求。

入口、译码和出口各至少增加一拍；CDC 还有指针同步和接收等待。FIFO 可连续
接收 beat，但满队列释放空间会有恢复延迟。背压测试记录连续 W 接收与最长响应
等待，不能用队列深度推算实际带宽。载荷只在握手时写，复位清有效位/指针，
减少宽数据复位扇出。历史 `soc/p2-unified-bus@e3caafe` 在 P0 Core 下完成一次
标准 PDS：84.9856 MHz、CLMA 47%、LUT 41%/39%、FF 17%、DRM 9%，未达 85 MHz。
该结果不覆盖后续 P2 优化或当前 P1+P2 集成；四域独立时钟的物理实现仍待验证。

## 3. 地址与访问

| 区域 | 基址 | 当前用途 |
| --- | --- | --- |
| ROM | `0x00000000` | 只读启动跳板，跳到 ITCM |
| ITCM / DTCM | `0x01000000` / `0x01100000` | 各 64 KiB，本地与系统端共享 RAM |
| MTIME / IRQ | `0x02000000` / `0x0c000000` | 机器定时器、软件中断与外部中断控制 |
| UART0 / UART1 | `0x10000000` / `0x10001000` | 串口，lite 省略 UART1 |
| Timer / GPIO0–2 | `0x10010000` / `0x10020000` 起 | Timer1、GPIO；lite 按 presence 缩减 |
| DMA / SoC 信息 | `0x10030000` / `0x10040000` | 单命令 DMA、设备与 Cache 控制 |
| Flash 控制 | `0x10050000` | SPI 命令、地址长度、dummy、分频、状态 |
| NPU 控制 / SRAM | `0x10060000` / `0x20000000` | 控制窗尚无设备；SRAM 可选端口，默认容量 0 |
| Flash 只读窗口 | `0x30000000` | 容量参数化，非执行，不支持写/擦除 |
| DDR | `0x80000000` | 容量参数化，可缓存代码/数据 |

原 SoC discovery ABI=1 保留。新增只读寄存器：SoC+`0x40` 扩展能力，
`0x44` DDR 状态（bit1 已配置、bit0 已就绪），`0x48` Flash 容量，`0x4c` NPU 容量。
不存在的窗口报错。RV64 高物理地址不能截断成低 32 位访问。

`CLOCK_INFO_ENABLE=1` 时，discovery `+0x3c` 的 bit8 声明频率扩展存在，major 仍为 1，
低 8 位 profile 不变。新增只读字段如下，旧 `+0x04` 保留配置值，不再用于推断不同域频率：

| SoC 信息偏移 | 内容 |
| --- | --- |
| `+0x50` | 扩展版本 1、五项 presence，值 `0x0001001f` |
| `+0x54` / `+0x58` | Core / SYS Hz |
| `+0x5c` / `+0x60` | DDR 用户口 / periph Hz |
| `+0x64` | mtime Hz，当前等于 periph |

新版 BSP 先读原 discovery，bit8 为 0 时仅用原 `+0x04`，不探测未映射地址。
启用扩展的 profile 配套新版 BSP；旧严格校验 discovery 的 BSP 会拒绝新 bit8。
Timer 超时和 tick 用 timer_hz，UART 用 periph_hz，SPI 分频用 sys_hz，mcycle 换算用
core_hz。未知版本、零频率或 timer/periph 不符返回错误。共享接口在
`software/common/soc_clocks.h`，冻结 CoreMark 镜像保持原样。

## 4. 程序和 DMA 的生命周期

复位后 CPU 从 ROM 跳转到预装 ITCM。ROM 仍只有跳板，生产 Flash 镜像的头部
检查、CRC、版本和失败恢复软件尚未实现。TCM 初始化可来自仿真镜像或 FPGA
存储初始化文件；本轮没有生成、下载 bitstream。

CPU 通过 MMIO 写 DMA 的源地址、目的地址、长度并 START。外设域把命令整包
送到 sys 域，BUSY 从命令接受持续到结果返回。DMA 用一个 AXI 主口读取源、
写入目的，双 128 B 缓冲允许读下一块和写上一块重叠。B 成功后累计成功前缀；
故障停止新请求并排空已展示事务，状态/故障地址整包返回，可查询或中断。

当前支持 TCM↔TCM、TCM↔DDR、DDR↔DDR、Flash→TCM/DDR；两端对齐时用宽块，
非对齐头尾使用同一 AXI 主口的窄访问。没有 UART FIFO DMA、描述符链、多通道，
NPU SRAM 尚未加入 DMA 地址白名单。CPU 负责命令和所有权交接，DMA 负责搬数据。

SPI 读取支持配置命令、3/4 字节地址、dummy 位与时钟分频；配置跨域原子提交，
只在空闲时应用。当前宽 Flash beat 会分成多次 XLEN 读取，每次重发 SPI 头部，
因此 Flash 持续读取带宽仍有优化空间。

## 5. Cache、MMIO 与中断

I$/D$ 仅缓存 DDR；TCM、ROM、Flash、MMIO 旁路。程序主体存放 DDR，Cache 根据
CPU 访问自动填行，软件无需先把程序搬入 Cache。每个 D$ bank 仍阻塞式处理 miss，
没有 MSHR、early restart 或硬件一致性。

P2 已保存的 DCache 优化允许同 bank 消费旧 cached 响应时接纳下一个 cached
请求，命中接纳间隔为两拍；旧 uncached 响应沿原端口协议交接。cached→uncached
仍保留边界，Store 应用、维护 pending、错误归属和反压载荷保持规则不变。
不同 bank 可并行，同 bank 双客户端按 owner 和轮转规则分配。

I-cache 新增显式候选 `SOC_ICACHE_FILL_BYTES=8`，默认仍为 4。32 B 行的块安装
由八次 32 位写变为四次 64 位写，安装尾部从九拍缩为五拍；标量填行仍发 32 位请求，
两次成功返回后合并写 RAM。填行失败后的两字回退只形成 IF64 响应，不安装缓存行。
整块检查、错误排空、失效优先和 IF64 命中每拍受理保持。
该候选不修改 D-cache 默认安装宽度，双宽 scalar/block 与兼容回归共 65 次运行通过。

DMA 读取 CPU 修改过的 DDR 数据前须 clean/flush；DMA 写回后 CPU 读取前须
invalidate。Cache 维护命令跨域整包发送，完成和最终错误状态同包返回。
FENCE.I、脏行写回失败和取指阻止行为保持原契约。常规 MMIO 为 32 位访问；
AXI4-Lite64 保留 RV64 MTIME/MTIMECMP 的单次 64 位读写，不拆成两个副作用操作。

MMIO/IRQ 状态属于 periph 域。中断状态保持到软件处理，经双触发同步和原 IRQ
寄存后送 Core，不直接跨域传单拍脉冲。协调复位同时清所有域的 FIFO 所有权，
各域同步释放；不支持仅复位一侧继续使用另一侧旧事务。

DDR 未就绪时，sys 域准入门直接返回错误，DDR 时钟停止也不阻塞这个错误路径。
已接受正常事务后若 DDR 失去时钟/校准，恢复需要协调复位；没有逐事务超时器。
板级候选 C1/C4 的 `pango_soc_reset` 使用 125 MHz 参考钟监测 DDR 健康状态和心跳，
故障时复位全部域、FIFO 两端及 DDR IP，丢弃在途事务后从 ROM 重启。
首次启动仅等待独立 SoC PLL，允许 DDR 尚未运行时执行 ROM/TCM/MMIO。
健康状态三拍同步后检测，静默停钟由 128 参考拍看门狗检测；公共复位保持 64 参考拍，
每个目标域再用三拍同步释放。该恢复不保证保存在途 DDR 写入。

## 6. 验证入口与结果

```bash
source scripts/verilator/p1_core_config.sh
make soc-axi-test XLEN=32
make soc-axi-test XLEN=64
make soc-system-test XLEN=32
make soc-system-test XLEN=64
```

`RISCV_TOOL_ROOT` 指向工具链目录。专项 runner 读取共享 `p2_core_config.sh`；
未选择配置时保留原 P0 对照，以上命令先载入完整 P1 profile，构建目录包含 Core
配置标签，不能将原 ROB16 二进制当作 P1。默认系统程序
跑 C0–C4：100/100/100/100、100/80/125/25、125/100/80/40、约85/117/93/37、
100/100/125/25 MHz；最后一组 core/sys 同频不同相。精确半周期保存在运行日志。
这些是仿真激励频率，没有对应的新 FPGA Fmax。

本轮 P1+P2 已通过双宽各 9 项 AXI/CDC/原生 DDR 定向、各 3 种子 TCM 等价检查，
及双宽 scalar/block 共 4 个严格 DCache turnover 目标，共 28 PASS、0 SKIP。
每次 DCache 测试会执行两种模式，模式选择只限定严格换单断言目标，原始 8 条
case PASS 含重复配置。24 条编译命令均核对完整 P1 宏，22 个二进制有 SHA，
测试前后源码 SHA 一致；证据在 `logs/p2/p1-adapt-20261023/focused/summary.json`。

以下为 P0 Core 下的历史 P2 功能结果：双宽各 9 项 AXI/CDC/原生 DDR 定向、
各 5 项整机异频程序通过；SoC ISA 为
RV32 59 PASS/1 SKIP、RV64 79 PASS/1 SKIP。程序实际通过 SPI 引脚模型读取代码，
DMA 装入 DDR 后执行，覆盖非对齐搬运、Cache 维护和 RV64 定时器宽访问。
DDR 模型采用确定性拍数等待，不能据此宣称真实 DDR 带宽。
原始结果在 `logs/p2/unified-bus/final/`，源码、镜像、二进制和命令有 manifest。

M2-direct 预装路径用 `SOC_DDR=1` 生成 DDR 链接镜像：入口留在 ITCM，代码放
DDR `0x80000000`，数据/栈留 DTCM；测试台用 `+DDR=<ddr.hex>` 预装模型。
RV32/RV64 C0–C4 各 5/5 PASS，日志在 `logs/p2/m2-direct-20261022/`。这是功能
验证，不代表 M2 CoreMark 性能、Flash loader 或板级启动已完成。

Pango wrapper 的 `BOARD_CLOCK_PROFILE=0` 保留四域共用 DDR 125 MHz 用户钟及等待
校准的行为；候选 C1/C4 使用独立 GPLL 输出 Core100、SYS80/100、periph25 MHz，
DDR 用户口仍为 125 MHz。未改动的厂商 GPLL 模型测得预期周期；双宽实际 CPU 的
DDR 停钟启动及 ROM→TCM→MMIO 执行通过。DDR 不可用报错及在途失锁由外部 AXI
测试端发起，协调复位后 CPU 重新从 ROM 执行，新 epoch 请求正常完成。
PLL 站点、DDR IP 共存、
生成时钟和 CDC 物理约束、IO/复位时序留给后续标准 PDS；Flash 引脚仍未接。
2026-10-23 的 schema 9 已能暂存 C1/C4，并从 `g_domain_clocks.u_soc_pll.u_pll/CLKOUT0..2`
生成 `clk_core`/`clk_sys`/`clk_periph`；profile 0 仍为 schema 8。C1 暂存
`soc-rv32-c1c` 的 557 条约束检查为 0 error，综合 PASS：76,298 LUT/159,800、
61,092 寄存器/319,600、36 DRM、4 APM、0 latch；估计 `clk_core` 36.5150 MHz
（WNS −17.386）、`clk_sys` 84.1326、`clk_periph` 73.0514、`ddrphy_sysclk` 144.7178。
没有加载 clock group、false path、max_delay 或 I/O delay；ddr→sys 和 sys→ddr
仍有跨域 setup/hold 失败，不能当作闭合。Core 的 36.5 MHz 综合估计来自 `ras.sv` 的
34 级串行恢复链，旧 r15/P2 的 85 MHz 不覆盖当前 P1 Core；place/route、bitstream
和烧板仍未完成。

B20 双宽整机 C0–C4 和时钟软件共 20 次运行通过，另有四次独立启动/恢复运行。
新版 BSP 在旧硬件上回退单频，新硬件上按各域频率配置 Timer/UART/SPI。RT-Thread
双宽 smoke 与 CoreMark 应用共四个镜像编译通过；完整 RT 运行因原有测试台引用旧
`soc_top` 层级而未完成，不能用这些编译结果代替 RT 运行验收。
证据根为 `logs/p2/joint-step3-20261023/`，性能结果见[项目介绍](../PROJECT_INTRO.md)。
当前没有新增标准 PDS、板级测试或实际十秒 CoreMark；GCC 11.4 与 GCC 16.1 镜像分开比较。
