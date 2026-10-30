# 项目配置与测量

2026-10-30工具补充：9e213c1将DDR生成RCF随新工程冻结并明确加载，74项纯工具检查通过。
新离线输入yolo-c10-rcf-inputs与原工程的260份HDL、完整程序、C10与64/80策略相同，
仅compile增加board_ddr.rcf加载；未重新运行PDS，原始缺RCF的结果不回写，后续比较交A。

本轮完整YOLO＋HDMI的原始P&R已于16:00正常结束：Core/SYS/DDR-user/外设/NPU/视频Fmax为
85.9387/108.0885/132.6612/72.8046/95.5526/162.8928 MHz，对C10六域WNS均正，0未布通。
全部slow/fast内部setup/hold、复位时序、MPW和CDC/Gray通过，DDR PHY最小setup+0.045 ns。
资源LUT94202（含常量/旁路）、FF73263、DRM169格（165×36K＋6×18K）、APM86单元/44格。
I/O仍有36输入/103输出通用delay提示，需按DDR、HDMI/I2C及异步接口核覆盖；没有板上FPS、bitstream或实物验收。
物理输入源45de647、正式程序6aff928ff969d57d，源/HEX/命令/报告哈希见logs/release-ab-20261030/yolo-physical-r1。

## 目录与公共配置

`vsrc/core` 保存共享 Core，`vsrc/soc` 保存 TCM/Cache、AXI、DMA、MMIO 和跨域接口，
`vsrc/cpu` 为 FPGA 顶层。`scripts/hardware_profile.json` 固定 Core 参数、容量和目标时钟；
`scripts/branch_profile.json` 记录当前分支保留的应用。`make help` 只显示存在的应用。
Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4，
正常 ALU/Load/DSP 为 8/10/10 级；C、F/V、MMU/Linux 未实现。

本分支当前使用C10 `yolo_sys`，Core/SYS/DDR-user/外设/NPU为
83.806818/102.430556/125/65.848214/92.1875 MHz，视频独立148.5 MHz。
系统GPLL为921.875 MHz VCO、I/M/F=8/1/59、输出分频11/9/14/10；DDR IP时钟不变。
旧C1–C8保留历史值，不能把旧周期或Fmax直接填到新档。
ITCM/DTCM各64 KiB，发布测量明确使用I$16 KiB、D$8 KiB、bank XOR mask2，两路、32 B行；
通用API的4/4 KiB默认值继续保留，I$填充粒度4 B。
TCM 与 Cache 命中逻辑仍在 Core 域；Core 与它们进一步分域仅是未来候选。
SYS 负责统一 AXI 仲裁，DDR 与外设分别通过 FIFO 跨域。DMA 是 SYS 域主设备，
CPU 提交地址/长度/方向、启动、核对完成和处理 Cache 所有权；不允许 DMA 写 START 等控制寄存器。
生产顶层为 `soc_system.sv`，CPU 侧使用 `cpu_memory_adapter` 与 `tcm_bram`。
SYS 与 Core 是并行的时钟域；SYS 域不包含 Core、TCM 或 Cache。各域组件见[系统结构](understand/SOC_SYSTEM.md)。

| 发布分支 | CoreMark | RT-Thread | 加速器 |
|---|---|---|---|
| main | M0与三层、完整上板程序 | 无 | 无 |
| yolo | 无 | 无 | YOLO＋HDMI |
| minimind | 无 | 无 | MiniMind |
| all | M0、三层与 YOLO 并发层 | 一份独立应用 | 同时挂载YOLO/MiniMind，仅仿真 |

所有分支保留公共功能、ISA、AXI、CDC、UART 下载验证。加速器分支不携带 CoreMark 算法、
跑分脚本或 RT-Thread。原作者 MiniMind C 代码、模型锁和导出工具保留在 MiniMind/all。

当前YOLO源码由`8a8f484`保留完整程序，选择性加入共享硬件、C10时钟和新Core优化。
发布输入为`45de647`，Core/TCM/SYS与main的`82cbf7a`逐文件相同，默认保留Store hint；
没有恢复旧Core，也没有保留CoreMark或RT-Thread专属程序/入口。

| 本轮检查 | 结果与路径 |
|---|---|
| 完整RV32/RV64固件 | O3/115200/HDMI1，27源、ELF/HEX/TCM、无C/F ISA核验通过；ID `6aff928ff969d57d` / `adcd70b68d805fcf`；`build/release-ab-20261030/yolo/final-program-rv{32,64}/manifest.json` |
| C10真实RV32生产驱动 | 3卷积、171输出、5量化值；`logs/release-ab-20261030/yolo/driver-c10-rv32/receipt.json` |
| C10 SYS/外设视频 | AXIL32完整1080p帧、切换/反压/欠载/I2C通过；`logs/release-ab-20261030/yolo/video-c10-rv32/result.json` |
| 原生暂存/角色/CDC工具 | 58 PASS/0 SKIP，视频清单共40 FIFO和10同步级组；`logs/release-ab-20261030/yolo/tools-delivery-pass.log` |
| Windows原生输入保护 | 16 PASS/0 SKIP，无PDS；`logs/release-ab-20261030/yolo/yolo-input-guard-test.log` |
| 程序短测 | 64 PASS/6 SKIP，缺固定模型的5项导出和1项发布检查未跑；`logs/release-ab-20261030/yolo/demo-tests.log` |

RV64新档driver/video复测交后续调试，本轮没有重复83层长仿真。
共享Core的两宽功能证据在main/all对应提交中保留，不把新程序构建称为完整RV32网络执行。

## 环境与命令

实测工具为 GCC 16.1.0、Verilator 5.052、Windows PDS 2025.2 ADS。
外部路径使用 `RISCV_TOOL_ROOT`、`PDS_HOME`、`PDS_WORK_ROOT`、`RTTHREAD_ROOT`。
依赖 `riscv-tests` checkout 只读、不作为本轮新子模块提交。

`make check XLEN=32|64` 运行通用功能、scoreboard、ISA、SoC、五组时钟、AXI 和 C smoke。
`make loader-host-test` 与 `make loader-soc-test XLEN=32|64` 检查下载协议和 UART 实际引脚。
本分支应用入口以 `make help` 为准。
`make yolo-demo-build XLEN=32|64` 编译常驻 UART/模型/整网/显示演示固件。
软件默认 O3，图计算显式关闭 fast-math 和浮点收缩；RV64 使用无 C/F 指令的软浮点库，
本轮复用`YOLO_SOFTMATH_ARCHIVE`，库SHA256为`819a14079182697a3ea1331886c5dc66239393ba215fe91a370c7a6059c8d467`；
未重新编译工具链。库缺失时先恢复同一归档，不把默认IMAC/F/D库链接到本核。
`make yolo-demo-test` 运行现有协议/PC 工具、无 Torch 导出、C 图算子、服务/内存池和视频 C 短测。
不自动启动整网；缺模型资产的可选导出/发布检查打印 SKIP。
2026-10-30 提供固定模型资产后，该入口 70 PASS、0 SKIP（协议37、导出13、图算子1、服务12、视频7），
日志 `logs/demo-software-20261030/yolo-entry-tests.log`；未提供资产时，6 项可选检查会打印 SKIP。
原 `make yolo XLEN=32|64` 保留自动卷积和 DMA 重叠回归。

PC 命令为 `scripts/yolo/host.py --port COM5 status|model|upload|read|detect|selftest`。
图像使用 RGB888，每块最多 1024 B，逐包、整帧和模型均核对 CRC32。
READY 的 DETECT/HDMI 位由模型发布、NPU 和显示状态决定；缺模型时仍报告 NOT_READY，
已校验模型可执行 83 Conv/266 节点。`network.c` 处理原 BN、SiLU、池化、拼接、上采样、
检测头和 NMS；`conv_schedule.c` 将卷积按 16×16 空间输入块、8 输入通道组和 16 输出通道装入 NPU。
边缘 halo 由 CPU 填零，输入动态 INT8 量化、权重逐输出通道量化，不折叠 BN。
驱动逐寄存器装载权重/激活；DMA/计算重叠仍由旧算子回归单独测量，不能套成整网吞吐。

| 2026-10-30 验证 | 结果 | 本地证据 |
|---|---|---|
| 完整 416 模型 NPU 部件仿真 | 83 Conv/266 节点、9,760,257 个输出与同源标量参考一致，3 框；33 分 28.7 秒 | `logs/demo-software-20261029/yolo-full/rtl-416-execution.json` |
| 真实 RV32/RV64 Core 执行生产驱动 | 各 3 个小卷积、171 个输出、5 个量化值通过 | `logs/demo-software-20261030/yolo-driver-rv{32,64}/receipt.json` |
| 视频独立 RTL，RV32/64 配置 | 每宽 4 个健康完整 1080p 帧，A/B CRC、反压、旧响应排空和欠载恢复通过 | `logs/demo-software-20261029/yolo-full/video-receipt.json` |
| 真实 UART 与原 C 应用短流程 | SELFTEST、两轮上传/回读、A/B 显示通过；CRC `a417d1cf` / `fd1074b8` | `logs/demo-software-20261029/yolo-full/app-tiny-3m/result.json` |
| 320 模型完整应用联合运行 | 83 Conv/266 节点、3,233 块、5,775,300 个 INT32 输出逐项通过，3 框；真实 UART 收图/回图、1080p 扫描、回 READY；11,638.68 秒 | `logs/demo-software-20261029/yolo-full/app320-full-rtl-v2/result.json` |

部件整网与共同 I/O 平台都由电脑执行 C，没有 RISC-V Core 或 CPU Cache；前者使用真实 NPU/AXI/CDC，
后者增加真实 UART 引脚、系统总线、DMA 和显示，DDR 为行为模型，没有 Flash。
完整应用的 C 也在电脑执行；真实 Core 另已通过同源5组图算子、BN、量化、Focus/拼接/池化/上采样/SiLU/sigmoid、解码和NMS检查；复用模型的90项Core/pkg SHA一致、SoC仍为C1，不作当前整机时序或整网结果。尚无完整RV32整网。
短流程的 3 Mbaud 是仿真参数，没有板上高波特率测试。I/O 平台仿真缩短 I2C reset/settle 等待到 600 周期，
400 kHz SDA 传输和 49 项寄存器写入保持。视频 PLL 的厂商模型实测 148.499986 MHz；板上 HDMI 尚未测试。

演示地址固定：RGB `0x81000000`、模型 `0x82000000`（16 MiB）、XRGB8888 A/B
`0x83000000` / `0x83800000`（各 8 MiB）、图计算 arena `0x84000000..0x88000000`（64 MiB）。
共同 I/O 平台共享 DDR 后台总计 128 MiB，从 `0x80000000` 开始；它是行为模型，不是 DDR3 PHY。
预载模型经过同一 CRC/图结构检查；模型 UART 命令可用，但没有 Flash 冷启动或板上约 5 MB 全传验收。
固件按 READY→上传→计算→框/画框图回传→显示完成→READY 循环，不使用 RT-Thread。

长测先将YOLO_IO_LIBRARY、YOLO_MODEL、YOLO_IMAGE、YOLO_REFERENCE设置为已生成的I/O库、320模型、原图RGB和同源参考目录；下面采用已测的192×144原图尺寸。

```bash
make yolo-io-test XLEN=32 YOLO_IO_OUT=build/yolo/io-new YOLO_IO_LOG=logs/yolo/io-new
make yolo-demo-cosim YOLO_IO_LIBRARY="$YOLO_IO_LIBRARY" YOLO_MODEL="$YOLO_MODEL"
make yolo-demo-cosim-full YOLO_IO_LIBRARY="$YOLO_IO_LIBRARY" YOLO_MODEL="$YOLO_MODEL" \
    YOLO_IMAGE="$YOLO_IMAGE" YOLO_WIDTH=192 YOLO_HEIGHT=144 YOLO_REFERENCE="$YOLO_REFERENCE"
```

联合入口执行同一 C 服务和真实 I/O RTL；完整网络为数小时长测，普通短测不会隐式启动它。
已通过的 320 联合运行使用 192×144 dog RGB，经真实 UART 收入，再由同一 C 预处理到 320；
`app320-full-rtl-v2/app-progress.jsonl` 记录逐层/分块进度，`app-packets.jsonl` 记录串口包。
首轮观察器漏读8字节trace签名，在第1卷积开始前退出，FAIL现场保留；修正后的 v2 完成整网与画框图回传。
v2 处理 172 个真实 UART 请求，累计 RX/TX 为 88,060/88,720 B；第二次 DETECT 复用已缓存结果，没有再次执行 83 层。
显示完成 596 个 1920×1080 帧，最终返回 READY、内存池 live=0；AXI、串口帧、显示欠载、视频总线和 I2C 错误均为 0。
8,208,000 个量化输入字节、全部 INT32 输出和 3 框与同源参考精确一致；画框 RGB CRC32 为 `d47715d8`，
完整显示帧 CRC32 为 `4f3b0e78`。`finalreceipt.json`、`sourceidentity.json` 和 `seal.json` 同目录保存，
20 份应用文件与 58 份 RTL/fixture 哈希逐项一致；最终收据 SHA256 为
`fee1f2a08395b2fde9ce563a1693cb45bd03c3f9e486727686753d34eda1a8cc`。
耗时 11,638.68 秒、峰值 RSS 78,476 KiB。构建记录基于 `6008bc5` 并包含当时未提交的联合入口，
这些源文件已由 `a91c795` 保存且逐项 SHA256 相同；结果记录 C 源码、模型与库 SHA256。
I/O 库为 `e229c17576903fe0e7f063f5ef30e5eb826197a6ec87805e10e7a6a0e23ed450`，模型为
`50fb5df506e4763dc07e65a394396df1215487150cafd66a219282751d48ee71`。
每次指定新输出/日志目录，收据保存命令、源代码、ELF/HEX 或库与资产哈希。

Cache 容量实验共用上述软件入口。`coremark-platforms`、独立 RT 测试和 PDS 暂存均支持
`--icache-bytes` / `--dcache-bytes`，未指定时各为 4096。实际实例参数、固件和时钟写入测量清单。
批量容量测试使用 `scripts/verilator/run_cache_sweep.py`，命令见[联合优化](understand/OPTIMIZATION.md)。

## 共享Core的历史CoreMark对照

以下为main/all的历史测量口径，本YOLO分支不提供CoreMark执行入口。M0使用TB一周期存储。
`core_tcm` 是真实 Core+TCM，`soc_tcm` 增加 ROM/DMA/MMIO，`soc_ddr` 增加 Cache/DDR，
all 的 `soc_npu` 再增加 YOLO。综合使用相同参数、软件 bundle 和仿真 build receipt。
RT-Thread 不参加这组测试。

CoreMark/MHz = iterations × 1,000,000 / 计时区 mcycle。
其他时钟域影响等待拍数，分母仍为 Core MHz。cold 未预热 Cache，warm 先运行一次；
background 加 DMA 和 Timer IRQ，NPU background 还执行、核对卷积。

| 软件优化 | M0 perf / val，64 次 | 真实 TCM perf / val，2 次 | DDR cold / warm perf，2 次 |
|---|---|---|---|
| O2 | 3.526520 / 3.507011 | 3.012983 / 2.994267 | 2.389572 / 2.404525 |
| O3 | 3.590617 / 3.570731 | 3.052755 / 3.035846 | 2.381312 / 2.395887 |
| Ofast | 3.590617 / 3.570731 | 3.052755 / 3.035846 | 2.381290 / 2.395887 |

编译矩阵 78 PASS、0 SKIP，源提交 d5abd51；公共集成 edc2349 重放 O3 24 项周期一致。
O3 提升 M0/TCM，但 DDR 略低；同表保留取舍。短仿真未满足正式十秒要求。
完整记录在工作区 `2-coremark/record.md`，镜像及日志在本仓库忽略目录
`build/four-branches/`、`logs/four-branches-20261027/`。记录包含命令、CRC、ELF/HEX/源码哈希。
历史日志曾被维护者删除，旧摘要不能替代本轮原始报告。

Cache 容量实验保持 Core 与上述时钟比例，O3 64 次迭代共 18 项通过。
I$16/D$4 KiB 的 cold、warm、DMA/IRQ performance 为 2.507487、2.508556、2.187186 CoreMark/MHz；
六个场景/种子的跑分几何均值比 4/4 KiB 提高 4.8455%，8/4 KiB 提高 4.5763%。
32/4 KiB 的两次迭代初筛周期与 16/4 完全相同；D$8/32 KiB 出现回退，保留 D$4 KiB。
默认配置仍为 4/4 KiB，16/4 是上述容量实验的显式配置；后续bank候选见下文，尚未替换正式baseline。
真实 TCM 重放周期不变，RV64 候选功能通过；RT32 的 I$ miss 6048→1635，总周期减少约 0.44%。
后者包含 tick 等待，单独记录。

## 历史RT-Thread数据（源码仅在all）

RT-Thread固定v5.2.2提交`ddf52e2cdd977f14fc04035c88672ac204aec713`，源码和执行入口仅在all。
本分支不提供RT命令，下列保留既有四域实验数据。
完整四域 SoC 无 NPU。Boot ROM 跳到 ITCM 启动，常用 trap/上下文代码驻 ITCM 顶部 8 KiB，
其加载镜像在 DTCM 的 `0x0110c000`；DMA 搬入后校验并执行 FENCE.I，再安装 mtvec。
程序主体、数据、BSS、线程栈/堆在 DDR `0x80000000`，由 Cache 自动填充；
DTCM 保留观测区和机器异常栈。TB 为仿真预装 DDR 镜像，板上装载仍需 Flash/UART 启动链。

O3 双宽实际运行通过：RV32/RV64 为 2,765,395/2,774,072 TB 周期，39 次 trap，
DDR 退休计数均超过 260 万，I$/D$ 命中和 DMA 热代码搬运均被检查。它们是功能时间，不能换算 CoreMark。

## 历史无NPU C6结果（2026-10-30）

无 NPU C6 最终布线 Fmax Core/SYS/DDR-user/外设为 87.3057/98.2415/122.5490/72.2201 MHz，
setup WNS 分别为 −1.454/−0.179/−0.160/+2.820 ns，0 未布通；Core 尚未达到 100 MHz。
源码提交 `80576b9`，I16/D8/mask2、O3/64 次 TCM 自动固件，原始摘要在
`logs/main-coremark-c6-cdc-20261029/physical-summary.json`。该结果属于 main 的无 NPU 完整系统，
不能套到新视频/YOLO硬件或交互固件。该次物理未包含当前交互固件和视频通路，没有板测。
DDR PHY 的负裕量、35/73 项缺少输入/输出 delay 等分别保留，不能把 0 未布通写成时序通过。


## 2026-10-28 TCM 与 YOLO 历史实验

TCM 改用双端口 BRAM：取指/数据主口固定，辅助口公平仲裁，CPU 读不增加一级。AXI beat 级写校验、已有请求队列的静态路由预译码、8 路 SYS 复位释放副本和同步器保护已加入组合。
真实 TCM 64 次为 3.095736/3.081770 CoreMark/MHz，较 R3 的 3.054825/3.040240 提高约 1.34%/1.37%。
SoC+TCM 加 DMA/IRQ 为 2.750866/2.737537；DDR cold 为 2.530971/2.513669，warm 为 2.532010/2.514682，后台为 2.207755/2.194270。
14 项长测已用冻结固件重放，周期与原汇总逐项相同。

| 工程/策略 | Core MHz / WNS ns | SYS MHz | DDR-user MHz | 外设 MHz | NPU MHz | LUT / FF |
|---|---:|---:|---:|---:|---:|---:|
| 组合 Core+TCM，标准 | 103.5733 / +0.345 | 无 | 无 | 无 | 无 | 26031 / 19682 |
| 组合 SoC+TCM，标准 | 96.4413 / −0.369 | 110.1200 | 无 | 98.7362 | 无 | 40759 / 39286 |
| 组合完整 DDR，标准 | 90.0252 / −1.108 | 107.6310 | 150.5117 | 87.6808 | 无 | 55906 / 55348 |
| 组合 Core+TCM，性能 | 104.1016 / +0.394 | 无 | 无 | 无 | 无 | 26939 / 24465 |
| YOLO，标准 | 93.1532 / −0.735 | 101.8537 | 146.4772 | 85.9107 | 107.9680 | 64816 / 67831 |
| YOLO，性能 | 92.9282 / −0.761 | 113.9212 | 146.0494 | 92.1574 | 114.8633 | 66393 / 72759 |

上表全部是综合估计。两套 TCM 工程用 32 DRM/4 APM，完整 DDR 用 38 DRM/4 APM，YOLO 用 164.5 DRM/86 APM，均无 latch。
加上端口单项三层，本轮 9 组综合均完成。Core+TCM 性能策略较组合标准提高约 0.51%，FF 增加约 24.3%；
YOLO 性能策略改善 SYS/NPU，但 Core 略退。尚未达到 Core+TCM 超过 130 MHz 或联合指标不退，正式基线未升级。
SYS 的 Fmax 可以高于 Core；它们分别由域内最差路径决定。目标频率仍为 100/80/125/25/100 MHz。

YOLO O3/I16/D8/mask2 双宽裸机通过，RV32/RV64 为 418463/423721 周期；实际 MAC 工作 83 次，与 DMA 重叠 28 次。NPU AXI 四种频率、双宽共 8 项各 14 检查通过。只验证小卷积与搬运，没有完整 YOLO 网络 FPS/mAP。
RT-Thread 在无 NPU 组合单独通过，RV32/RV64 为 2741224/2752870 周期、各 39 次 trap；它们是功能耗时。

RTL 组合测量提交 a7b25c2，YOLO 集成 76139dc，配对原生工程工具 8277462。命令、ELF/HEX 和日志哈希在
`logs/tcm-bram-20261028/`、`build/yolo/system-rv{32,64}-O3-i16384-d8192-h2/result.json`。
临时树跨文件系统迁移失败后被删除，部分原始仿真日志丢失；原生 PDS 工程、报告、冻结固件及汇总保留。
组合双宽回归、14 短/14 长/3 项 RV64、RT 与 PLL 已补测，新的证据在 `logs/tcm-bram-20261028/recovery/`，与丢失原件分开记录。
SoC+TCM 26 个 FIFO/358 个同步寄存器及 YOLO 36 个 FIFO/502 个同步寄存器已核对原生对象和时钟归属。
约束前后对照已通过：6/11 组功能跨域 setup 裕量为正，同域时钟、Fmax、setup/hold 和端点数一致，
同域例外及无匹配路径告警均为 0。146 项工具测试与新增 2 项时序对照测试通过，工具提交 5b29642。
YOLO 的 `physical-ready` 工程与启动脚本已冻结；预检为物理 14.988 GiB、提交余量 8.370 GiB。
按用户要求停在 dev_map/place/route 之前。Core 100 MHz 的综合 WNS 仍为 −0.761 ns，物理结果待测。
补测重复快照和可重建编译产物已清理，日志、固件和结果保留约 74 MB，清单为
`logs/tcm-bram-20261028/recovery/retained-evidence.json`。所有原生 PDS 报告保留。

## 2026-10-27 路径历史实验

收尾分支integrate/soc-path-selected基于47aec08，保留SYS独热控制和可配置bank入口，不含A/B；正式baseline未升级。
I16/D8/mask2是显式性能候选，默认I4/D4/mask0保持。六项64次DDR与bank-only对照同周期，TCM周期保持。

| 当前无A配置 | performance / validation，每MHz | Core综合估计MHz | LUT / FF |
|---|---:|---:|---:|
| M0，64次 | 3.590617 / 3.570731 | 不单列裸Core测频 | 不适用 |
| Core+TCM，2次 | 3.052755 / 3.035846 | 105.0641 | 26130 / 19665 |
| SoC+TCM，2次 | 3.052755 / 3.035846 | 93.6067 | 39908 / 39165 |
| SoC+TCM＋DMA/IRQ，2次 | 2.642689 / 2.618037 | 同上 | 同上 |
| DDR cold，64次 | 2.530971 / 2.513669 | 89.3336 | 52571 / 55207 |
| DDR warm，64次 | 2.532010 / 2.514682 | 同上 | 同上 |
| DDR＋DMA/IRQ，64次 | 2.207225 / 2.193928 | 同上 | 同上 |

SoC+TCM的SYS/外设为112.9433/98.8045 MHz，DDR完整系统SYS/DDR-user/外设为106.6894/150.4664/86.3185 MHz。
三层DRM分别32/32/38、APM均4；各域WNS、最差路径和约束缺口见 [路径实验综合](fpga/FPGA_ADAPTATION.md#路径实验的三层结果与取舍)。
四分支整理时Core+TCM/SoC+TCM/DDR Core为103.8853/95.0299/85.1064 MHz；随后I16/D4容量实验为86.8282 MHz。
当前Core+TCM频率与资源改善；SoC+TCM Core比旧95.0299下降1.4976%，因此本轮未验收所有层主频不退，正式baseline保持。
SYS单项I16/D4/mask0的Core90.1307 MHz高于D8联合89.3336；D8六项每MHz几何均值+0.8207%，两项取舍分开记录。
A单项曾得到92.2594 MHz，但联合三层的Core频率与LUT均由无A控制取得较好结果；B在相同SYS底座使Core90.1307→88.3470、增加492 LUT/155 FF且每MHz回退，均不采用。
D4/mask1联合Core85.4920 MHz，低于起点86.8282，被拒绝。这组 2026-10-27 路径实验没有布局布线或上板成绩。

47aec08完整双宽test各82 PASS/2 SKIP、scoreboard31/0，ISA58/2与78/2，smoke各1/0，M0各2/0通过。
I16/D8/mask2独立RT双宽通过，总周期2741313/2753088，各39次trap；该功能耗时不作为RT跑分。
完整短/长矩阵、两份源码对照、三层标准综合与哈希保存在本地record和final-summary.json。
