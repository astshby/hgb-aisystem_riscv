# FPGA 适配与 PDS

> 写作约束：[regulation.md](../../../regulation.md)。本文记录工具、流程、约束和结果，不把工具 Fmax 写成板上频率。

P1.1a 实测源码为 `core/p1-1a-split-lq-sq@a23b65c`，LQ/SQ 拆分后保持 ROB16/IQ8。
标准综合、dev_map、place、route、route_optimize、report_timing 均完成，得到
86.1721 MHz、85 MHz WNS +0.160 ns、TNS 0、12 类 STA 零失败，57,149 条网络全部布通。
物理为 40,181 LUT、32,188 FF、36 DRM、4 APM、77 IO；综合为 37,486 LUT、32,057 FF、
零 latch。228 项输入哈希和 I/D-TCM 各 64 KiB 初值均匹配。最差路径由 Store 地址
经转发资格、提示标签、IQ 操作数选择到分支事件，20 级、11.135 ns，逻辑/布线
4.481/6.654 ns，最高扇出 38。证据为 `logs/p1/p1-1a/pds-result.json`，原生工程在
`$PDS_WORK_ROOT/work/p1-1a-lsq-split-20261022/soc-rv32`。85 MHz 为内部 STA，
IP 实际配置仍为 125 MHz，35/73 项 I/O 延迟缺失，未上板。

P1.1b `f547da3` 原生综合为 46,184 LUT、38,941 FF、36 DRM、4 APM、零 latch，
229 项输入及双 TCM 初值通过。标准布局完成，place 内存池峰值 14,879.289 MB；
布线第 13 轮仍有 24,179/69,295 条未布通、154,582 项 overused，主动取消中间运行。
只停止已核对身份和项目路径的自有 route，父 PDS 随后退出；没有最终 Fmax/WNS。
工程和原始报告保留在 `$PDS_WORK_ROOT/work/p1-1b-rob32-split-iq-20261022/`，
取消记录为 `logs/p1/p1-1b-drain/pds-cancelled.json`，`Flow-0189/-1` 随取消出现。
P1.3 选择 ROB32/int8/mem4、有限整数乱序、转发模式 3、Tournament/RAS。
`8c072c0` 完整回归为 RV32 237 PASS/4 SKIP、RV64 269 PASS/4 SKIP，八次 RV32 固定镜像
重放全部逐项一致。最终工程为 `$PDS_WORK_ROOT/work/p1-3-store-forward-tournament-20261022/soc-rv32`，
230 项输入哈希、216 个 HDL 及全部参数通过，全部 FDC 与 P1.1a 逐字节相同，未修改 false path。
综合入口物理可用/提交余量为 13.707/6.914 GiB，最终综合为 57,437 LUT、41,497 FF、
零 latch、36 DRM、4 APM、77 IO，230 项输入和双 TCM 各 64 KiB 初值全部匹配。
首轮标准实现入口为 17.859/20.725 GiB，place 入口为 17.314/20.179 GiB。标准 place
在 EP_DL 阶段申请 51,145,552 字节失败，耗时 10 分 15 秒、内存池峰值 20,193 MB；
没有进入 route，没有最终 Fmax/WNS，失败收据为 `logs/p1/p1-3-final/pds-place-failed.json`。
原工程及全部原始报告保留，未主动取消。已从综合完成快照复制到全新目录
`$PDS_WORK_ROOT/work/p1-3-memory-retry-20261022/soc-rv32`，283 个文件哈希一致，
230 项输入及双 TCM 初值复查通过，未重编 RTL 或改约束。
2026-10-22 22:57:13 +08:00 重试启动前物理可用/提交余量为 19.988/24.021 GiB，
额外 16/24 GiB 检查通过；place 入口为 19.826/23.847 GiB，标准各阶段仍检查双 6 GiB。
重试 place 在 EP_DL 申请 92,745,552 字节失败，耗时 6 分 8 秒、内存池峰值 22,191 MB，
23:03:59 自然退出，没有进入 route。Windows 事件 2004 在 23:03:57 记录
PDS 提交量 42,237,083,648 字节及虚拟内存不足；工具池峰值与进程提交量分别记录，
24 GiB 启动余量未能支撑此配置。系统按现有设置自动增长分页文件，仍发生分配失败；
没有手工修改分页或结束无关进程。
证据为 `logs/p1/p1-3-final/{retry-place-failed.json,retry-resource-event.json,retry-monitor.jsonl}`，
重试控制结果 `retry-controller-result.json` 为 FAIL。原工程、网表、两次失败日志和控制结果保留。
用户已要求暂停布局；最终 P1.3 没有 Fmax/WNS、物理资源、最差路径或未布通数量，
本次仅提交代码、仿真和综合结果供评审。后续明确恢复后再评估环境并使用新目录，
不直接重跑已失败的控制入口或覆盖日志。不能将 P1.1a 的物理结果代替最终 P1.3。

## 1. 目标

- RV32 统一承担性能优化与完整 SoC 标准 PDS ≥85 MHz 验收；RV64 只做功能/ISA/SoC 仿真，不设性能门槛、不启动 P&R。
- 同域 Fmax、WNS、资源、最差路径和未布通网络一起记录。
- DDR PHY、外部 IO、UART、ILA 和十秒 CoreMark 单独验收。

当前 wrapper 仍使用 DDR IP 的 125 MHz 用户时钟。125 MHz 下 setup 未收敛，
没有 bitstream、没有烧板。

CMP `2b49c77` 的 r12 已完成标准 PDS：87.8837 MHz、85 MHz WNS +0.386 ns、
TNS 0、零未布通；slow/fast setup、hold、recovery、removal、MPW、skew 均零失败。
物理 LUT/FF 为 46,457/32,096，36 DRM、4 APM。最差路径为 IQ 读指针到 DSP，
7 级、10.015 ns，高扇出 897。35 输入、73 输出仍缺 I/O 延迟约束。
当前 ISS `85ab1ca` 为 ALU/Load/DSP 8/10/10 级，完整双宽回归与八次重放通过；
r13 完整标准 PDS 为 82.8726 MHz、WNS −0.302 ns、86 个 slow setup 失败端点、零未布通，频率验收失败。每次原始报告与输入哈希均独立保存，详见
工作区 `ITERATIONS.md` 9.6。

完成预选 `180f6fc` 的 r14b 已完成标准综合、place、route、route_optimize 和最终
STA：82.7423 MHz、WNS −0.321 ns、TNS −0.759 ns、5 个 slow setup 失败端点，
其余 11 类 STA 零失败，57,902 条网络全部布通。物理 40,954 LUT、32,318 FF、
36 DRM、4 APM；最差路径为 LSQ 转发选择到分支接纳，18 级、11.675 ns。
周期与 ISS 保持一致，频率仍未达标。place 用时 8 分 18 秒、内存池峰值 9,305 MB；
route 用时 11 分 32 秒，各阶段入口双 6 GiB 均通过，运行最小物理可用/提交余量为
8.272/0.682 GiB，无内存分配失败。源与报告绑定在
`logs/pipeline/preview-180f6fc-20261021/pds-result.json`。

本轮 `dffb8a2` 的 r15 标准 PDS 已完成：**85.2464 MHz、85 MHz WNS +0.034 ns、
TNS 0、零未布通**，12 类 STA 均无失败，57,382 条网络全部布通。物理为
40,154 LUT、32,318 FF、36 DRM、4 APM、77 IO；比 r14b 少 800 LUT，FF 不变。
相对 r14b，Fmax 提高 3.03%；比 CMP 的 87.8837 MHz 低 3.00%。
用户已确认按 8–10 级结构、CoreMark/MHz 不回退和标准 PDS ≥85 MHz 冻结 r15 为新 P0。
CMP 是 7 级 ALU 诊断点，不作为本次冻结门槛。原 `p0-acceptance.json` 保留当时
与 CMP 比频率的失败记录，原始数值和判据没有改写。发布基线为 `publish/p0-r15`，
发布仅含当前 P0 文件的一次提交，不带开发历史；原开发和历史阶段分支全部在
本地保留。后续 RTL 优化从独立分支开展。
r15 最差路径从 LSQ 地址比较，经 Store 转发资格、请求选择、提示完整标签和 IQ
匹配/数据选择到分支下一 PC，19 级、11.183 ns；逻辑 3.588 ns、布线 7.595 ns，
路径最高扇出 76。place 20 分 20 秒、峰值池 10,058 MB；route 11 分 28 秒，
route_optimize 1 分 4 秒。各阶段入口双 6 GiB 全部通过，实现期间采样最小物理
可用/提交余量为 6.129/0.464 GiB，无内存分配失败。综合为 37,678 LUT、32,188 FF、
36 DRM、4 APM、0 latch；226 项输入、212 个原生 HDL 和双 TCM 初值均通过。
同源结果为 `logs/pipeline/forward-format-dffb8a2-20261021/pds-result.json`；
原联合判据为同目录 `p0-acceptance.json`，其中对 CMP 的频率不回退项失败；
用户随后决定采用上述 P0 冻结依据，原报告保留。
35/73 项 I/O 延迟仍缺失，85 MHz 裕量为 0.034 ns，未验证板上运行。

## 2. 工具与目录

- PDS：`$PDS_HOME\bin\pds_shell.exe`。
- 工程根：`$PDS_WORK_ROOT\work\timing-YYYYMMDD-<topic>`，每次新目录。
- `reference/` 只读。
- 生成 IP、网表、工程、原始日志和报告都放 F:，仓库只保留源码、脚本和摘要。

运行前查 Windows 可用提交。常规 place 曾在 EP_DL 大块分配失败，历史快速布局
数据仅作对照。当前使用单线程标准 `place`，布线与优化保持 Normal 模式；
`r8-route4` 为复用同一布局的 4 线程布线实验，
不自动回退快速模式。不改分页、不终止无关进程、不烧板。

启动前先清理确认可丢弃的本项目遗留进程，避免与仿真、编译并发。
WSL 文件缓存也会占用 Windows 物理内存和提交余量；先对本项目非可执行生成
文件释放可丢弃缓存，保留源码、镜像、日志及数据库，再读取 Windows 字节计数。
WSL 的 `MemAvailable` 不能替代 Windows 指标；禁止将其他 agent 的任务当作遗留进程。
`memory_gate.ps1` 同时要求 Windows 物理可用量和提交余量至少 6 GiB，按原始
字节判断，查询失败即拒绝；更高的流程门槛通过 `HGB_PDS_MIN_PHYSICAL_GIB`、
`HGB_PDS_MIN_COMMIT_GIB` 保留，不能设为低于 6。每次查询保存独立 JSON。
暂存工程包含两个内存检查脚本及哈希；`implement.tcl` 在 dev_map、place、route、
route_optimize 前逐次检查。新工程用 `scripts/pango/run_phase.ps1` 的
`-Project <工程.pds> -LogDirectory <新日志目录> -Phase synthesis|implementation`
入口，`PDS_HOME` 指向 Windows PDS 安装目录。旧工程和旧日志保留原状。
入口在 Windows 本地工程目录运行，避免 UNC 工作目录限制。若继承的 `PATHEXT`
缺少 `.EXE`，仅为当前启动进程和 PDS 子进程临时补齐，完成后恢复；不修改用户或
机器环境。原生调用失败或没有有效退出码时不能算成功。可用
`tb/tools/test_pango_native_launch.ps1 -OutputDirectory <fresh-test-directory>`
在 Windows 实测这条启动路径、stderr 和失败退出码。
综合只接受尚无 `.pds` 的新目录；实现阶段仅传 `-file implement.tcl`，由 Tcl 打开
已综合工程，并先保存原生 `.pds` 副本。不能给实现阶段传 `-project_name`：该参数
会先强制新建同名工程，丢失设计输入列表。r11 的这次入口错误保留在工作区记录中，
后续使用新目录重新综合，不手工拼接不完整的原生工程。

## 3. 流程

```text
WSL loader 构建
  → prepare_project.py 暂存 RTL/IP/固件
  → verify_synthesis.py --staging-only
  → pds_shell compile + synthesize
  → check_tcm_init.py 核对 ITCM/DTCM INIT
  → dev_map -force_to_run
  → place
  → route
  → route_optimize
  → report_timing -max_path 100 -nworst 1
  → timing-summary.json
```

新后端暂存使用 `prepare_project.py --core-backend scoreboard`。schema 4 明确记录
i2、ROB16、IQ8、LQ4/SQ4、checkpoint4、p0/r0、IF64、双数据口与每 TCM 两 bank；
`--core-backend legacy` 保持 schema 3 的旧 i1 控制组。manifest 保存源码提交/分支、
工作树状态及每个暂存文件的 SHA，不能把暂存校验写成综合或时序通过。

原始 64 KiB `firmware/{i,d}mem.hex` 同时生成 `.bank0`/`.bank1`，按 XLEN 字
交错切分；校验器检查每份 bank 的哈希以及与原图像的逐字对应。
`check_tcm_init.py` 另从综合网表的地址/输出连线及全部 INIT 参数重建内容：
旧 RV32 使用 16K×2，新 RV32 为两个交错 bank，各八个 8K×4 DRM。
新 RV64 的 4K×8/9 模式由厂商模型及工具测试覆盖；r7 的实际 RV64 网表也已
完成两块 64 KiB TCM 的全字节校验，每块使用 16 个 DRM。
未知连线、缺失 INIT、重叠输出位均拒绝。`timing-20261021-p0-scoreboard-r2`
的 RV32 两个 TCM 各 64 KiB 已全部匹配；新旧映射及证据输出的八项工具测试通过。
新 RV32 配置综合映射为 36 DRM、4 APM、0 latch；RV64 为 38 DRM、12 APM、
0 latch。旧 RV32 控制组仍要求 34 DRM、4 APM，RV64 旧核映射尚未纳入校验入口。
`verify_synthesis.py` 按位宽和后端分别检查，41 项 PDS 交接工具测试通过。
r2/r3 的默认标准 place 均在 EP_DL 阶段内存分配失败，尚无有效布线时序结果。
r3b 的 `logic_optimize_lut_cascade` 被器件拒绝，未进入布局；通用帮助中的选项
不保证适用于本器件。r4 `769d739` 使用标准 `place -logic_optimize_lut6d FALSE`，
仅关闭 LUT 拼合，命令及资源/时序另列。综合为 41,182 LUT、31,381 FF、
36 DRM、4 APM、0 latch；两块 TCM 全部 INIT 匹配，布局仍在 EP_DL 内存失败，
峰值工具池 17,312 MB。关闭 LUT 拼合没有解决该失败。
后续独立关闭单元复制或宏优先仍在 EP_DL 内存失败。r7 `555453f` 的综合资源为
RV32 40,530 LUT / 31,682 FF，RV64 61,614 LUT / 44,319 FF；双宽均通过源输入、
资源与 TCM 初值核对。r8 `fdb3ffb` 对 ROB 完成到退休分拍，RV32 综合为
41,793 LUT、31,682 FF、36 DRM、4 APM、0 latch；最差路径从 29 级、
19.389 ns 降至 19 级、13.177 ns，综合 WNS −2.043 ns。源输入、TCM 初值通过。
RV32 标准 PDS 的首次启动因可用提交仅 2.663 GiB 而在运行前被脚本拦下，
该次没有启动综合。释放自有编译页缓存后重试完成，标准布局用时 12 分 6 秒，
工具池峰值 7,682 MB，运行前可用提交 9.327 GiB。单线程 route 第 8 轮耗时
818.903 秒、剩余 38,942 个未布通网络后人为中断；日志和进程身份记录均保留。
`r8-route4` 新目录复用原布局，228 项哈希核对通过，在 8.411 GiB 可用提交下
运行 `route -force_to_run -route_mode normal -number_of_router_thread 4`
并用 `-input_place_db_file` 显式指定复制的布局数据库。原 RTL、器件、IP、
85 MHz 约束均相同；该次布线后来按用户要求中断，没有最终时序。

`summarize_timing.py` 自动读取可选的 `placement-reuse.json`：核对原工程与新工程
全部源输入、网表、TCM 初值证据、布局数据库、原始布局日志的哈希；要求原工程
最后一次成功布局为默认标准 `place`，并确认新 route 实际使用该数据库及声明的
Normal 模式和线程数。原布局和新布线成功标记分别检查，缺一不能汇总成完成结果。
资源表的日志来源另存入摘要。新增 7 项布局复用拒绝/接纳测试后，PDS 工具共
48 项通过；未改变硬件。
`check_tcm_init.py --summary <new-json>`
可在两块 TCM 全部匹配后创建证据，绑定 manifest、网表和 HEX 哈希，拒绝覆盖已有报告。

新 P0 候选参数：`CORE_XLEN=32`、`MUL_IMPL=0`、`DIV_IMPL=1`、
`CORE_BACKEND=scoreboard`、`ISSUE_WIDTH=2`、`RETIRE_ENTRIES=16`、
`SOC_PROFILE=full`、`LOCAL_TCM_ENABLE=0`、
`DMA_WIDE_ENABLE=1`、`CACHE_BLOCK_ENABLE=1`、`DMA_BLOCK_ENABLE=1`。

## 4. 旧控制组完整布线结果

2026-10-20，源码 `c24ff08`，工程
`$PDS_WORK_ROOT\work\timing-20261020-i2-rv32`（参考机器的实际值见交接记录）。

| 指标 | 结果 |
|---|---:|
| 同域 Fmax（`ddrphy_sysclk`） | 65.4279 MHz |
| 125 MHz WNS | −7.284 ns |
| setup 失败端点 | 16614 / 78712 |
| 物理 LUT / FF | 24888 / 20140 |
| 综合 LUT / FF | 19033 / 20085 |
| DRM36K / APM | 34 / 4 |
| latch / 未布通 | 0 / 0 |
| 同域 hold | +0.061 ns |
| DDR PHY 跨域 | −0.061 ns |
| 外部 IO 约束 | 35 输入、73 输出缺失 |

与 `19562a9` 的 84.7314 MHz 相比下降 22.8%；LUT 增加 29.6%，FF 增加 56.2%。

关键路径：

```text
reset_sync_q[1]
  → retire_gpr_query
  → ex_operand_register
  → mul_unit/g_dsp.../Z
```

8 级逻辑，数据延迟 13.696 ns（逻辑 4.538、布线 9.158）。前 100 条 SoC setup
路径全部从 `reset_sync_q[1]` 出发。DDR IP 自身最差只有 −0.061 ns。

## 5. 旧端口默认值问题

PDS 2025.2 拒绝 SystemVerilog input 端口默认值，I2 有 89 处、23 个文件。
该旧检查点按原样不能综合；其结果来自 F: 暂存副本删除默认值后的版本，补丁在
`$PDS_WORK_ROOT\work\timing-20261020-i2-rv32\portability-patch.diff`。
`c04c588` 已将修正纳入仓库，当前 P0 从干净提交暂存并核对全部源哈希。

## 6. 十三轮 Fmax

| 轮次 | Fmax RV32/RV64 (MHz) | 主要代价 |
|---|---|---|
| 01 | 41.75/35.80 | 未单独测 |
| 02 | 47.57/38.96 | TCM 乘积 −4.9%/−7.5% |
| 03 | 43.39/33.87 | TCM 周期恢复 |
| 04 | 55.86/43.45 | TCM −70.8%/−71.5% |
| 05 | 55.78/45.61 | 基本不变 |
| 06 | 64.59/46.99 | Core-only −16.6%/−15.0% |
| 07 | 62.23/49.85 | Core-only −2.2%/−2.0% |
| 08 | 65.20/58.07 | 普通除法 +1–2 拍 |
| 09 | 73.56/60.16 | 不变 |
| 10 | 60.76/55.67 | Core-only −10.4%/−9.5% |
| 11 | 80.60/67.91 | 不变 |
| 12 | 68.39/63.15 | 不变 |
| 13 | 84.73/81.85 | 不变 |

十三轮说明：布线和布局对结果影响大；插寄存器不一定切断所有控制依赖；删掉一条
路径也不一定缩短全局最差路径。

## 7. 复位与资源

当前没有复位树或复位例外约束。`pango_200hp_top.sv` 的 `reset_sync_q[1]`
驱动全 SoC 同步复位；正常运行时是常数 0，STA 仍按数据路径分析。

可选：

1. 平衡复位树或分区复位同步器。
2. 异步复位、同步释放。
3. 有依据的复位例外，需要维护者审阅。

I2 物理 FF 20140，DMA 双 128B 缓冲、块桥读写缓冲、full 外设占比大。
建议拆 perf/full 两套 profile，i1 时完全裁掉第二 ALU/额外 RF 口。

## 8. 板级边界

- 125 MHz setup 未收敛，没有可交付 bitstream。
- DDR PHY 跨域只差 −0.061 ns，但外部 IO 约束仍缺 35/73。
- 没有真实 DDR 颗粒、校准、UART、ILA、功耗。
- 没有十秒 CoreMark。
- 100 MHz 方案需要重新生成 IP 或补 CDC，不能只改 FDC 数字。

## 9. 原始证据

历史工程在 `$PDS_WORK_ROOT\work\timing-20261016-*` 和 `timing-20261020-i2-rv32`。
当前流水拆分使用 `timing-20261021-pipe-head-r11b`、`pipe-completion-r12`、
`pipe-issue-r13`、`pipe-preview-r14b`、`lsu-forward-format-r15` 对应的新目录，
完整目录名见工作区记录；包含 manifest、网表、
原生工程、日志和时序报告。仓库不提交二进制、网表或原始工具报告。
