# RT-Thread 首版 BSP（rt-thread-port）

MES2L676-200HP 的后续板级集成见 [Pango 进度](FPGA_DEMO_REPORT.md)。此页记录的首版 BSP 仍以 TCM 镜像和仿真 `sim_console` 自检为准；`scripts/rt-thread/build_sim.sh` 现在会使用传入的 `MUL_IMPL`/`DIV_IMPL`，板级目标选择 `0/1`（DSP/SRT）。

## DDR CoreMark 应用（开发分支）

UART loader 与下载工具已作为独立软件加入，协议和测试见 [FPGA demo 报告](FPGA_DEMO_REPORT.md)。`RT_COREMARK_RESIDENT=1` 生成独立驻留应用，每轮输出 CRC、原始 cycles 和配置，收到 UART0 的 `r` 后重测；默认单次运行接口保留。完整 ELF 下载包已通过 RV32/RV64 × performance/validation 四组 SoC UART 数字仿真，各执行两轮并检查 RT-Thread 继续调度，0 SKIP。均为 1 次迭代的功能测试，实板和有效时长验收仍未完成。

2026-10-13 起按新 demo 契约增加 `RT_COREMARK_LAYOUT=ddr` 独立布局：主代码、常量、普通数据/BSS、堆与线程栈进入 `0x80000000–0x8001ffff`；2000 B 工作集在 `0x80020000`；探测字在 `0x8003f000`。应用 ELF 入口在 DDR，热代码 LMA 仍在 D-TCM，IRQ/启动栈在 D-TCM。`rt-thread-coremark` 入口预装模型 bootstrap 与外存 HEX；`uart-rt-thread-test` 入口只预装 loader 的 TCM 初值，经 UART 下载 DDR 主体与 D-TCM 热镜像，不预装应用 HEX。上板时必须集成 loader BRAM 初值和匹配的 DDR IP。

```bash
RT_COREMARK_LAYOUT=ddr make rt-thread-coremark XLEN=32 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
RT_COREMARK_LAYOUT=ddr RT_COREMARK_MODE=validation make rt-thread-coremark XLEN=32 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
# RV64 使用 XLEN=64 独立复跑。
```

镜像目录为 `build/rt-thread/coremark-ddr-{performance,validation}-rv{32,64}`，驻留追加 `-resident`，非默认波特率再追加 `-baud<值>`。布局专用运行日志为 `logs/rt-coremark-ddr-*-rv*.log`，完整下载日志为 `logs/uart-rt-*-rv*.log`。TB 要求观察实际 DDR 指令请求；预装布局另检查 I$ 命中，完整 UART 入口检查两轮经 UART 解码的 PASS/READY 与 DMA/FENCE.I。单有 DDR 数据读写不能通过此布局验收。

`codex/fpga-rtthread-coremark-ddr3` 另加独立应用入口，不替换原 `make rt-thread` 自检。构建使用未修改的 CoreMark vendor 源码、RT-Thread v5.2.2 和 DSP 乘法/SRT 除法；`.hot` 仍由 D-TCM 的镜像经硬件 DMA 装入 I-TCM，再执行 `FENCE.I`。专用链接脚本把 2 KiB `static_memblk` 放在 `0x80000000` 的 DDR 窗口，其他代码、数据和栈留在 TCM。应用先对 DDR 探测字做 D$ flush/invalidate 及读回；CoreMark 结束后再比较工作集在 D$ flush/invalidate 前后的哈希。镜像检查同时核对工作集地址与热代码 VMA/LMA。

在仓库根目录运行功能仿真：

```bash
make rt-thread-coremark XLEN=32 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
make rt-thread-coremark XLEN=64 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
RT_COREMARK_MODE=validation make rt-thread-coremark XLEN=32 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
RT_COREMARK_MODE=validation make rt-thread-coremark XLEN=64 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu-
```

默认每次只跑 1 次迭代。CoreMark 原输出会明确提示运行时间不到 10 秒，故 `PASS ... functional CRC (short run)` **只证明功能 CRC 正确，不是合格分数**。测试平台观察外存 AXI 模型的读写接受、UART0 TX 跳变、DMA 搬运顺序及执行热代码前的 `FENCE.I`；日志 `sim_console` 只是仿真观察口，固件同时逐字节经 SoC UART0 发送。外存模型不等于实际 Pango DDR3 芯片或板上串口采集。

正式运行应以 `RT_COREMARK_ITERATIONS=0` 调用 `scripts/rt-thread/build.sh` 生成自动校准镜像，并在上板后核对 UART 输出中的 `Correct operation validated.`、三个分项 CRC、至少 10 秒实测时长、迭代数和时钟频率。若在仿真中尝试长时运行，可提高 `RT_COREMARK_MAX_CYCLES`，但当前 40,000,000 周期默认上限不足以模拟 10 秒。当前尚无 FPGA 上板成绩。应用输出和构建物分别位于 `logs/rt-coremark-*` 与 `build/rt-thread/coremark-*-rv*`。

本适配基于 SoC 快照 `9c7cbb4`，仅在 `rt-thread-port` 开发；不修改或推送
`main`。新增软件、构建入口和被动测试，不改 `vsrc/`、既有 benchmark、
既有 SoC 测试或上游 RT-Thread 源码。

## 依赖与运行

采用官方 RT-Thread **v5.2.2**，固定提交
`ddf52e2cdd977f14fc04035c88672ac204aec713`。配置为单核、M 模式、Nano
无 libc 内核，加上官方 serial-v1/pin 设备框架、堆、信号量和互斥量。
没有启用 SMP、POSIX、FinSH、文件系统、网络、浮点或硬件原子操作。
原子操作使用内核的单核关中断实现。复用上游 common RISC-V 上下文切换及栈初始化。

Ubuntu 仓库位置为 `/home/yukino/projects/hgb-aisystem_riscv`。
在仓库根目录执行：

```bash
git branch --show-current        # 必须是 rt-thread-port，不在 main 修改
make rt-thread-fetch             # 首次下载官方依赖到忽略的 build/ 目录
make rt-thread XLEN=32 CROSS_COMPILE=riscv64-linux-gnu- OPT_FAST=-O0
make rt-thread XLEN=64 CROSS_COMPILE=riscv64-linux-gnu- OPT_FAST=-O0
```

需要 Git、Python 3、GNU Make、Verilator、主机 C++ 和 RISC-V GCC/binutils。
本地验证使用 Ubuntu 22.04、GCC 11.4、Verilator 5.052。`OPT_FAST=-O0` 只影响
Verilator 生成的主机代码，规避本机 GCC 编译生成模型很慢的问题，不改变固件优化。
也可用 `CROSS_COMPILE=/path/to/riscv64-unknown-elf-`；默认沿用
`RISCV_TOOL_ROOT=/opt/riscv/bin`。本次未验证另一工具链。
`RTTHREAD_ROOT` 可指定相同提交的只读依赖，构建会拒绝版本不符或已修改的源码。

固件使用 `rv32im_zicsr_zifencei/ilp32` 或 `rv64im_zicsr_zifencei/lp64`。
不生成 A/C/F 指令，不执行 WFI，不依赖操作系统 libc。关闭 Linux GCC 默认的
build-id，确保 `_start` 真正位于 ROM 跳转目标，而非被 ELF note 挤到后面。

生成物位于 `build/rt-thread/rv32`、`rv64`，包含 ELF、链接 map、反汇编、符号表和
I/D-TCM hex。日志位于 `logs/rt-thread-{build-,sim-build-,}rv{32,64}.log`。
下载失败时保留现有目录并报错，不自动删除或重置任何依赖。

## TCM 与 DMA 布局

| 物理地址（含首尾） | 用途 | 初始内容 |
|---|---|---|
| `0x01000000–0x0100dfff` | I-TCM 常驻启动和普通内核代码，56 KiB | 由仿真/板级初始化预装 |
| `0x0100e000–0x0100ffff` | I-TCM 热代码，8 KiB 上限 | 测试时全零，必须 DMA 装载 |
| `0x01100000–0x0110bfff` | D-TCM 数据、线程栈、堆，48 KiB | data 初始化、BSS 启动清零 |
| `0x0110c000–0x0110dfff` | 热代码装载镜像，8 KiB 上限 | D-TCM 预装，只读使用 |
| `0x0110e000–0x0110ffff` | 独立启动/中断栈，8 KiB | 不作堆或 DMA 缓冲 |

链接脚本检查容量和至少 8 KiB 剩余堆。`.hot` 的执行地址在 I-TCM、装载地址在
D-TCM；镜像脚本只把 `.hot` 放入 D-TCM hex。`HOT_CODE` 可标注新增常用函数。
当前 `.hot` 包含 Direct trap 入口、IRQ 分派，以及上游线程切换和关/恢复中断函数。
不是把代码标成一个 section 就视作搬运完成。

启动次序：ROM 跳到常驻 `_start` → 关中断、清 BSS → 真实 DMA 从
`0x0110c000` 搬到 `0x0100e000` → 检查完成/错误/字节数及逐字节内容 →
`FENCE.I` → 设置 Direct `mtvec=0x0100e000` → 初始化内核/设备 → 启用 MTIE/MEIE →
启动调度器。失败保持关中断并写失败码，不执行热代码。

CPU 目前只支持 **Direct mtvec**，所以使用统一入口后软件分派，不配置硬件向量模式。
D-TCM 不可执行。ROM 仍只是跳转器，不是 UART/Flash 下载器；本版没有解决上板镜像
下载，也没有通过修改 ROM 绕过现有启动约定。

TCM 不经过 I$/D$，不会 cache miss；同步 bank 在请求接受后下一拍返回。
这不等于整个 CPU 每拍必定完成一次取指：仲裁竞争、owner 交接、流水线反压仍会等待。
测试按 bank 接受沿检查一周期响应，不将这个结果冒充 FPGA Fmax 或零竞争保证。
本版 DMA 的两端均在不缓存的 TCM；若将装载源迁到 DDR，必须另加 D$ 所有权交接：
源 clean/flush，目的交出前 flush、DMA 完成后 invalidate，最后再 `FENCE.I`。

## 驱动边界

- Tick：读 SoC `CLOCK_HZ`，MTIME 每 CPU 周期递增，1000 Hz 系统 tick；高低高读时间、
  高全一/低/真实高写比较值。绝对截止时间避免漂移，延迟服务时补 tick。
- IRQ：真实的七源 claim/complete 汇聚器；先清外设原因再 complete，不假定完整 PLIC。
  trap 保存所有线程需要的整数寄存器，在独立 IRQ 栈处理；中断退出应用内核延期调度。
  不开启嵌套中断。同步异常记录 `hgb_fault_cause/pc/value` 后停止，尚不支持恢复。
- UART：`uart0/uart1`，32 位 MMIO（RV64 也不使用 LD/SD 访问普通外设）。
  轮询 TX、IRQ RX、软件接收环形缓冲；仅支持 8N1、LSB、无反相/流控。
  不支持 UART DMA：现有 DMA 硬件禁止 MMIO。RX 硬件只有一字节，软件缓冲不能消除
  中断延迟造成的硬件溢出。错误计数可由 `hgb_uart_errors[]` 观察。
- serial-v1 上游控制接口会缓存无效配置并忽略 configure 错误；BSP 在设备控制入口
  预检，使不支持的格式通过 `rt_device_control` 返回 `-RT_EINVAL`，不修改上游文件。
- GPIO：`pin` 设备，0–31/32–63/64–95 对应三组。支持输入、推挽输出、上升/下降/双沿
  中断；读输入为硬件两级同步后的值。RMW 操作关中断保护，回调前 W1C 清事件快照。
  拒绝越界 pin 和电平中断。没有硬件上下拉/开漏/去抖支持；`rt_pin_mode` 的 void
  接口通过 errno 报错，也提供带返回值的 `hgb_pin_mode_checked`。
- `rt_hw_console_output` 提供 UART0 早期轮询输出；测试报告另走既有仿真 console
  观察口。没有开启交互式 shell。普通业务应通过串口设备框架使用 RX。

## 验证层次

`make rt-thread` 每种位宽独立完成：

1. 镜像检查：入口、VMA/LMA、热函数地址、容量、I-TCM 热区初始全零。
2. 官方内核运行：tick 抢占、两个不主动让出的同优先级线程时间片、周期软件 timer、
   semaphore 超时与 ISR 唤醒、线程返回及 idle。
3. 上下文探针：线程各用不同寄存器模式，检查调用者/被调用者保存寄存器、参数和
   16 字节栈对齐；RV64 模式包含非零高 32 位。不是仅跑一个空线程。
4. UART0/1 各四个字节的物理引脚数字环回，设备 API 收发、IRQ 唤醒、错误配置拒绝、关闭中断。
5. 三组 GPIO 的读写、双边沿 IRQ、detach 后不再回调，以及无效模式/编号拒绝。
6. 新增被动 TB 观察：热区初始为空、CPU 没有代替 DMA 写热区、DMA 地址/字节数/成功响应、
   完成及 `FENCE.I` 前不执行热代码、真实 trap 入口退休、TCM bank 一周期响应、没有 DDR 取指。

最终运行结果见 [修改记录](COMMIT.md)。以上是 Verilator SoC 仿真；没有 FPGA 综合、
BRAM 推断报告、板级 UART 电气/波特率容差测试、GPIO IOBUF 或 DDR 初始化验证。
不能据此声称已上板完成、具备生产级实时延迟保证或全功能 RT-Thread BSP。
DMA 超时/硬件错误的停止分支已实现，但本次未做故障注入；DMA 独立硬件回归见既有记录。

## 文件职责与后续

`software/rt-thread/` 保存配置、链接、启动、trap、板级支持、UART/GPIO 和测试应用；
`scripts/rt-thread/` 保存依赖下载、固件/模型构建、镜像检查、运行入口；
`tb/soc/tb_rt_thread.sv` 复用现有 SoC runner，新增被动契约检查。
默认固件是有限时长的自检，不是常驻 shell。实际应用下一步可替换 `smoke.c` 的
`hgb_app_init`，通过 `rt_thread_init/startup` 创建业务线程，保留启动与 DMA 契约。
需要后续单独评审的工作：板级 BRAM 初始化/下载器、时钟与引脚约束、压力/故障注入、
串口持续流控方案、可选 FinSH、DDR/Cache 场景及常驻应用。
