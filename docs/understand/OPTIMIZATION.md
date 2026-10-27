# 优化学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。本文记录哪些改动真正改变了周期或频率，哪些只是结构变化。

2026-10-23 当前分支 `soc/p2-p3-clock-study`，B20在B19 `0501f10` 上推进P2/P3步骤1–3。
Core的84个RTL/包文件保持P1，8/10/10级、ROB32/int8/mem4与预测/转发配置不变。
当前生产RTL为 `1a4f8fa`；主要结果见[项目介绍](../PROJECT_INTRO.md)。本轮没有PDS，
独立时钟候选的物理时序与85MHz下限仍待验证。

I-cache显式安装8字节时，32B行的安装尾部9→5Core拍；默认4字节保留供物理对照。
标量填行请求仍为32位，两次成功后合并64位写；block完整成功后再安装。
错误/截断/取消/失效/背压及共享D-cache双宽65次回归通过，命中IF64仍每拍受理。
不将每次少四拍乘以miss数直接当成全程序周期收益，最终以同镜像测量为准。

M1全程观测到数据响应1拍、d0/d1排队1.046/1.107拍；输出等待216822拍对应DTCM同bank争用，
入口仅满21拍。当前已支持请求/返回同拍换单，保留注册边界可避免TCM仲裁重接Core.ready。
本轮没有修改M1队列；后续若继续研究，应分开读读和读写冲突，按CPU阻塞窗口验收益。

DMA补测区分W源气泡与下游反压，连续流每burst的源等待均为AW到首W固定一拍，
没有观测到额外burst中途缺供。本轮没有加预取。SYS80/100MHz下持续DMA为
519.20/615.85MB/s，IRQ-only/DMA-only的软件对照另列；原100μs M2-B继续保留。

时钟发现/BSP把mtime、UART、SPI、CoreMark分别按timer、periph、sys、core计时。
候选C1/C4保留Core100/DDR125/periph25，仅比较SYS80/100；GPLL厂商模型、DDR未启动
时实际CPU执行ROM/TCM、在途失锁后协调重启均通过。真实站点/CDC/IO约束还需标准PDS。
旧binary的64次同镜像C1→C4，cold/warm/background分别提高0.361%/0.354%/1.109%；
该结果属于SYS频率激励变化，和I-cache逻辑收益分开记录。48模式联合矩阵及10模式
M0/M1控制均通过，同钟fill8两模式无回退；精确数值见项目介绍。

所有结果保留 `logs/p2/joint-step3-20261023/` 的源码、镜像、命令和原始日志；
实际十秒CoreMark尚未完成，RV64只验功能。RT-Thread四个镜像编译通过，完整运行仍
被旧测试台层级失配阻塞；裸机时钟软件测试不能替代RT运行。旧P1 GCC11.4数据单列。

以下为 P1 来源报告，不能跨编译器镜像直接计算收益。

P1 以 `main@094443e` 和 GCC 11.4 重建的同一组镜像比较。P1.1a 拆 LQ/SQ 后周期和
统计不变；P1.1b 的 ROB32、分离 IQ 提高 M0/M1 得分 0.0814%/0.7759%，综合增加
8,698 LUT、6,884 FF，中间布线拥塞后取消，没有最终 STA。P1.2 限制为 ALU/MDU
就绪旁路，分支/访存保留接纳顺序，得分较重建 P0 提高 1.4002%/2.6147%。

P1.3 `ea3fb0a` 的五组、二十次比较显示：屏蔽分支全部 LSU 提示会让 M0/M1 得分
比 P0 下降 6.8744%/5.0268%；其余 LSU 提示全部先捕获时下降 9.7774%/8.4293%。
旧提示同时含合法读返回和 Store 转发，最终选分源模式 3，保留合法读返回当拍旁路，
Store 提示先捕获且不送分支；配合 Tournament/RAS 后为 2.933400/2.566781/MHz，
较同镜像 P0 提高 11.3812%/10.7359%。单独模式 3 的周期代价为 0.0233%/0.0164%。
模式 0 的 MDU 资源等待约 742 拍，Load RAW 队列状态为千万拍且可能与其他等待重叠，因此本轮
没有再增加 ALU/MDU 级数。`8c072c0` 最终回归为 RV32 237 PASS/4 SKIP、RV64 269 PASS/4 SKIP，
其中八次 RV32 重放的周期、CRC、统计和镜像逐项重复一致。最终综合为 57,437 LUT、
41,497 FF、零 latch，比 P1.1b 增加 11,253 LUT、2,556 FF。首轮标准 place 峰值
20,193 MB，申请 51,145,552 字节失败。新目录复用同源综合快照、283 文件哈希一致，
重试前物理可用/提交余量 19.988/24.021 GiB；place 再次申请 92,745,552 字节失败，
内存池峰值 22,191 MB。Windows 事件记录 PDS 提交量 42,237,083,648 字节及虚拟内存不足，
24 GiB 的启动余量未能支撑此配置。用户已要求暂停布局，最终 P1.3 时序和物理验收未完成。
详细结果见 [双发射](DUAL_ISSUE.md)，不与下列旧 GCC 16.1 记录混算。

## 1. CoreMark/MHz 怎么算

设迭代数为 K、CPU 周期为 C：

```text
CoreMark/MHz = K × 10^6 / C
```

板上总分还要乘实际 MHz。IPC、CoreMark/MHz、Fmax、实际时钟和资源效率分开记录。
时钟约束写 125 MHz 不代表电路能在 125 MHz 工作。

本项目至少四条路径：Core-only 一周期存储、SoC TCM、裸机 DDR/Cache、RT-Thread
DDR。迭代数、链接布局、软件指令数、Cache 状态和总线等待不同。只在同路径、同
ELF/HEX、同参数下比较纯 RTL 改动。

## 2. 逐轮数据

下面是 RV32 历史测量，镜像和配置存在差异；跨行不直接计算纯 RTL 增幅。

| 阶段 | 路径 | 周期/迭代 | CoreMark/MHz | 说明 |
|---|---|---:|---:|---|
| 第三轮 | SoC TCM | 345,167 | 2.897145 | 接近一周期存储 |
| 第四轮 | SoC TCM | 1,183,872 | 0.844686 | 主端事务寄存器 |
| 第六轮 | Core-only | 约 413,700 | 2.417461 | WB 响应寄存 |
| 第十轮 | Core-only | 472,098 | 2.118203 | 分支结果寄存 |
| I1 C2c | Core-only | 578,891 | 1.727441 | 严格 WAW、LSU/CSR 队头 |
| I1 C3c | Core-only | 603,568 | 1.6568 | 解除全局阻塞，反而退步 |
| I1 最终 | Core-only | 584,792 | 1.710011 | Tournament/RAS |
| I2 i2/q8 | Core-only | 552,169 | 1.811039 | 有限双发射 |

历史 `fdb3ffb` 使用固定 64 次迭代，双宽、M0/M1 的八次重放通过：

| 分类 | RV32 CoreMark/MHz | RV64 CoreMark/MHz |
|---|---:|---:|
| M0 Core + 仿真双口存储 | 2.393948 | 2.092062 |
| M1 完整 SoC-TCM，DDR 空闲 | 2.137354 | 1.896438 |

无额外请求拍的同镜像对照 `b98f714` 的 M1 为 2.371599/2.087406。
两项时序改动分别是 SoC 请求缓冲和 ROB 寄存退休；前者增加一次访存请求等待，
后者增加一次退休等待。两者都保持每拍双路吞吐，仍会降低部分程序的周期效率。
最终取舍须和标准布线 Fmax 一同验收，P0 的 RV32 门槛为 85 MHz。

## 3. 三个负优化

### 3.1 第四轮：主端事务寄存器

`bus_transaction_register` 是单槽状态机，一笔完成后下一拍才能接下一笔。TCM
本来可以接近 1 拍，现在要经过请求寄存、fabric、TCM、响应寄存。SoC TCM 分数
下降约 70.8%。

收回思路：热 TCM 给专用 1 拍口；慢路径保留寄存但允许请求 FIFO 和 2–4 笔
outstanding；Cache miss 用 critical-word-first。

### 3.2 第六轮：WB 响应寄存

`wb_response_register` 先把响应寄存，下一拍才让 LSU 完成。所有 Load 多一拍，
Core-only 下降 16.6%。

收回思路：保留寄存边界，同沿把格式化数据旁路给 EX 带 ID 前递；或用 2 项响应
队列，第一次消费从队头旁路。

### 3.3 第十轮：分支结果寄存

`branch_result_register` 让所有条件分支/JALR 停 EX 一拍，Core-only 下降 10.4%。

收回思路：乐观推进。EX 用组合结果先推进本包，下一拍用寄存快照检查误预测。
预测正确零代价，误预测仍是一拍后重定向。异常、目标不对齐、训练和中断边界单独测。

## 4. I1 的主要成本

1. 全部 Load/Store 等退休队头。普通 RAM Load 不需要这个许可，只有 MMIO、
   Store 副作用和 CSR 需要。
2. 严格 WAW。查询最多返回一个生产者，所以同名写者要等；按年龄选最年轻的更老
   写者可以去掉这个停顿。
3. 单完成口固定 WB 优先。队头 Load 等完成时，年轻 WB 抢走完成口；C3c 的退步
   是这个机制的直接证据。
4. CSR 队头、单 LSU、4 槽 ROB。容量和顺序策略要分别测量。

## 5. 旧 SoC 成本与当前边界

下面列出 I1/I2 旧后端的主要成本。新 scoreboard 后端已经提供原生 IF64、
I$ 命中 II=1、TCM 双 bank 与两个 D$ bank，详细契约见 [SoC 系统](SOC_SYSTEM.md)。
每个 D$ bank 仍为阻塞式 miss，共享 DDR 填充/写回带宽；MMIO 的周期另测。

1. 取指逐 word 串行拼 64 位；I$ 命中 II=3。
2. 整行安装逐 word；D$ miss 全阻塞。
3. 每个主端单笔在途；TCM 仍经过 router/fabric。
4. MMIO 端点约 3 拍接受间隔；UART 只有一字节 RX。

## 6. 怎么测

1. 先加事件计数：取指饥饿、发射 0/1/2、退休 0/1/2、RAW/WAW、队列满、
   LSU/MDU、Cache 命中/缺失、仲裁等待。
2. 包含式计数可以重叠；互斥归因要先声明优先级，不能把重叠原因相加。
3. 每条指令用完整 ID 跟踪 alloc、request、response、valid、complete、retire。
4. 区分延迟和吞吐停顿；空级没有工作不算停顿。
5. 每次 RTL 改动跑同一 ELF，先 Core-only，再 SoC TCM，再 DDR/RT。

## 7. 当前优化顺序

P0 已冻结于 r15，Core 的 ALU/Load/DSP 为 8/10/10 级，原完整 SoC 标准 PDS
85.2464 MHz。P1 的 Core 工作归其他接手人；本轮 P2 固定 Core，只改 SoC 总线。
P3 再做实际时钟、CDC 物理约束、标准 PDS 和 ≥85 MHz 验收。RV64 跟随功能仿真。

P2 以同步 FIFO 切开 ready 返回，AR/AW 译码独立寄存，按目标轮转仲裁，读写
分方向保存 owner，跨域用有界 FIFO。TCM/Cache 命中留本地，慢设备等待只占
其目标和相关请求。双缓冲 DMA 继续读写重叠，完成/故障整包跨域。

M0 为 Core 控制组，M1 为 TCM，M2 单列 DDR/Cache cold/warm，M2-B 独立记录
并发负载。分母用 CPU ROI 周期；改变 sys/ddr/periph 比例必须重测。
已测 C0–C4 功能不能替代 M2 性能数据，也不能将旧 P0 Fmax 配给新 SoC。

当前分支 `soc/p2-m1-local-timing` 基于 `e3caafe`，先缩短 M1 本地组合逻辑：
TCM 资格改为独立前缀/对齐/权限检查；双 bank 选择从逐项 greedy 改为并行首选
加不冲突次选，载荷由 one-hot 掩码直接选取。两项均无新增寄存拍，保持原轮转
顺序与 IF64 原子访问。宽载荷 grant 扇出仍存在，实际 Fmax 与资源待后续测量。
双宽原译码对照、组合穷举、原模块逐拍及 RAM 字节参考均通过。

`benchmark/p2/` 为 M2 专用布局：代码、常量、工作区和正常栈在 DDR，TCM
只留入口、维护/中断胶水及测试控制。cold 在 TCM 控制栈清空 Cache，warm
预跑一次原版 iterate 并恢复输入；M2-B 使用私有 DDR 区域并由 CPU/定时器
中断发起、续传 DMA。三场景指令镜像相同，只改 DTCM 配置。
`run_p2_coremark.py` 强制核对布局、CRC、实际时钟与 ROI 内 DDR/DMA/IRQ 活动。
2 次迭代是短适配测试；不与 64 次 M0/M1 计算优化比例。
warm 预热算法代码/数据，未保证所有正常 DDR 栈行预热。M2-B 每次处理完中断后
重新安排 2048 个 periph 周期，各时钟配置的实际 IRQ 强度不同。

DMA ROI 吞吐统计主口接受的 W beat，完成字节包含收尾排空并另列。最长 AR
入队等待为零也不能说明 Cache miss 无等待。下一步先增加响应等待统计，再
比较 CPU R FIFO、DMA W 缓冲/owner、Flash 连续读和系统 TCM 宽口。

本轮双宽 TCM/SoC/ISA 回归通过，M0 固定两模式仍为
22,381,822/22,507,018 拍，M1 C0–C4两模式共10项通过，ROI仍为25,658,220/25,792,596拍；C1与入口前后相同。
M2 cold/warm、M2-B × 两模式 × C0–C4 共30项短测通过；解析/布局负测24项通过。
C1 performance 三场景分别为1,004,030/1,000,530/1,142,577拍，validation为
1,011,219/1,007,344/1,151,521拍。每CPU MHz归一化值来自迭代数除以mcycle；
移植层的1MHz虚拟秒数与实际仿真时长分开，当前均未达到实际10秒要求。

```bash
# RISCV_TOOL_ROOT 指向工具链 bin；日志目录使用新的名字保留之前记录。
python3 scripts/verilator/run_p2_coremark.py --build-sim --iterations 2 --clocks 0 1 2 3 4 --log-root logs/p2/ddr-replay
python3 tb/scripts/test_p2_coremark.py
python3 tb/tools/test_soc_clock_plan.py
```

`plan_soc_clocks.py` 只生成新 build 目录中的四端口时钟定义及 CDC 清单：
C0–C4 五种仿真条件和 85/100/125/25 MHz 候选，不写板级 FDC、不启动 PDS。
wrapper 仍四域共用 125 MHz DDR 用户钟；PLL、综合后 Gray pin 约束和 IO 约束
需后续接入。此前标准 PDS 为 84.9856 MHz、WNS −0.002 ns，最差端点在冻结
Core；不能用它宣称本轮候选已通过 85 MHz。证据在
`logs/p2/m1-local-followup-20261022/`，执行范围见工作区 Codex B17。

## 8. 不要做的事

- 不用增加表容量代替实际测量。
- 不用 false path 掩盖真实同步路径。
- 不把不同 ELF、频率或 RTL 的优点拼成一个成绩。
- 不把功能 PASS 写成性能提升。
- 不把 Core-only、SoC TCM、DDR 的分数混用。
