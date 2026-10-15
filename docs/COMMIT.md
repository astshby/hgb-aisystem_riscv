# 设计调整记录

## 2026-10-15（Asia/Shanghai）— 可复现综合 PR 与统一 demo 报告

- 按用户要求从最新 `origin/main`（PR #5 合并提交 `c2818ca`）新建 `codex/pango-reproducible-synthesis`，移入已评审的 `b8fbbb9` 产品基线；原分支和四份未提交文档逐字保存，未在 main 修改或 push。100 MHz 失败实验及下一轮 20 文件建议未恢复为产品代码。
- 两份重复板级报告合并为 `docs/FPGA_DEMO_REPORT.md`，统一目标、实现、改动文件、时序优化/回退、资源功耗、复现命令及实板缺口；保留原架构文档/阶段历史并更新链接。
- 新增 PowerShell 综合入口、WSL 参数调用辅助、固定 200HP HMIC_S 1.10 IDF 和综合/manifest 校验。隔离提取用户提供的 IP 包，不依赖历史生成目录；WSL 构建生产 loader 并暂存到 Windows 原生目录，原生 PDS 综合后才执行严格双 TCM INIT 与 34 BRAM/4 DSP/0 latch 门槛。修正 FDC 按实际字节计算哈希，增加实际 125 MHz/1000 Mbps 配置检查。新构建入口不需要 Windows Python，不运行 P&R/bitstream/JTAG。
- 工作树新目录重建通过：164 HDL、169 项文件字节哈希，RV32 综合 16,331 LUT/12,377 FF/34 DRM/4 APM/77 IO/0 latch，双 TCM 各 16 DRM、64 KiB 初值全量通过。manifest 字节篡改、TCM 单比特篡改、错误实际时钟三项负向验证均按预期拒绝，3 PASS/0 SKIP。干净克隆 `eacc4ab` 复建通过且 `source_clean=true`，其后仅修改 Markdown；完整双位宽回归通过：每宽度 43 unit + 17 directed PASS/1 位宽 SKIP，核心 ISA 58/78 PASS 各 2 SKIP，SoC ISA 59/79 PASS 各 1 SKIP；裸机/SoC CoreMark 各两模式、SoC directed 各 5、Cache 各 18、外设/DMA 软件各 1/2、基本 RT 各 7、UART loader 各 1 build + 2 runtime、RT DDR 四组、主机协议 19 和独立 bridge 双宽度均通过，其余 0 SKIP。确切范围及未运行项见统一报告。
- 100 MHz 实验 post-route 20,331 LUT/12,752 FF/34 DRM/4 APM，SoC/DDR WNS −11.147/−1.362 ns，已归档恢复；其映射代次例外和 reset recovery/removal 问题仍未解决。报告不把实验改进当成本 PR 的已采用时序优化，没有新实板或正式成绩。

## 2026-10-15（Asia/Shanghai）— 第六轮 execute-only fabric 实验，改善但未收敛并恢复七文件

- 用户明确批准七文件及相关 docs：从 `637527d` 重用第五轮 `ex_stage.sv/tb_decoder.sv/tb_ex_stage.sv` 专用 LSU 异常地址；在 `bus_interconnect.sv` 增加默认全零的 `EXECUTE_ONLY` 掩码，仅 `soc_top.sv` 的 IF master 0 启用。结构上排除该主端对 D-TCM/不可执行 MMIO 的 eligible 和载荷 mux 参与，保留 ERROR/ROM/I-TCM/DDR、通用默认行为、仲裁/锁定、D/DMA、响应归属、取指撤销与 FENCE.I；不增加流水周期或时序例外。另两文件 `tb_soc_fabric.sv/tb_dma_fabric.sv` 增加权限错误、ROM/DDR 取指和三主端交接检查。双宽度定向 **16 PASS / 0 SKIP**：每宽度 decoder/EX 2、fabric 通用/专用 × 两种优先级 4、DMA 通用/专用 2；fabric checks RV32/RV64 56/65，DMA checks 366/328，EX 地址检查 3,456/4,608，decoder 访存控制 2,048。
- m0d1 完整双位宽回归：`make test` 每宽度 **43 unit + 17 directed PASS / 1 位宽 SKIP**；核心 ISA RV32 **58/58**、RV64 **78/78 PASS**，各 2 策略 SKIP；SoC ISA **59/59、79/79 PASS**，各 1 策略 SKIP。裸机与 SoC smoke 各位宽各 **1 PASS**、CoreMark performance/validation 各位宽各 **2 个模式 PASS**；SoC directed 各 **5 PASS**，Cache 各 **14 unit + 4 软件 PASS**，外设/DMA 软件各 **1/2 PASS**，其余目标均 **0 SKIP**。裸机和 SoC CoreMark performance 同为 RV32 29 次/11,080,543 ticks/2.617200 CoreMark/MHz、RV64 26 次/11,051,172 ticks/2.352692；SoC performance/validation 总周期 RV32 `11125568/11172436`、RV64 `11092352/11129768`，与基线相同。
- UART loader 每宽度 **1 build + 2 runtime PASS / 0 SKIP**，周期 `356337/356454`；基本 RT-Thread 每宽度 **7 runtime PASS / 0 SKIP**，周期 `1339909/1348150`、DMA `984/976` B。完整 UART RT-Thread DDR 模型四组各两轮短时 CRC，**4 个集成用例 PASS / 0 SKIP**；DDR fetch RV32 performance/validation `56259/55912`、RV64 `57480/57688`，热退休数依次 `122068/122048/114366/113972`。使用数字 UART/AXI RAM，不能作为实际 DDR3、正式 FPGA 成绩或 ILA。基本 RT 宿主 O0、UART 宿主 O2；本轮未单独运行 `soc-lint`、独立 `mdu-backends` 或实板测试，共享 unit 已包含 backend 用例。
- 新增并发刺激最初要求连续 D 占用同一 bank 时 DMA 仍交接；同一刺激在 `637527d` 原 fabric 的 RV32 独立复现中也失败，证明是既有规则的限制。本轮按批准范围保持原仲裁，正式测试在每次 D 请求接受后留合法空拍，等待最后一次 D 握手后才停 valid，验证 DMA 进展和 IF 恢复。原 fabric/TB/源列表与两份复现日志保留，预期失败不计入上述 PASS，也不宣称修复无限连续 D 下的饥饿。
- F 盘 `F:\pango-project\work\soc-rv32-execute-only` 完成 PDS 2025.2-ads build 211867 ADS compile、RV32 synthesis、双 64 KiB TCM INIT、`dev_map/place -mode fast/route/route_optimize/report_timing`，均成功，**23,647/23,647 网络布通**；实现用时 48m48s。综合 **15,534 LUT、12,377 FF、34 DRM36K、4 APM、77 IO、0 latch**；物理布线优化后 **19,744 LUT（CLMA 14,615 + CLMS 5,129）、12,399 FF（9,237 + 3,162）、34 DRM36K、4 APM、77 IO**。125 MHz setup **WNS −16.716 ns、TNS −126245.980 ns、16,892/50,135 失败端点**，PDS Fmax **40.4596 MHz**，比正式基线改善 **0.909 ns**，仍未收敛。同域 hold +0.051 ns、0 失败，跨域最差 +0.041 ns、0 失败；至 `phy_dq_sysclk_0` setup −0.034 ns、TNS −0.068 ns、3/196 失败。最终 check timing 仍有 35 输入/73 输出缺外部延迟。
- 三条新最差路径不再到旧 MMIO 端点，且均不经过通用 ALU 比较器；首条 **I-TCM→fabric/D-Cache/WB→共用操作数前递/专用分支比较→流水/IF/I-Cache/fabric→DDR bridge 地址检查→write_data_q CE**，32 级、**24.264 ns 数据延迟 = 6.059 ns 逻辑 + 18.205 ns 布线（75.029%）**。报告中的 MDU operand 名称是共用操作数别名，不表示乘除法算术成为瓶颈。已有诊断只证明 WB→分支→IF 前缀可达，完整新路径仍未证明；合法 DDR 取指经过寄存填行且 IF 不写内存，因此下游 IF→DDR/write-enable 还有相关条件待核验。没有据此新增 false-path。逐段到达时间在工程 `path-analysis.md`。
- 同一 PDS 实现的官方实体归属表也已归档：其顶层为 **15,533 LUT、12,366 FF**，与物理 CLMA/CLMS 统计口径不同，不取代 19,744/12,399。实体表 Core 为 4,121 LUT/3,557 FF/4 APM，DDR IP 4,905/5,399，fabric 1,800/123，I$/D$ 610/369 与 1,203/762（各 1 DRM），I/D-TCM 各 16 DRM。父级包含子级，不能相加；两种表差异的具体原因尚未确认，原表及 `resource-breakdown.md` 完整保留，不把实体分项冒充可直接对账的物理占用。
- 使用 PDF 技能只读提取并目视复核板卡手册相关完整页面：仓库和候选 FDC 的 **73/73 DDR/参考时钟 LOC**、候选 IDF 的 **71/71 活动 PAD** 均匹配手册，含地址/Bank/DQS/DM/控制/CK；检查器、PDF/FDC/IDF 哈希及比较表在证据包。板厂声明相应 Micron 型号兼容，手册明确 DDR-VDDQ=1.5 V；仍需颗粒时序/IO 电气/PHY 和实际校准读写验证。本次 Windows 只读扫描仅枚举蓝牙 COM3–8，未检出 CP210x；这不是 JTAG 连接测试，也未打开串口或操作板卡。
- **49 份日志、98 项证据哈希、169 项暂存清单及七份测试源快照**核验通过。FDC 唯一清单差异仍为 CRLF/LF，规范化后内容一致。精确补丁 SHA-256 `51cefd64e1f0cc0e9d9429d4fcbd5834e72993fecdf5f2102b35a2a89ecdda27`；实现日志 `c13a3b11ce98e6def62ed6b5f4fb63eb607e959466ebdc4de925ab097496df85`；综合 `.vm` `dbefeba954150a9be47b186d2c223e663045032f913e4b9eb431f00b5044a03d`；布线优化 `.netlist` `7b294f3ea212294b37fd7716d73e4769daaf386b170061aefd76adfb8d434e2b`；原始时序 `da88b83ab05f3ffe6ccf70f99c983dc85f23983d37dc1fbd08ab0cb5ce4ced2e`。各哈希与准确文件名还见 `reports/key-hashes.json`。
- 按批准的失败回退条件，归档校验后 **仅将七个 RTL/TB 原子恢复到 `637527d` 的 Git blob，逐字节/非空/哈希核验通过**，保留本轮文档和 F 盘实验，不纳入正式基线。没有新功耗估算、bitstream、烧写、实板 DDR/UART/CoreMark 或 ILA，也未改/push main。下一方向建议以板上实际 27 MHz 时钟驱动 SoC、保留 DDR 用户时钟 125 MHz，并实现可验证 CDC/协调复位；原 demo 指导允许异时钟且未要求 CPU 125 MHz。该平台方案尚未获批或应用，具体范围和验证门槛见 [上板与报告](FPGA_DEMO_REPORT.md)。

## 2026-10-15（Asia/Shanghai）— 第五轮 EX 专用访存异常地址实验，路径转移但未收敛，恢复源码

- 用户在具体三文件方案后回复“继续”，批准从 `85552c8` 仅修改 `vsrc/core/execute/ex_stage.sv`、`tb/unit/tb_decoder.sv`、`tb/unit/tb_ex_stage.sv` 及相关文档。EX 用独立 `forwarded_rs1 + imm` 驱动访存异常 effective_address，原 out_packet.result、分支/MDU、握手及流水周期保持；没有增加寄存器或时序例外。译码测试每宽度穷举 131,072 组 opcode/funct3/funct7，全部 2,048 组访存控制满足 ADD/RS1/IMM/BR_NONE/XLEN。EX 地址/异常检查 RV32 **3,456**、RV64 **4,608** 项通过，覆盖符号立即数、XLEN 回绕、MEM/WB 前递优先级、store data、对齐 cause/完整 tval 及已有异常保留；四次定向测试 **4 PASS / 0 SKIP**。
- m0d1 双位宽完整回归：`make test` 各 **43 unit + 17 有效 directed PASS / 1 位宽 SKIP**；核心 ISA RV32 **58/58**、RV64 **78/78 PASS**，各 2 策略 SKIP；裸机 smoke 各 **1 PASS / 0 SKIP**，CoreMark performance/validation 各 **2 个模式 PASS / 0 SKIP**。SoC directed 各 **5 PASS**；Cache 各 **14 unit + 4 SoC 软件 PASS**；SoC ISA RV32 **59/59**、RV64 **79/79 PASS**，各 1 策略 SKIP；SoC 外设/DMA/smoke 各 **1/2/1 PASS**；SoC CoreMark 各 **2 个模式 PASS**，以上未另列 SKIP 的目标均 0 SKIP。裸机与无额外 IF 缓冲的 SoC CoreMark performance 均为 RV32 29 次/11,080,543 ticks/2.617200 CoreMark/MHz、RV64 26 次/11,051,172 ticks/2.352692，仍是模型结果。
- UART loader 数字模型每宽度 **1 build + 2 runtime PASS / 0 SKIP**，周期 RV32/RV64 `356337/356454`；基本 RT-Thread 每宽度 **7 runtime PASS / 0 SKIP**，周期 `1339909/1348150`、DMA `984/976` B。UART 下载 RT-Thread DDR 布局的四组（RV32/RV64 × performance/validation）各两轮短时 CRC，**4 个集成用例 PASS / 0 SKIP**；DDR 取指请求 RV32 performance/validation `56259/55912`、RV64 `57480/57688`，DMA `984/976` B。这是数字 UART/AXI RAM 模型，没有实际 DDR3 或至少 10 秒 FPGA 成绩。RV64 基本 RT-Thread 的首次宿主 O2 编译较慢，核实 PID 后仅终止本任务编译器，保留中断日志并以同 RTL/固件的宿主 O0 完成；UART 模型使用 O2。中断不计 PASS 或 RTL 失败。本轮未单独运行 `soc-lint`、独立 `mdu-backends` 目标或实板测试；共享 unit 回归包含 backend 用例，ADS/回归编译均通过。
- 10 月 14 日的 F 盘隔离工程 `F:\pango-project\work\soc-rv32-ex-address` 使用 PDS 2025.2-ads build 211867，ADS compile、RV32 synthesis、双 64 KiB TCM INIT 核验、`dev_map/place -mode fast/route/route_optimize/report_timing` 均成功，零未布通网络。综合后 **16,233 LUT、12,377 FF、34 DRM36K、4 APM、77 IO、0 latch**；布线优化后 **20,094 LUT、12,398 FF、34 DRM36K、4 APM、77 IO**。125 MHz 同域 setup **WNS −17.867 ns、TNS −161436.074 ns、17,443/50,750 失败端点**，PDS Fmax **38.6593 MHz**，相对正式基线 −17.625 ns **恶化 0.242 ns**。同域 hold 最差 +0.043 ns、0 失败；跨域 hold 最差 +0.041 ns、0 失败。`ddrphy_sysclk→phy_dq_sysclk_0` setup −0.046 ns、TNS −0.083 ns、2/196 失败；35 输入/73 输出仍缺外部延迟。
- 三个新最差同域 SoC setup 均不再经过通用 ALU 比较器，而经过专用分支比较器。首条从 D-TCM→fabric/D-Cache/WB→EX rs2 前递/分支→异常/流水与取指门控→I-Cache/fabric→SoC-info MMIO→维护 `fence_owner_q` CE，**30 级、25.156 ns 数据延迟 = 5.776 ns 逻辑 + 19.380 ns 布线（77.039%）**；后两条为 −17.858 ns 至 IRQ 响应及 −17.826 ns 至维护 fault_addr CE。此前合法 Load/BLTU 序列已证明 WB→分支→IF valid 可达，不能整体豁免；本轮下游 IF valid→不可执行 MMIO 则有独立权限互斥问题。
- 随后只在忽略目录创建不修改产品 RTL 的三主端 fabric 诊断：每宽度覆盖 20 项 IF 地址刺激、目标 4–13、busy/lock、三个 owner/next/locked-owner、response-valid、八种 pending 及四种 D/DMA valid；时钟停止并直接设定寄存器，包含不可达的目标局部状态组合，其他目标保持空闲，并非覆盖全部全局在途状态。固定 execute=1，切换 IF valid 的 **1,382,400 项**检查均不改变该目标 valid/完整请求/error；去掉 execute 的负对照确实改变 SoC-info 请求。双宽度合计 **2 PASS / 0 SKIP**。源码中 execute 取指仅允许 ROM/I-TCM/DDR，非法执行经 TARGET_ERROR；诊断支持按权限去除冗余仲裁依赖，但不是全部地址、Core/I-Cache 状态或 Pango 门级全路径形式证明，没有新增 false-path/multicycle。完整逐段分析和下一轮待批范围见工程 `path-analysis.md`。
- 归档精确三文件补丁 SHA-256 `47a9249e2f43bd49e4e811cdf33c266dba2c767ab93f105b7b6c110f4e1a7fc2`；已测试/暂存 EX 源码同为 `2f6be3a4193c05a2ccb8b2af052e89e6f80868f4f39f5f713a85601e4288364f`。实现日志 `f92dafe0748fc08b43d2455bc1eda93e82af45aaf02c013feff0f4a47ed45be0`，综合 Verilog `.vm` `5a1a79aabe9988b5d95ea4ded65eb9ff349382a8cb64321e37fb731ad49bc3e0`，布线优化 `.netlist` `262965ee284ee11c73a7779973b8e773c5121c90248d8a91a7099cbc0e8b5ab1`，原始时序 `0137263b0397028416f7903509b0185e33a4758c0229dc023f168fbb85dac662`。**39 份日志、76 项证据哈希、13 份测试/诊断源快照**校验通过。169 项工程清单中 168 项实际字节哈希一致，唯一 FDC 差异为 565 个 CRLF：实际 SHA-256 `f605e1be03fbb2ef856466a4cb0e39d4b254fd911510b7035d0639413c205df7`，仅转 LF 后与原清单 `ad99ec4e8dfea4ed718aa62aefb2999d6e90ae47fb65b2b9dc3df6754204fb52` 一致，另存差异记录，未改清单或约束内容。
- 按已批准的未收敛回退条件，核验完整当前差异与归档补丁相同后，**仅恢复本轮三个 RTL/TB 文件至 `85552c8` 的版本**，工作树不保留实验源码。收尾复核曾发现常规 restore 后三文件意外为空，随后从当前 HEAD 的 Git blob 原子写回并逐字节及 SHA-256 核验一致，未提交空文件。正式交付仍为原 `deliverables/rv32-synthesis` 与 `rv32-pnr-fast`；第五轮没有新功耗估算、bitstream、JTAG 烧写、实板 DDR/UART/CoreMark 或 ILA，未改/push main。下一轮拟将上述 EX 简化与 execute-only 主端的 fabric 结构裁剪组合验证，具体七文件范围须按根 `AGENTS.md` 另获批准，当前未应用。

## 2026-10-14（Asia/Shanghai）— 长路径可达性诊断，提出 EX 访存地址专用计算方案（待批准）

- 用户要求继续分析后，仅在忽略的 `build/timing-analysis/` 创建诊断，没有修改受维护 RTL/TB 或时序约束。以提交 `3c95e47` 为源码快照，复核第四轮 PDS 报告的三个同域 SoC 最差 setup：均为 D-TCM→WB/EX rs2→通用 ALU 比较器→访存地址对齐异常→IF/fabric 握手，WNS −16.208 ns，均未经过专用分支比较器。decoder 只有 LOAD/STORE 分支设置 mem_read/mem_write，并固定 ADD/RS1/IMM、BR_NONE；D1/D2 整包传递 uOp，Core HOLD 只更新操作数、CLEAR 仅清 valid。合法访存控制与 SLT/SLTU 地址结果、rs2 地址操作数互斥；通用 `alu_result` 却作为 `ex_exception_check.effective_address`，留下了这段冗余组合依赖。
- 诊断合计 **4 PASS / 0 SKIP**。RV32/RV64 各穷举 **131,072** 组 opcode/funct3/funct7，出现的 **2,048** 组访存控制均满足上述不变量，其中合法 RV32 1,024、RV64 1,408；合法访存地址/前递/异常 cause/tval 检查分别 **3,072 / 4,224 PASS**。人为把 Store 控制改成 SLTU/RS2 才复现“比较结果改变对齐异常”，该人为控制不算合法指令。真实 Core 的 LUI/LW/ADDI/BLTU 序列在两宽度第 15 拍均到达 Load WB PC=0x04、依赖分支 EX PC=0x0c；保持流水寄存器不动，返回数据 `0x10000000→0x20000000` 使 IF valid `1→0`，且仅发出一次 Load。故整体 WB→分支→IF 依赖确实可达，不能整体添加 false-path。
- 限度：这是源控制不变量、主控制字段穷举与零延迟 RTL 仿真，未穷举全部 32-bit 指令字、未完成门级全路径形式证明，也没有新 PDS、ISA/CoreMark 全回归或实板数据。首次 RV64 Core 诊断宿主 `-Os` 单文件编译较慢，仅终止已核实的本任务编译器并保留日志；同 RTL 改用输出分割/宿主 O0 后双宽度完成，不把中断当设计失败。F 盘 `F:\pango-project\work\timing-path-analysis-20261014` 保留两份诊断 TB、运行脚本、原始日志、路径摘要和方案；17 份归档文件及 10 份源 RTL 的 SHA-256 均校验通过。
- 待批方案仅涉及 `vsrc/core/execute/ex_stage.sv`、`tb/unit/tb_decoder.sv`、`tb/unit/tb_ex_stage.sv` 及既有相关文档：用独立 `forwarded_rs1 + in_packet.imm` 驱动访存异常的 effective_address，保持原 out_packet.result、分支/MDU、流水周期和协议；固化译码不变量，覆盖地址低位、符号立即数、XLEN 回绕、rs1/rs2 前递和 tval。它绕开通用 ALU 比较/移位/选择器，不增加流水寄存或 timing exception。获批后须做双宽度定向及根 `AGENTS.md` 全回归、相关 SoC/Cache/RT-Thread 回归、RV32 ADS 综合/TCM INIT/快速布局布线；若仍未收敛则归档并仅恢复实验 RTL/TB。当前仅完成分析与方案记录，尚未应用。

## 2026-10-14（Asia/Shanghai）— 第四轮 DDR bridge 请求寄存实验，末段切断但时序仍未收敛

- 用户在收到具体两文件方案后回复“继续”，批准只在开发分支修改 `vsrc/cpu/pango_ddr3_bridge.sv`、`tb/unit/tb_pango_ddr3_bridge.sv` 及相关文档。桥在 IDLE 锁存完整请求，握手后转入寄存的 PREPARE 状态，下一拍才做地址/权限/字节 lane 校验和 DDR IP 事务准备；旧 `ddr_req_valid→write_data_q CE` 同拍路径因此被切断。仍保持单笔在途、AXI AW/W/AR/R 接受顺序、无 B 通道语义、响应反压与错误码。每笔请求增加一拍；新单元测试验证上游请求改写、忙时第二笔拒绝及 PREPARE 中复位丢弃。
- 双位宽 m0d1 测试：桥接定向各 **1 PASS、9 checks / 0 SKIP**；`make test` 各 **43 unit + 17 有效 directed PASS / 1 位宽 SKIP**；核心 ISA RV32 **58/58**、RV64 **78/78 PASS**，各 2 策略 SKIP；裸机 `benchmark-smoke` 各 1 PASS、CoreMark performance/validation 各 2 PASS。`make soc-test` 各 **5 PASS / 0 SKIP**；`make cache-test` 各 **14 个 Cache/维护单元 + 4 个 SoC 软件 PASS / 0 SKIP**；UART loader 数字 SoC 模型各 1 build PASS、2 runtime PASS。裸机 CoreMark 仍为 RV32 29 次/11,080,543 ticks/2.617200 CoreMark/MHz、RV64 26 次/11,051,172 ticks/2.352692 CoreMark/MHz。SoC/Cache/loader 模型不实例化本板级 bridge，不能把其 PASS 当作真实 DDR 桥接或实板证明。本轮未重跑 SoC ISA、SoC CoreMark、完整 RT-Thread UART 下载模型或实板测试；共享 RTL 的根 `AGENTS.md` 必需双位宽目标已运行。
- F 盘隔离工程 `F:\pango-project\work\soc-rv32-bridge-register` 用 PDS 2025.2-ads build 211867 完成 ADS compile、RV32 synthesize、双 64 KiB TCM INIT 逐字核验、`dev_map/place -mode fast/route/route_optimize/report_timing`，均退出码 0、零未布通网络。暂存 bridge RTL SHA-256 与已测试工作树同为 `1f2a35c2ea79c18767b12aadf32b3cd7ee4fcb5f2d3b70057be025c28b48d8eb`。综合后 **16,408 LUT、12,449 FF、34 DRM36K、4 APM**；布线优化后 **20,272 LUT、12,500 FF、34 DRM36K、4 APM、77 IO**。125 MHz `ddrphy_sysclk` setup **WNS −16.208 ns、TNS −130609.328 ns、15,487/51,273 失败端点**，Fmax **41.3087 MHz**；同域 hold 最差 +0.050 ns、0 失败端点，`ddrphy_sysclk→phy_dq_sysclk_0` setup −0.085 ns、5/196 失败。35 输入/73 输出仍缺外部延迟。相对正式基线 −17.625 ns，最差 setup 改善 **1.417 ns**，但远未达到 125 MHz。
- 新最差路径不再到 bridge `write_data_q`，而从 D-TCM DRM 读出经 fabric/D-Cache/WB、EX 旁路与异常/流水控制、维护/取指门控、I-Cache/fabric 请求-就绪反馈到 IF `request_q[166]` CE；25 级逻辑、23.563 ns 数据延迟（逻辑 5.742、布线 17.821 ns，占 75.6%）。旧路径的桥内末段确已切断，上游长链仍在。上一轮“当前 IF 旁路→DDR”段在 I-Cache 启用且合法 DDR 取指可缓存时可能互斥，但此轮新路径也涉及 ROM/TCM 取指；尚无完整可达性证明，不增设虚假的 false-path 约束。逐段到达时间及判断见 F 盘 `path-analysis.md`。
- 完整实现日志 SHA-256 `dc3a548082a8dcefa65b19c980333cd949e918c716a5d72b9bbfb34724ee327f`；综合网表 `8868a4aa4a570d2bb8ec18f5280fa89deff0fa9863d02b972a0a01bb01d1e1e2`、布线优化网表 `09edf0f87a030c0b9eff9471ea5c445ac43652487a77e497f525155180246d2d`，原始时序报告 `41cab6f4adccf061d974305c794e6b8a42db77fabd88b3f20a6102ec13b59c89`。精确两文件差异 `bridge_request_buffer_experiment.patch` SHA-256 `a9e7662c05c25d0290f566677996fc4ae4d8ee3dcd1788840c68763bef0fa076`；十份关键验证日志和 `files.sha256` 已逐个校验。按用户批准的失败回退条件，实验 RTL/TB 仅在 F 盘保留，Git 中恢复到本轮前提交；不纳入正式基线。未做此失败候选的新功耗估算、bitstream、JTAG 烧写、实板 DDR3/UART/CoreMark 或 ILA，也未修改/push main。

## 2026-10-14（Asia/Shanghai）— 第三轮组合边界时序实验，未收敛并恢复源码

- 用户批准在开发分支只改 `vsrc/soc/bus/bus_interconnect.sv`、`vsrc/soc/soc_top.sv`、`tb/soc/tb_soc_fabric.sv`、`tb/soc/tb_dma_fabric.sv`、`tb/soc/tb_soc_benchmark.sv` 及相关文档。实验组合 IF→I-Cache 单项请求缓冲与 fabric 目标请求缓冲，但后者仅作用于 IRQ 目标 5、GPIO 目标 9–11。已接受旧取指仍完成并由 IF kill 丢弃；FENCE.I 的 I-Cache 失效改为寄存待发脉冲，等旧请求进入 I-Cache 后执行，期间不接收新取指。仲裁、反压、响应 owner 与非目标路径保持；取指和选中 MMIO 请求各增加一拍。
- 双位宽 m0d1 验证：`make soc-test` 各 **5 PASS / 0 SKIP**，`make cache-test` 各 **14 个 Cache/维护单元 PASS + 4 个 SoC 软件 PASS / 0 SKIP**，取指反压/FENCE.I 专项各 **1 PASS / 0 SKIP**（4 拍阻塞、1 次重叠）；`make test` 各 **43 unit + 17 有效 directed PASS / 1 位宽 SKIP**。核心 ISA RV32 **58/58**、RV64 **78/78 PASS**（各 2 策略 SKIP）；SoC ISA RV32 **59/59**、RV64 **79/79 PASS**（各 1 策略 SKIP）。裸机/SoC `benchmark-smoke` 各位宽各 1 PASS，裸机/SoC CoreMark performance、validation 各位宽各 2 PASS；SoC 外设各 1 PASS，DMA 无 DDR/64 KiB DDR 各 2 PASS。SoC CoreMark RV32 17 次/11,327,102 ticks/1.500825 CoreMark/MHz，RV64 15 次/11,322,896 ticks/1.324749 CoreMark/MHz，均为模型成绩。`soc-lint` 未单独运行；ADS compile 与上述测试编译通过。
- UART loader 双位宽各通过构建及运行（RV32/RV64 周期 359,639/360,011）。UART 下载 RT-Thread DDR 布局的 RV32/RV64 × performance/validation 四组均各通过两轮短时 CRC；热代码 DMA 为 984/976 B，DDR 取指请求依次 56,864 / 57,200 / 57,896 / 58,256。使用数字 UART/AXI RAM 模型，不能当作板载 UART/DDR 或至少 10 秒正式分数。11 份关键测试日志及 `files.sha256` 位于 F 盘实验工程 `validation/`，已逐文件校验。
- `F:\pango-project\work\soc-rv32-combined-boundaries` 的 PDS 2025.2-ads build 211867 ADS compile、RV32 synthesize、双 64 KiB TCM INIT 逐字核验、`dev_map/place -mode fast/route/route_optimize/report_timing` 均退出码 0，零未布通网络。综合后 **16,130 LUT、12,604 FF、34 DRM36K、4 APM**；布线优化后 **20,133 LUT、12,625 FF、34 DRM36K、4 APM、77 IO**。125 MHz `ddrphy_sysclk` setup WNS **−18.681 ns**、TNS **−143788.833 ns**、15,275/51,745 失败端点，PDS Fmax **37.4799 MHz**；最差 hold +0.041 ns、0 失败，DDR PHY 跨域另有 −0.012 ns。35 输入/73 输出缺外部延迟。相对正式基线 −17.625 ns，最差 setup **恶化 1.056 ns**。
- 最差路径为 fabric `owner_q[1][0]` 经 D 响应、Core EX 分支、Cache 维护/I-Cache/fabric 请求组合链，到 DDR bridge `write_data_q[26]` CE；26 级逻辑、26.042 ns 数据延迟，其中布线 21.648 ns（83.1%）。快速模式完整日志 SHA-256 `11dda87a3a95b2724288bbeab31b6d1115ab60f5aac224278b80db8a5d5dfe16`，综合/布线优化网表分别为 `ffa28700467e8d5a8ce599c56ef996bdcab776c6e1ed7729f1053d496de8ec91` / `ce5bbbd0c4986ef676b9099f9364719b1f18c8cffa25b8523a1a7de94b5676fa`。首次实现误用暂存工程默认常规 `place`，Stage 2 提交内存增长时只终止该 PDS 子进程；其内部错误退出**不作为实现失败结果**。随后只改 F 盘副本 Tcl 为 `place -mode fast`，以上统计仅取完整重跑。
- 精确五文件差异存于 F 盘 `combined_boundaries_experiment.patch`（SHA-256 `db5eb249e7b5a4923d64856ff1fe63c051f478c24cccefc30115fe6107ebd554`），工程 `README.md` 标明未保留。按获批失败回退条件，**五个实验 RTL/TB 文件已逐一恢复至已提交基线，工作树无实验源码差异**；正式交付仍是 `deliverables/rv32-synthesis` 和 `rv32-pnr-fast`。未给失败候选做新功耗估算、bitstream、JTAG 烧写、实板 DDR3/UART/CoreMark 或 ILA。main 未修改、未 push。下一轮需针对响应→取指→DDR bridge 跨模块握手/写数据使能路径另定行为、文件与验证方案，按根 `AGENTS.md` 审批后再改 RTL。

## 2026-10-14（Asia/Shanghai）— 第二轮 IF 请求缓冲实验，部分改善但未收敛并恢复源码

- 用户批准在开发分支仅修改 `vsrc/soc/soc_top.sv`、`tb/soc/tb_soc_benchmark.sv` 及相关文档。SoC 在 IF→I-Cache 之间增加单项寄存请求缓冲，让 IF ready 由本地空位决定；已接受的旧请求继续送入 I-Cache、由 IF kill 逻辑丢弃响应。若 FENCE.I 发生在槽内尚有旧请求时，先等它进入 I-Cache 再失效标签，并阻止新 IF 请求越过失效边界。该方案给每笔取指增加一拍，未改 Core、Cache、fabric、DDR IP、固件或约束。定向 TB 用同步抑制输出 valid/ready 的刺激制造 4 拍反压和 1 次 FENCE.I 重叠，并逐沿检查请求地址、RV64 lane、失效顺序及无重复/丢失。
- 双位宽功能结果（`MUL_IMPL=0 DIV_IMPL=1`）：`make soc-test` 各 **5 PASS / 0 SKIP**；`make cache-test` 各 **14 个 Cache/维护单元 PASS、4 个 SoC 软件 PASS / 0 SKIP**；队列反压/FENCE.I 定向仿真各 **1 PASS / 0 SKIP**，均确实覆盖 4 拍 ready 反压和 1 次重叠。`make test` RV32 **60 PASS / 1 位宽 SKIP**（43 unit、17 directed），RV64 **61 PASS / 1 位宽 SKIP**（43 unit、18 directed）；核心 ISA RV32 **58/58**、RV64 **78/78 PASS**（各 2 策略 SKIP），SoC ISA RV32 **59/59**、RV64 **79/79 PASS**（各 1 策略 SKIP）。裸机与 SoC `benchmark-smoke` 各位宽各 1 PASS，CoreMark performance/validation 各位宽各 2 PASS，`soc-software` 各 1 PASS、`soc-dma-software` 的无 DDR/64 KiB DDR 各 2 PASS；`soc-lint` 双位宽通过。SoC CoreMark performance：RV32 17 次/11,327,102 ticks/1.500825 CoreMark/MHz，RV64 15 次/11,322,896 ticks/1.324749 CoreMark/MHz，均非 RT-Thread 实板成绩。
- SoC UART loader 小包 RV32/RV64 各有 loader build 1 PASS、运行 2 PASS，周期 359,639/360,011。完整 RT-Thread DDR 布局经 UART 下载的 RV32/RV64 × performance/validation **4 组**均完成 **每组两轮短时 CRC PASS**；RV32/RV64 DMA 分别 984/976 B，DDR fetch 依次为 56,864 / 57,200 / 57,896 / 58,256（按 RV32 performance、RV32 validation、RV64 performance、RV64 validation 排列）。仿真使用 AXI RAM 模型；未运行至少 10 秒的实板正式分数。
- F 盘隔离工程 `F:\pango-project\work\soc-rv32-fetch-queue` 的 PDS 2025.2-ads build 211867 ADS compile、RV32 synthesize、双 TCM INIT 逐字核验、`place -mode fast`、route、route_optimize、report_timing 全部成功，零未布通网络。综合后 **16,499 LUT、12,382 FF、34 DRM36K、4 APM**；布线优化后 **20,487 LUT、12,403 FF、34 DRM36K、4 APM、77 IO**。125 MHz `ddrphy_sysclk` setup **WNS −17.040 ns、TNS −157579.064 ns、17,064/50,354 失败端点**，PDS Fmax **39.9361 MHz**；最差 hold +0.041 ns、0 失败端点，DDR PHY 交叉另有 −0.004 ns。相对未改基线 −17.625 ns，最差 setup 改善 **0.585 ns**，但仍严重不收敛。最差路径从 fabric `owner_q[5][0]` 经 D 响应、Core EX/重定向、Cache 维护门控与 I-Cache/fabric 请求逻辑，最终到 GPIO 输出 `[16]` CE；26 级逻辑、24.399 ns 数据延迟（逻辑 3.493 ns、布线 20.906 ns，占 85.7%）。35 输入/73 输出仍缺外部延迟约束。
- 实验完整日志 SHA-256 `55683ef17e8451ec713a951c7055929b15833ba973002fa2a6435abec8af2b46`，布线优化网表 SHA-256 `f2f992e5dcce4b8d571399ac067eefd65d1d108c368e4bcdb149f34c18b16c14`。`F:` 工程内 `fetch_queue_experiment.patch` SHA-256 `5a6094865ac6710c62876c2b2bdf8e03e58979c12558ba784741447eaad17510` 保留精确 RTL/TB 差异，`README.md` 明示未保留。PDS 暂存的 `soc_top.sv` 与测试时的工作树 SHA-256 均为 `dc0bbd9b5e9b6d6aea7f6036a2a79cbd2bd4baa515be910ecbd6565f8ec70cd7`。
- 按用户批准的失败回退条件，**只恢复本轮两个 RTL/TB 文件到已提交基线**，不把较慢取指且远未收敛的候选纳入源码；开发分支记录仅更新文档，main 未修改或 push。本候选未做新功耗估算、bitstream、JTAG 烧写、实板 DDR3/UART/CoreMark 或 ILA。下一条路径横跨 fabric、Core 重定向与 I-Cache 请求门控，不能只根据 GPIO 端点定位修复；修改前须另提文件与协议方案、按根 `AGENTS.md` 等待批准。

## 2026-10-14（Asia/Shanghai）— 获批外设请求寄存实验，时序未改善并恢复源码

- 用户批准在开发分支仅改 `vsrc/soc/bus/bus_interconnect.sv`、`vsrc/soc/soc_top.sv`、`tb/soc/tb_soc_fabric.sv`、`tb/soc/tb_dma_fabric.sv` 的第一轮实验：目标 4–13 外设请求、错误码与 owner 寄存一拍；其他目标、响应归属、仲裁优先级和未接受 IF 请求撤销保持。新 MMIO 访问增加一拍。实验文件先暂存进 `F:\pango-project\work\soc-rv32-registered-mmio`；**时序未收敛后，Git 中这四个实验文件逐一恢复到此前已提交版本，没有把实验 RTL 纳入交付源码或修改 main**。F 工程和其 `README.md` 保留原始实验实现/报告，明确标为未保留。
- 功能验证：`make soc-test` RV32/RV64 各 **5 PASS / 0 SKIP**；`make test XLEN=32/64 MUL_IMPL=0 DIV_IMPL=1` 各 **43 unit PASS、17 directed PASS、1 位宽 SKIP**；`riscv-tests` RV32 **58/58**、RV64 **78/78 PASS**，各 2 策略 SKIP；`benchmark-smoke` 各 **1 PASS / 0 SKIP**；`coremark` 各 performance/validation **2 PASS / 0 SKIP**，m0d1 周期与旧基线相同。SoC UART loader RV32/RV64 各 **2 行运行 PASS / 0 SKIP**，周期 356433/356575。RV32 UART RT-Thread CoreMark performance/validation 各两轮短时 DDR 模型 CRC PASS，DMA 984 B，DDR fetch 56,168/55,912；完整包 45,807/45,815 B。尚未运行 RV64 完整 UART RT-Thread 下载或实板测试。本轮生产 SRT 配置的共享 RTL/ISA/benchmark 回归已跑；无 RTL 变更的当前 Git 基线沿用原先记录。
- 工具过程限度：不指定 `RISCV_TOOL_ROOT` 的首次 ISA 尝试因 `/opt/riscv/bin` 不存在报 58 个编译失败；用已有 `build/toolchain/bin` 符号链接指向系统 `riscv64-linux-gnu-*` 后双位宽全通过，未改上游 ISA clone。默认 DIV_IMPL=0 的 `make test XLEN=32` 在 `tb_muldiv_backends` 高优化 C++ 编译持续约 16 分钟时只终止本任务编译器，前 28 项 unit 已通过；随后生产 m0d1 的双位宽 O0 宿主构建完整通过。RV32 完整 UART O0 宿主仿真运行约 7 分钟只到首段 1,076 B，保留部分日志并仅终止该仿真；同 RTL/固件 O2 宿主构建完成 performance 与 validation，各两轮 CRC 通过。中断尝试均不计 PASS。
- PDS 2025.2-ads build 211867：RV32 ADS 编译、综合、双 TCM INIT 逐字校验、快速布局、route、route_optimize、report_timing 全通过，零未布通网络；综合后 **15,739 LUT、12,921 FF、34 DRM36K、4 APM**，布线优化后 **19,899 LUT、12,971 FF、34 DRM36K、4 APM**。125 MHz `ddrphy_sysclk` setup **WNS −18.573 ns、TNS −118155.795 ns、13,851/52,972 失败端点**，Fmax **37.6322 MHz**；hold 最差 +0.041 ns、0 失败。原基线 −17.625 ns，因此最差 setup 恶化 **0.948 ns**，尽管总体违例数减少。新最差路径为 I-TCM→WB/EX 分支重定向→IF/I-Cache/fabric 握手→IF 请求寄存器 CE，30 级逻辑、25.994 ns 数据延迟（布线 20.121 ns）。完整日志 SHA-256 `c0ce843b6f1a7cb1f3aa553e37222706421cea68e1acc4f30bd87ae2aa891a60`，布线网表 SHA-256 `f3128d237234a2f42075865717763f952fa86543a4884ed352fab9d07900f47d`。
- 结论：第一轮寄存外设请求只切断原关键路径的末段，未解决更早的响应/重定向/取指握手长链。没有为该失败候选生成 bitstream、追加功耗结论、连接 JTAG、烧写、push 或宣称实板成绩。按用户批准条件不扩大 RTL 范围；下一轮需明确新的行为和文件并依据根 `AGENTS.md` 再获批准。

## 2026-10-14（Asia/Shanghai）— RV32 快速布局布线、时序与条件功耗

- 32 GiB F 盘分页已在重启后实际生效；同一 RV32 网表的单线程常规 `place` 仍于 Stage 2 EP_DL 申请 2,127,036,416 B 时内存分配失败，20m52s、PDS 峰值池 22,897 MB，route 未开始。完整日志及 SHA-256 见 [上板与报告](FPGA_DEMO_REPORT.md)。没有据此增加分页或声称常规模式可用。
- 按厂商 Tcl 手册把 F 盘工程复制为隔离的 `soc-rv32-fast-place`，综合网表哈希保持 `82624f5494a73058300a550906f3f3a4b7f3407019dc01cc93cf342e11702e44`，仅在该副本选择 `place -mode fast`。PDS 2025.2-ads build 211867 的 `dev_map/place/route/route_optimize/report_timing` 全部完成，退出码 0、零未布通网络；完整日志 SHA-256 `46ee97d99f4f401cab9b0612384cab0c02614364d81d373900e71acb86a68af7`。这只是离线可布线，不等于可上板。
- 布线优化后 **20,272 LUT、12,427 FF、34 DRM36K、4 APM、77 IO**。125 MHz `ddrphy_sysclk` 域 setup WNS **−17.625 ns**、TNS −158094.574 ns、16,949/50,345 失败端点，工具报告 Fmax 39.0244 MHz；最差 hold +0.019 ns、0 失败端点。最差 setup 为 D-TCM 读出经 WB/EX 组合控制到 IRQ 优先级寄存器 CE，28 级逻辑、24.943 ns 数据延迟（其中布线 19.030 ns）。另有 35 个输入/73 个输出没有对应 IO 延迟约束，不能以放宽或忽略时钟约束代替修复。
- PDS Power Calculator 对该未收敛布线候选的片上条件估算：内部默认翻转率 10%/20% 时 **2.276/2.332 W**，相应静态 0.865/0.870 W、差值动态 1.411/1.462 W；25 °C、Typical/Production、默认 5 pF 负载及其他默认活动率，置信度 Low（超过 75% 输入活动未指定）。默认 12.5% 场景为 2.290 W。PDS 拒绝 `-prob` 的初次试验未计为有效场景。均非整板/DDR3/CPU 实测。
- 在 `F:\pango-project\deliverables\rv32-pnr-fast` 另存网表、约束、IP、镜像、完整日志、资源/时序数据库及功耗 PPR/PPS；30 个源文件与工作工程逐个 SHA-256 相同，索引 `files.sha256/files.json`。同步 README 和两份英文名报告；本轮无 RTL/固件/约束源修改，无新仿真回归（既有 PASS 记录沿用）。未生成 bitstream、连接或烧写 JTAG、取得板级 UART/DDR/CoreMark/ILA 数据、修改 main 或 push。下一步须在受保护阶段修改前先提交具体时序修复范围供审批，完成外部 IO/颗粒核对与时序收敛后再谈上板。

## 2026-10-13（Asia/Shanghai）— 英文报告名、备份清理与 32 GiB 布局准备

- 用户把近期阶段门槛定为可核验的 RV32 整机综合完成，仍要求继续尝试布局和推进总体实板 demo。已有综合报告、网表及双 TCM INIT 核验保留；不能将综合数字写成 post-P&R、实板或功耗成绩。
- 再次从 F 盘启动 Ubuntu-22.04，验证开发分支干净、工具可运行及发行版注册路径指向 `F:\WSL\Ubuntu-22.04` 后，仅删除 `F:\WSL\backups\Ubuntu-22.04-before-20261013.vhdx` 导出备份（19,184,746,496 B）；活动 ext4.vhdx 保留。
- 按用户最新要求把 F 盘 Windows 分页由固定 16 GiB 设置为固定 32 GiB，C 盘仍系统管理。设置值与注册表已核对；即时实际分配仍为 16 GiB，等待用户手动重启并在重启后复核再重试 PDS。将两份阶段报告改为英文文件名 `FPGA_DEMO_GOALS_AND_PROGRESS.md`、`PANGO_BOARD_VALIDATION_AND_REPORT.md` 并更新内部链接。未改 RTL、`vsrc/` 布局或参考工程。

## 2026-10-13（Asia/Shanghai）— 工作目录迁移与文档归并

- 使用 WSL 官方 `--manage --move` 将 Ubuntu-22.04 从 C 迁至 `F:\WSL\Ubuntu-22.04`；先导出并校验 F 盘 VHD 备份。迁移后注册路径、默认用户、分支 HEAD 及 482 个受 Git 跟踪文件 SHA-256 均相同，WSL 交换文件指向 F 盘。
- 按用户最终选择，Windows 保留 C 系统管理分页，F 盘固定 16 GiB；查询时 F 分页已分配 16,384 MiB。没有自动重启。原 RV32/RV64 与候选 DDR IP 工程共 666 文件复制到 `F:\pango-project\work`，逐文件 SHA-256 比较一致；C 原件和 F 的 `reference` 未动。
- 将本开发阶段新增的四份说明归并为 [目标与进度](FPGA_DEMO_REPORT.md) 和 [上板与报告](FPGA_DEMO_REPORT.md)，保留原有文档及历史记录，仅更新其导航链接。200HP 手册与参考例程继续用于颗粒、管脚和时序核对；尚未上板、烧写或取得正式成绩。
- 后续在 F 盘副本备份并重写六个配置文件中的 C 绝对路径，`rebased-config.json` 记录原件/改写哈希；RV32/RV64 全部 `add_design/add_constraint` 输入解析为 F 本地存在的文件。运行 RV32 离线实现，`dev_map` PASS，place 在 Stage 2 EP_DL 申请 `1,398,800,384 B` 时再次内存分配失败，实际耗时 10m09s、峰值池 20,941 MB；route 未执行，未获得 post-P&R 资源/时序。日志及 SHA 见新上板文档。不改 RTL、C 原工程或原 reference，不生成 bitstream、烧写或 push。

## 2026-10-13（Asia/Shanghai）— 离线实现入口与布局内存限制

- 新增 `scripts/pango/implement.tcl`，由暂存器复制到原生 Windows 目录；通过 `HGB_PDS_PROJECT` 打开既有综合工程，只执行 device map、place、route、route_optimize、report_timing。已核实 CLI `-project/-file` 互斥、`open_project` 无 `-in_process`、skipped 动作会终止批处理，入口以 `dev_map -force_to_run` 重做映射，缺省 `HGB_PDS_THREADS=1` 可覆盖；不生成 bitstream、不连接 JTAG。
- RV32 device_map 成功，place 三次均在 Stage 2 EP_DL 分配失败，峰值池依次 `15,035 / 18,536 / 20,167 MB`，失败请求 `675,807,232 / 676,855,808 / 844,103,680 bytes`。后两次采用单线程，第三次在缓存回收完成后于沙箱外执行。route/report_timing 未到达；**无 post-P&R PASS、资源或时序成绩**，不是 RTL 功能断言失败。
- 仅对本仓 build/logs 内、排除符号链接的生成文件发出 POSIX_FADV_DONTNEED 建议，45,494 个文件、磁盘共 9.87 GiB，无文件内容变更或删除。WSL缓存约 5.8 GiB 降至 248 MiB，未结束其他用户程序、未关闭 WSL。只读核验 RAM 约 31.5 GiB、C 盘系统分页约 14.5 GiB；重试期间提交内存接近耗尽，分页自动扩展使 C 空闲低至约 256 MiB，结束后恢复约 9 GiB。F 空闲约 272 GiB，分页扩容方案留待明确批准，未修改系统设置，不继续无条件重复布局。
- 综合报告 SHA-256 `a8b1c42b880c25ccc8cd28557dc5491dd0979bbdbf5e559b66c8163413bf0b95`，综合网表 `82624f5494a73058300a550906f3f3a4b7f3407019dc01cc93cf342e11702e44`；初值校验与上述资源均对应这个 RV32 m0d1 候选。原始文件和三次日志保留于本机 `pds-soc-rv32-compat/`，生成物不入 Git。
- 2026-10-13 只读复核远端：PR #5 MERGED，合并于 2026-09-30 18:15:11（Asia/Shanghai），合并提交及当前远端 main 均为 `c2818ca6200875ebf59013e671a1e5cc968b29a3`。当前开发工作未 push 或更新 PR。整体状态、成果/缺口、下一步及分页配置提案已写入阶段总结。

## 2026-10-13（Asia/Shanghai）— 获批 ADS 等价适配、双位宽回归与 RV32 综合

- 用户明确批准四文件范围后，仅修改八处声明：`tcm_controller.sv/soc_top.sv/pango_200hp_top.sv` 的五个文件名参数由 typed string 改为同值 untyped；`core_types_pkg.sv` 的三个宽度 typedef 改为 `core_config_pkg::` 限定引用。未改默认文件值、位宽、协议、流水/缓存/DMA 行为，保留全部头部和既有注释。
- m0d1 的 `make test XLEN=32/64` 均完成：每位宽 **43 unit PASS、17 directed PASS、1 位宽 SKIP**，原有非致命 lint warning 保留。`make riscv-tests` RV32 **58/58 PASS**、RV64 **78/78 PASS**，每位宽各 2 策略 SKIP（Core-only fence_i/ma_data）；上游 clone 未修改。
- `make benchmark-smoke` 两位宽各 **1 PASS / 0 SKIP**；`make coremark` 各 performance/validation **2 个模式 PASS / 0 SKIP**。RV32 29 次、计时周期 `11,080,543`、`2.617200 CoreMark/MHz`；RV64 26 次、`11,051,172`、`2.352692 CoreMark/MHz`，与适配前相同，仍是裸机仿真结果。
- 针对初始化类型和热路径：小程序 UART loader 两位宽各 **1 行构建 PASS + 2 行运行 PASS / 0 SKIP**，周期 `356,337/356,454`；RT-Thread BSP 两位宽各 **7 行运行 PASS / 0 SKIP**，周期 RV32 `1,339,909`、RV64 `1,348,150`，DMA `984/976` B、热退休 `22,381/21,672`、trap 均 39 次。RV64 首次宿主 O2 编译单文件耗时超过 13 分钟，核对 PID/工作目录后终止该编译器，保留中断日志，换 O0 完成同 RTL/固件的测试；中断尝试不记 PASS 或设计失败。没有重复完整 RT-Thread UART 长下载测试；该链路仍引用上一阶段四组结果。
- 本机 PDS 2025.2 build 211867，RV32/RV64 整机 ADS compile 各 **1 成功 / 0 SKIP**，均导出 DB；原先大量枚举赋值错误为连带错误，未额外改枚举。RV32 synthesize 成功（3m34s，峰值池 1,224 MB）；整机含 DDR IP 综合后为 **LUT 16,331（logic 16,136 / distributed RAM 195）、registers 12,377、latch 0、DRM36K 34、APM 4**。来源 `pango_200hp_top.snr`，不是 post-P&R 数字或时序通过证明。
- 新增 `scripts/pango/check_tcm_init.py`，按当前 RV32 x2 DRM 的 INIT 和实际地址/数据连线重建两个 TCM。各 64 KiB 逐字等于生产 loader HEX，**2 PASS / 0 SKIP**；单比特故障被准确拒绝，另 **1 PASS**。ITCM SHA-256 `9080e499cbb9c3b8dbb213d32de91095442bfa0e857f082356855df44b2c5f7f`，DTCM `42bc3142a73c32571c2f418353ede2e5e30ffd1dde214019ef8e4400f09c3535`。两个 TCM 各 16 个 DRM36K、Cache 数据各 1 个，乘法器映射 4 个 APM。校验器严格拒绝其他映射，不支持 RV64；未冒充门级协议或 bitstream 验证。
- 新增 `docs/FPGA_RTTHREAD_COREMARK_PROGRESS.md` 解释完整成果、模型/实板边界、证据、缺口与顺序，README/Pango 文档同步。全套共享 RTL/ISA/裸机所要求目标已跑；本轮未额外重跑 Cache 专项、SoC ISA 或完整 UART 长下载。无 vendor 修改、main 修改、push、烧写、擦除或板级复位。

## 2026-10-13（Asia/Shanghai）— 原生 PDS SoC 暂存与 ADS 兼容诊断

- 新增 `scripts/pango/prepare_project.py`，将有序 SoC 源码与生成 DDR IP 综合源码（RV32 共 164 个 HDL 文件）、生产 loader 的 ELF/双 TCM 初值及文件哈希清单暂存到新的本地 Windows 空目录。显式 m0d1、PG2L200H/-6/FBB676、TCM 初值参数；先核对 DQ 32/32、HEX 深度/字宽和 ELF 位宽。生成离线 compile/synthesize Tcl，不修改仓库 RTL、不运行 JTAG/bitstream。
- RV32/RV64 候选暂存各 1 PASS，RV64 尚未运行整机 compile。本机 PDS 2025.2 build 211867 首次 RV32 整机 compile **失败**，339 行 `E:` 含大量连带错误，未运行 synthesize/P&R。最早解析失败为三个模块的 `parameter string`；跨包展开 `core_types_pkg` 的宽度 typedef 另报导入常量不在该包。只有后续取得成功日志和报告，才能声称综合或初始化通过；外层 PowerShell 命令退出不能代替流程结果。
- 隔离六项语言探针，**4 次 compile 成功、2 次预期失败，0 SKIP**：typed string 失败/untyped 同值参数成功；导入裸宽度的跨包 typedef 失败/定义包限定宽度成功；普通 enum 与显式 var enum 均成功。这支持先限于四文件做语法适配，不能证明整机其余错误都已解决。探针与原始日志在本地 `pds-probes/`、整机在 `pds-soc-rv32/`，均未加入源码发布。
- 候选 FDC 保留生成器的 PHY/时钟/IO，仅移除例程专属的两行 free_clk，层次保持不变，完整约束尚未验收。未修改已验收 RTL；拟适配 `tcm_controller.sv/soc_top.sv/pango_200hp_top.sv/core_types_pkg.sv` 的具体方案见 `docs/PANGO_200HP.md`，按根 AGENTS.md 等待批准后再修改并跑双位宽回归。没有烧写、复位、擦除、push 或 main 修改，尚无整机资源/时序/功耗报告。

## 2026-10-13（Asia/Shanghai）— 完整 UART 下载、RT-Thread 驻留重测与 DDR IP 候选

- 在 `codex/fpga-rtthread-coremark-ddr3` 增加独立 `RT_COREMARK_RESIDENT=1` 应用：成功后保持调度，UART0 收到 `r` 后重测。`coremark_app.c/coremark_port.c` 每轮清空 CRC/有效时长判定、匹配位置和迭代种子；输出模式、XLEN、实际 CLOCK_HZ、MDU 参数和完整 64 位 cycles，计时区间不含报告打印。默认单次入口保留。构建隔离 `-resident` 与非默认波特率目录，软件日志参数由传入的 MUL/DIV 配置产生。
- 新增 `scripts/loader/test_rt_thread.sh` 与 `make uart-rt-thread-test`。TB 只预装 loader 的 TCM 初值，不预装应用 DDR/TCM HEX；按 ELF HGB1 包经过真实 UART 数字引脚下载。先拒绝坏 header/停止位再重试，核对两轮 UART 解码 CRC PASS/READY、实际 DMA 源/目的/字节数、热区执行前 FENCE.I、DDR 取指及第二轮后持续热路径活动且未写成功退出。主机 `--runs N` 可按 READY 请求后续轮次，板级串口尚未实测。
- 完整下载 **4 个集成用例 PASS / 0 SKIP**，每例含两轮单迭代功能 CRC，共 8 次短时 CRC 观察；不是 8 个独立集成用例。均为 m0d1、50 MHz、500 kbaud 仿真，未得到有效时长成绩：

  | 配置 | wire bytes / 段数 | DMA bytes | DDR 指令请求 | 热区退休数（含驻留等待） |
  |---|---:|---:|---:|---:|
  | RV32 performance | 45,807 / 2 | 984 | 56,259 | 122,068 |
  | RV64 performance | 46,727 / 2 | 976 | 57,480 | 114,366 |
  | RV32 validation | 45,815 / 2 | 984 | 55,912 | 122,048 |
  | RV64 validation | 46,735 / 2 | 976 | 57,688 | 113,972 |

- 日志为 `logs/uart-rt-{performance,validation}-rv{32,64}.log`。前三组运行时被动 console 地址仍沿用了小程序地址，故原始文本未完整打印，但 TB 的实际 UART 解码断言通过；RV64 validation 按 ELF 正确 console 地址记录了两轮原始文本，cycles 为 `1,487,120 / 1,485,628`。脚本现从符号表取 `tohost/sim_console`，通过判定始终依赖 UART 解码和硬件观察，不依赖 console 文本。RV64 validation 用同一 TB/RTL 的独立 O2 宿主模型复用已构建镜像运行。
- 原单次 DDR 预装入口四组回归均各 **4 行运行 PASS + 3 行镜像 PASS / 0 SKIP**：RV32 performance ticks/SoC cycles `1,355,798/5,264,460`、validation `1,351,238/5,251,399`；RV64 performance `1,496,092/5,309,767`、validation `1,496,110/5,305,527`。仍不足 10 秒；原输出 `Errors detected` 来自短时长检查，功能判定只认三个分项 CRC，不将其包装成正式分数。
- 115200 baud、`ITERATIONS=0` 的四组驻留候选固件已构建并各通过 3 行镜像检查，未运行有效时长测试。text/data/bss（字节）：RV32 performance `37820/6616/14816`、validation `37820/6624/14800`；RV64 performance `38020/7304/16816`、validation `38020/7312/16800`。上游编译警告保留，不宣称零警告。
- 收尾复核：生产 C 接收器 19 项正常/故障/重试检查 + 上表四个实际包检查，**23 PASS / 0 SKIP**。通用 TB 的小程序双位宽复跑各 1 行构建 PASS、2 行运行 PASS / 0 SKIP，周期 RV32 `356,337`、RV64 `356,454`，与前阶段一致。长仿真采用 `--output-split-cfuncs 500` 和可覆盖宿主优化，集成脚本默认 O2；这些只改变 Verilator C++ 编译，不改变固件/RTL 周期契约。
- 新增 `scripts/pango/generate_ddr_ip.ps1/import_ddr_pins.tcl`，在本地 Windows ASCII 工作目录隔离安装 IP v1.10，复制参考 IDF 并调用厂商 FDC 导入/CA-DQ 自动配置过程，避免仅设路径而未更新管脚。PDS 2025.2 build 211867 独立重建 **0 errors / 0 warnings**，更新后 `PAD_DQ0..31` **32/32 match**；生成物不入 Git，不覆盖原参考工程或 PDS。WSL UNC 的实例锁及 RemoteSigned 问题通过本地副本解决，未更改系统执行策略。
- **更正前两条阶段记录的密度推断**：参考 `CUSTOMIZE_MEM=false` 时实际启用 `DDR3_DFT_MEM_PART=MT41K256M16XX`，`DDR_MEM_PART` 同为 256M×16，行/列/Bank=15/10/3、DQ=32。原先据未启用的 `DDR3_BASE_MEM_PART=MT41K128M16XX` 认为密度不匹配不成立。参考原 DQ 元数据 0/32 匹配的发现仍有效。XCCC 与 Micron 预设的电压/速率/时序等效性仍未验证；生成的 `pnr/ddr_test.fdc` 还需清理例程 `free_clk` 并核验当前层次的 PHY/PLL 约束。
- 同步 README、软件路线、RT-Thread/loader/Pango 文档。未改共享 Core/Cache/TCM/DMA RTL、CoreMark vendor 或上游依赖；完整共享 RTL/ISA/裸机 benchmark 回归本阶段未重跑，沿用 2026-10-12 m0d1 记录。没有烧写、复位、擦除、push 或 main 修改。尚缺可复现 PDS SoC 工程、BRAM 初始化/推断、综合/布局布线、板级 UART/DDR 校准与压力、复位后重下、正式长时成绩及有依据的资源/时序/功耗报告。

## 2026-10-13（Asia/Shanghai）— 常驻 TCM UART loader 与 HGB1 下载包

- 在 `codex/fpga-rtthread-coremark-ddr3` 新增 `software/loader/`，不替换模型 bootstrap 或已验收的 RT-Thread/Core/Cache/DMA 实现。loader 关闭中断、配置真实 UART0、先做 DDR scratch 写回/失效读回检查，再接收有版本/配置/入口/段描述的 HGB1 包。仅允许 DDR 普通镜像区与 D-TCM `.hot` 装载区，拒绝越界、回绕、重叠、非法入口、loader/栈覆盖。
- 生产 `protocol.c` 按 128 B 块 CRC 和 ACK 节流，另检查 header、表及整段 CRC；全局 D$ flush/invalidate 成功后逐段重新读回 CRC，才允许 GO、FENCE.I 和跳转。接收超时、UART framing/overrun、CRC/range 错误返回 NAK/错误码并留在 loader，静默清理后可重试。外存无响应仍需协调复位，软件 UART 超时不等于 DDR 事务超时。
- 新增 `scripts/loader/host.py`，按 ELF PT_LOAD 物理地址和文件长度生成下载包，排除模型引导/被动观察口、不传 BSS；输出段 CRC、包 CRC、ELF SHA-256 清单。可选 pyserial 负责 stop-and-wait 下载与日志显示。新增构建/测试脚本、`tb/loader/` 与 Makefile `loader/loader-host-test/loader-soc-test` 入口，匹配文档为 `docs/UART_LOADER.md`。
- 生产 115200 baud 固件双位宽构建各 1 PASS，GCC `-Wall -Wextra -Werror` 且无未定义符号：RV32 text/data `2056/90` B，RV64 `2112/94` B，BSS 均 0。正式初值在 `build/loader/rv*`；加速仿真的 500 kbaud/1 ms 静默镜像在独立 `sim-rv*`，避免误用于 PDS。
- 主机直接调用同一 C 接收器的 19 项正常/拒绝/故障/重试检查 PASS，加上实际 RV32/RV64 RT-Thread performance DDR ELF 包通过接收、缓存发布和下层内存读回，各 1 PASS，共 **21 PASS / 0 SKIP**。包分别为 44,631 / 45,655 wire bytes，各 2 个段。未将这些主机检查冒充 SoC 执行或实板下载。
- m0d1 双位宽 SoC UART RX/TX 数字仿真各 2 行运行 PASS / 0 SKIP：RV32 `356,337` 周期、RV64 `356,454` 周期；先拒绝坏 header 与坏停止位，再成功下载小型 DDR 程序及 D-TCM 数据。TB 检查 ACK/NAK/GO、FENCE.I 与 DDR 取指后程序完成，无 DDR 程序预装。UART RX 的真实计时超时/overrun 故障尚未做 SoC 注入；超时已通过 C backend 截断输入验证。
- 仅新增独立软件与 TB，没有修改共享 RTL、既有 C runtime、vendor 或上游依赖；本轮未重跑完整 Core/ISA/Cache/裸机 benchmark 回归，沿用先前记录。JTAG 已用本机 PDS 2025.2 build 211867 只读识别 PG2L200H / IDCODE `0x00603899` / DONE=0，但未连接确认板上 UART、未烧写。尚缺整份 RT-Thread/CoreMark 经 UART 的 SoC/实板链路、成功后驻留与重复测试、匹配板卡的 DDR IP 和 PDS BRAM 初始化/实现/资源时序功耗报告。

## 2026-10-13（Asia/Shanghai）— demo 契约与 DDR 主代码布局（开发分支）

- 用户指定新的 demo 指导已归档为 `docs/FPGA_RTTHREAD_COREMARK_DEMO.md`。RV32 为比赛首要验证配置，RV64 保留独立构建；继续使用 DSP/SRT m0d1，不改全仓默认 MDU 或已验收 RTL。
- `RT_COREMARK_LAYOUT=ddr` 使用独立 `link_coremark_ddr.ld`：应用 `_start`、RT-Thread 普通代码、CoreMark 主体、常量、数据/BSS、堆和线程栈位于 DDR `0x80000000–0x8001ffff`；工作集在 `0x80020000`，探测字在 `0x8003f000`。启动/IRQ 栈、仿真观察口仍在 D-TCM；热区 VMA/LMA、真实 DMA 与 FENCE.I 契约保留。TCM 的 `bootstrap_ddr.S` 仅为外存模型预装验证跳转，不是 UART loader。
- 构建分别输出 TCM 初值及 DDR HEX；镜像检查核对 DDR 入口、内核/CoreMark 函数、BSS/堆、工作集及 DMA 热区。新 TB 复用 256 KiB AXI RAM 模型，在 DDR 布局下额外要求真实 DDR 取指与 I$ 命中。运行日志按布局分开，避免覆盖 TCM 对照结果。
- DSP/SRT performance 短时仿真：RV32 `1,343,434` ticks、`4,617,397` SoC 周期，DDR 取指 `22,112`、I$ 命中 `1,323,196`、DMA 984 bytes、DDR R/W `30,456/7,016`；RV64 `1,486,013` ticks、`4,755,855` 周期，DDR 取指 `32,536`、I$ 命中 `1,360,998`、DMA 976 bytes、DDR R/W `37,572/4,168`。
- validation 短时仿真：RV32 `1,344,338` ticks、`4,612,225` 周期、DDR 取指 `22,328`、DDR R/W `30,648/6,968`；RV64 `1,485,848` ticks、`4,751,519` 周期、DDR 取指 `32,568`、DDR R/W `37,648/4,176`。四次仿真各 4 行运行 PASS（functional CRC、SoC 完成、DDR 指令路径、DMA/DDR/UART 集成），各 3 行镜像 PASS，0 SKIP；每次 1 迭代，不足 10 秒，不能报告正式分数。首次未留完整日志的运行不计入验收，最终固定脚本四次复跑日志为准。
- 未修改共享 Core/Cache/DMA RTL、vendor 或上游依赖；完整共享 RTL/ISA/裸机回归沿用 2026-10-12 m0d1 记录。本轮仅验证新布局，不宣称重跑上述全部目标。
- 参考 IP `.idf` 的 32 个 `PAD_DQ` 均与 200HP 管脚表/FDC 不同，Memory Part 也不匹配；新增 `scripts/pango/check_ip_dq.py` 对该参考配置按预期拒绝（0/32 匹配），用于重新生成后的 DQ 元数据复核。PDS 生成前须同时重设颗粒、管脚、PHY 约束。IP v1.10 包仅在忽略的 `build/pango/` 隔离展开。板卡尚未连接；UART loader、运行后驻留/重复测试、长时运行、真实 DDR/PDS 实现及功耗仍未完成。

## 2026-10-12（Asia/Shanghai）— RT-Thread DDR CoreMark 功能仿真（开发分支）

- 在 `codex/fpga-rtthread-coremark-ddr3` 增加独立 `rt-thread-coremark` 构建/测试入口，不改原 BSP 自检、CoreMark vendor 源码、Core/Cache/TCM/DMA RTL。`MUL_IMPL=0`、`DIV_IMPL=1` 分别选 DSP 推断乘法和 SRT 除法；厂商算术 IP 尚未评估。
- `software/rt-thread/link_coremark.ld` 将 CoreMark 2 KiB 静态工作集放在 `0x80000000` DDR 逻辑窗口；普通代码/数据与栈在 TCM，`.hot` 仍从 D-TCM 经真实硬件 DMA 搬到 I-TCM，检查完成后执行 `FENCE.I`。`check_image.py` 核对实际 ELF 地址和 I-TCM 热区初始全零。应用通过 D$ flush/invalidate 的探测字及整个工作集哈希读回，防止仅凭缓存命中宣称外存读写成功。
- `coremark_port.c` 用 `mcycle` 与 SoC `CLOCK_HZ` 计时，vendor 文本同时发往仿真 console 与硬件 UART0；识别三个分项 CRC 和官方有效运行提示。新 SoC TB 被动检查 DDR AXI 读写、UART0 TX 活动、DMA 地址/字节顺序及热代码执行前的 `FENCE.I`。只有自动校准且运行满足 CoreMark 时长要求时才输出 valid-duration PASS；默认 1 次迭代仅输出 functional CRC PASS。
- DSP/SRT 双位宽 performance 与 validation 模式各通过 1 次短时仿真：RV32 performance `601203` ticks、`3,370,250` SoC 周期，validation `601324` ticks、`3,367,423` 周期；RV64 performance `633020` ticks、`3,406,612` 周期，validation `634550` ticks、`3,403,758` 周期。四次各有三个预期分项 CRC、DDR 工作集读写及 UART0 TX 活动；RV32 DMA 984 字节、DDR 读/写接受 1024/448，RV64 DMA 976 字节、DDR 读/写 512/256。CoreMark 原输出均提示不足 10 秒，故**没有有效 CoreMark/MHz 或 FPGA 成绩**。仿真外存是 AXI RAM 模型，不是板载 DDR3。
- 原有 `make rt-thread` 双位宽 DSP/SRT 复跑均 7 行 PASS、0 SKIP：RV32 `1,339,909` 周期、DMA 984 字节；RV64 `1,348,150` 周期、DMA 976 字节。新入口最终版的 performance/validation 双位宽各复跑通过，输出均明确标为 `SoC integration`。
- 后续 demo 契约要求 **CoreMark 主要代码与数据都在 DDR**，并有 UART 两阶段 loader；本阶段仅完成 DDR 数据工作集，因此仍是中间里程碑。尚缺与真实 XCCC256M16EP-EINAY 颗粒匹配的 PDS DDR3 IP、FPGA 工程/镜像、板级 UART 捕获、至少 10 秒的正式成绩，以及 P&R 资源/时序和有依据的功耗。见 [板级进度](FPGA_DEMO_REPORT.md)。

## 2026-10-12（Asia/Shanghai）— MES2L676-200HP 板级接入第一步（开发分支）

- 分支 `codex/fpga-rtthread-coremark-ddr3` 从当日更新的 `origin/main` `c2818ca` 创建；未修改、推送或合并 main。
- 新增 `vsrc/cpu/pango_ddr3_bridge.sv`：本地 XLEN 访存到参考 DDR3 IP 的 256-bit 用户接口，单笔在途，按 32-byte beat 转换地址/byte lane，处理 AW/AR 反压、写数据接受和无 RREADY 的读脉冲。IP 无逐笔 B 错误反馈，不能据此证明写入物理 DDR 已可靠完成。
- 新增 `vsrc/cpu/pango_200hp_top.sv`：参考差分时钟、DDR 校准后 SoC 复位、CP2102 UART0 和 512 MiB DDR 逻辑窗口；未修改现有 Core、Cache、TCM 或 DMA 行为。`scripts/pango/mes2l676_200hp.fdc` 从正确 200HP 参考工程的第二组 IO 表提取，77 个 LOC 唯一；避免复制原 FDC 中冲突的旧版 pin 行。
- `scripts/rt-thread/build_sim.sh` 现传递 `MUL_IMPL`/`DIV_IMPL`。板级目标为 DSP 乘法 `0`、SRT 除法 `1`；厂商乘除 IP 尚未评估，不替代当前可验证实现。新增双位宽 DDR 桥 TB 和测试入口；相关 README、硬件/仿真/外存文档同步。
- `bash scripts/pango/test_bridge.sh`：RV32、RV64 各 4 个定向检查 PASS；目标 MDU 的 `make rt-thread XLEN=32/64 MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu- OPT_FAST=-O0` 均 7 行 PASS，无 SKIP。RV32 `1,339,900` cycles、DMA 984 bytes；RV64 `1,348,188` cycles、DMA 976 bytes。顶层在 IP/差分输入黑盒下 Verilator RV64 DSP/SRT lint 通过，不等于厂商 IP lint/综合。
- DSP/SRT 双位宽回归：`make test` 每位宽 43 unit PASS、17 directed PASS、1 位宽 SKIP；`make riscv-tests` RV32 58/58 PASS、RV64 78/78 PASS，每位宽 2 策略 SKIP；`make benchmark-smoke` 两位宽各 1 PASS；`make coremark` 两位宽的 performance/validation CRC 各 2 PASS。RV32 仿真 29 次/11,080,543 计时周期、`2.617200 CoreMark/MHz`；RV64 26 次/11,051,172 周期、`2.352692 CoreMark/MHz`，均为裸机仿真而非 RT-Thread DDR 成绩。
- 本环境只有 `/usr/bin/riscv64-linux-gnu-*` 交叉工具；回归在忽略的 `build/toolchain/bin` 下创建工具名映射。ISA 镜像需禁止该工具链默认 PIC/GOT 和 build-id 才能从零地址裸机启动；相关本仓 runner 增加 `-fno-pie -fno-pic -Wl,--build-id=none`。SRT 配置下 Verilator 生成的 C++ 用 `-O0` 加速编译，仅改变宿主仿真程序优化，不改变 RTL。上游 `riscv-tests/` 未修改。
- 原参考 `.idf` 的颗粒型号 `MT41K128M16XX` 与板载 `XCCC256M16EP-EINAY` 不符；尚未用 PDS 2025.2 重新生成 IP、取得时序/资源/功耗报告，也未上板、烧写、运行 DDR RT-Thread CoreMark 或串口实测。不能把本轮接口 TB 与 TCM BSP 仿真写成 DDR3 或 FPGA 成绩。剩余步骤见 [Pango 板级进度](FPGA_DEMO_REPORT.md)。（此为当时判断；后来确认 `CUSTOMIZE_MEM=false` 使用 `MT41K256M16XX`，见新文档。）

## 2026-09-30（Asia/Shanghai）— RT-Thread 首版软件 BSP 与 DMA 热代码

- Ubuntu 仓库 `/home/yukino/projects/hgb-aisystem_riscv`，分支 `rt-thread-port`，
  基于 `9c7cbb4`；main 未修改。本次未提交、推送、开 PR 或合并。
- 新增 `software/rt-thread/`、`scripts/rt-thread/`、`tb/soc/tb_rt_thread.sv`；
  Makefile 增加 `rt-thread-fetch/rt-thread`，忽略规则放行 software，关联文档同步。
  未改 `vsrc/`、既有 testbench、benchmark、只读 RT-Thread 依赖。
- 官方依赖 v5.2.2：`ddf52e2cdd977f14fc04035c88672ac204aec713`。单核 M 模式
  Nano 无 libc 配置加 serial-v1/pin 设备框架；不启用 A/C/F、WFI、SMP、POSIX 或 FinSH。
- 使用硬件 DMA 将 D-TCM `0x0110c000` 的 `.hot` 装载到 I-TCM `0x0100e000`，
  包含 Direct trap、IRQ 分派、线程切换/关中断；检查完成和内容后 FENCE.I，再设 mtvec。
  两端 TCM 旁路 cache。保留原 ROM 跳转和预装冷代码约定，不冒充板级下载器。
- BSP 实现 MTIME tick、IRQ claim/complete、UART0/1 与三组 GPIO。serial-v1 的
  配置错误被上游忽略，故新增 BSP 入口预检；不改上游代码。无上下拉/电平 IRQ/UART DMA。
- 最终 `make rt-thread XLEN=32/64 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu- OPT_FAST=-O0`
  均通过：每种位宽 1 个镜像检查 PASS、5 组软件检查 PASS、1 个 SoC 完成 PASS、
  1 个被动硬件契约 PASS（8 条 PASS，无 SKIP；不是 8 个独立仿真）。
  RV32 1,339,863 周期、DMA 984 字节、热区退休 22,381 条、trap 39 次；
  RV64 1,348,230 周期、DMA 976 字节、热区退休 21,672 条、trap 39 次。
  覆盖线程寄存器/64 位高半部、时间片、timer/semaphore、双 UART 环回、三组 GPIO
  边沿/解绑；TB 检查热区初始零、DMA 字节/地址/成功响应、禁止 CPU 代拷、FENCE.I
  后执行、真实 trap 与 bank 接受请求后下一拍响应。
- 固件 text/data/bss：RV32 `32212/5531/13136` 字节；RV64 `32532/6083/15408` 字节。
  工具为 GCC 11.4、Verilator 5.052；上游少量 signedness warning 保留，不宣称零警告。
- 适配前基线已验证：每位宽 42 unit PASS、17 directed PASS/1 SKIP；每位宽
  soc-test 5 条 PASS，外设裸机各 1 PASS，DMA 软件各 2 PASS（无 DDR/64 KiB DDR）。
  本轮只新增独立 BSP，未修改共享 C runtime/ISA/CSR/RTL/内存时序或 benchmark 支持，
  未重跑完整基线、riscv-tests、CoreMark、Cache 专项。未做 DMA 故障注入、
  FPGA 综合/BRAM 推断/时序/上板；不能以此次仿真替代这些结果。
- 详细地址表、接口限制及复现命令见 [RT_THREAD_PORT.md](RT_THREAD_PORT.md)。

## 2026-09-29（Asia/Shanghai）— hgb SoC 开发分支收敛

- 将 `docs/soc-learning-map` 改名为 `SOC/all`。当前文件树沿用 S5，未改 `vsrc/`、`tb/`、`scripts/`、`benchmark/` 或 Makefile；旧 S2/S3/S4/S5 分支头与早期 MDU 分支头以仅记录历史的 merge 接入，合并前后文件树哈希相同。
- hgb 保留 `main` 和 `SOC/all`；阶段差异改用可达的提交定位。rhbyv 的学习分支不动。`docs/` 仍有 28 个文件，README、正式接口和 understand 导读已改用当前分支与历史提交；两仓的 S3 完整 DMA 硬件、测试、脚本和 benchmark 内容一致。
- `make test XLEN=32/64`：每种位宽 42 项单元 PASS、17 项整核定向 PASS、1 项不适用位宽 SKIP；`make cache-test XLEN=32/64`：各 18 PASS。Markdown 相对链接、文档文件数和旧分支提交可达性均检查通过。
- 本轮未修改 RTL，因此未重跑 riscv-tests、CoreMark、SoC 软件测试或 FPGA 流程；这些验证结论仍以先前 S5 记录为准。

## 2026-09-29（Asia/Shanghai）— S5 WB/WA Cache 升级

- 两仓从已保存的 S4 基线新建 `s5/cache-up`；S4 提交为 rhbyv `72a3235`、
  hgb `4f0ddcb`。不改 main/S2/S3，不删除分支。保留注释、功能分块和 S4 WT 回归参考。
- D$ 改为两路阻塞式 write-back/write-allocate；Store hit 合并字节并置脏，
  Store miss 先填行，脏 victim 全行写回成功后才替换。失败保留 valid/dirty/data。
- 新增 `cache_writeback`、`dcache_meta_array`、`cache_maintenance_controller`，
  `cache_pkg` 仅定义枚举；旧实现保留为 `dcache_wt`，SoC 不实例化旧策略。
  共用 `cache_port/cache_refill` 增加维护归属和分配失败回退控制，I$ 保留原失效/排空机制。
- `soc_info/soc_peripherals/soc_top` 接入异步 clean/flush/invalidate 命令、
  busy/error/fatal 与真实故障地址。原 0x20 写 1 的软件必须升级为检查完成状态。
  invalidate 拒绝脏行；不会替软件悄悄丢弃数据或覆盖 DMA 新结果。
- FENCE.I 退休立即阻止新取指，自动 clean D$ 成功后恢复；失败 fail-stop 到复位。
  普通逐出错误返回当前触发替换的访问错误，不宣称能追溯旧 Store 的精确异常。
  无新机器检查 Trap、超时恢复或硬件 DMA 一致性；普通 FENCE 不清缓存。
- 新增 WB 字节记分板 TB、维护控制器 TB 和 C 维护辅助头；更新 SoC MMIO TB、
  改码/数据交接程序及缓存 runner。覆盖每个写回 beat 错误与重试、脏失效拒绝、
  原 Store 回退、混合冲突、旧响应反压中的维护排队、FENCE.I 失败禁止年轻提交。
- 两仓 README 分别维护，正式接口/目录/路线/测试文档同步。
  学习文档新增 [S5 写回解读](understand/S5_CACHE_WRITEBACK.md)，S4 文档加历史版本说明。
  没有修改 Core、MDU、vendor、只读 riscv-tests checkout、软件路线或 LICENSE。
- 两仓均独立完成 RV32/RV64 完整回归，以下结果已逐项核对；中断的 hgb RV64 后半段已补跑通过。

| 每仓每位宽的测试分类 | RV32 | RV64 |
|---|---|---|
| Cache 专项 | 18 PASS / 0 SKIP | 18 PASS / 0 SKIP |
| Core 单元 | 42 PASS / 0 SKIP | 42 PASS / 0 SKIP |
| Core 定向 | 17 PASS / 1 位宽 SKIP | 17 PASS / 1 位宽 SKIP |
| Core-only riscv-tests | 58 PASS / 2 SKIP | 78 PASS / 2 SKIP |
| SoC riscv-tests | 59 PASS / 1 SKIP | 79 PASS / 1 SKIP |
| SoC 模块 / 外设 C / DMA C | 5 / 1 / 2 PASS | 5 / 1 / 2 PASS |
| Core-only 与 SoC C smoke | 各 1 PASS | 各 1 PASS |
| Core-only 与 SoC CoreMark | 各 performance/validation 2 PASS | 各 performance/validation 2 PASS |

ISA 跳过项仍为 Core-only 的 fence_i/ma_data，SoC 仅 ma_data；无新增跳过。
Core/SoC lint 通过，SoC 未报告 LATCH/UNOPTFLAT/MULTIDRIVEN。
默认 m0d0、固定 32/29 次迭代，Core-only/TCM SoC 的 CoreMark/MHz 仍为
`2.897145 / 2.579496`；这是基线保持，不是 WB DDR 性能结论。
日志在各仓忽略的 `logs/s5-*`；rhbyv Cache 聚合日志为 `s5-cache32/64.log`。

未运行：厂商综合/上板/DDR3 时序、DDR CoreMark、长时随机 I/D/DMA 压力、
全 MDU 后端矩阵（本轮 MDU 未改）、AXI burst/多核/MMU/CMO 验证。
远程 PR 尚未创建：环境无 gh 或可调用 GitHub PR 工具；不直接 push main、不自合并。

## 2026-09-29（Asia/Shanghai）— S4 验收基线

- 用户确认 S4 完成，保存已同步、已双位宽验证的 I$/WT-NWA D$ 基线，再分支到 s5/cache-up。
- 本次仅整理本地提交，不改 S4 行为；测试结果复用下方 D$ 交付记录与现有日志。
- main、S2、S3 不变；S5 的写回/写分配、DMA 与维护协议变更另行记录。

## 2026-09-29（Asia/Shanghai）— WT/NWA D$ 与显式 DMA 数据维护

- 在两仓当前 s4/cache 上继续实现，不动 main、S2、S3；保留上一轮 I$ 未提交成果、
  现有注释和功能分块。Core 流水、load-use、MDU、非对齐异常策略不变。
- 新增 vsrc/soc/cache/dcache.sv：两路阻塞式，默认 4 KiB/32 B 行。
  Load 分配填行；Store 全部等待真实下层响应，成功命中按 byte strobe 更新，
  错误命中失效，写缺失不分配。没有 dirty、Store buffer 或提前 ACK。
- cache_port 增加数据访问模式；cache_data_array 支持字宽/字节掩码；
  cache_refill 按 I$ 的 4 B 或 D$ 的 XLEN 填行，失败仍只回退一次原始请求。
  I$ 算法与 FENCE.I 语义不变。soc_top/soc_peripherals 连接 D$ 与维护信号。
- soc_info 在既有系统窗口新增 0x20 全失效、0x24 启用状态、0x28/2c 容量/行大小。
  绝对地址 0x10040020 写 1，读恒 0；命令寄存一拍，失效不晚于写响应消费，
  反压不重复副作用。DMA 等 DONE/ERROR 后失效再读数据，不限制 DMA 的合法地址，
  不使用固定 uncached pool。普通 FENCE/FENCE.I 不充当 D$ invalidate。
- 新增 tb/cache/tb_dcache.sv、dcache_smoke.c、run_dcache_software.sh。
  更新 Cache runner、benchmark 构建参数/独立目录、SoC harness 的故障注入与计数，
  外设 TB 验证新寄存器的掩码、非法写和响应反压。修正参数矩阵脚本后逐项核对实际配置。
- 两仓独立运行 RV32/RV64：Cache 各 11 PASS、0 SKIP（I$/D$ 各 4 配置 + 3 软件）；
  D$ 四配置检查数 RV32 为 111/111/13/13，RV64 为 112/112/14/14。
  覆盖原样 Store 载荷、所有宽度/lane、NWA、延迟/错误写、部分副作用、每个填行错误、
  扩宽失败窄读成功、在途/安装沿失效、旁路交接与协调复位。
- DDR 软件以 D$ 开/关分别验证 CPU→DMA WT 可见性、预热目的区更新、第二笔 AXI 写错
  后的部分完成与全失效，并访问独立 DDR 区域与 DMA 竞争；开启各观察 30 hit、2 次维护。
- 每仓每位宽完整回归：42 unit + 17 directed PASS、1 位宽 SKIP；
  Core-only ISA 58/58、78/78 PASS，各跳过 fence_i/ma_data；
  SoC ISA 59/59、79/79 PASS，各仅跳过 ma_data。
  SoC 模块各 5 PASS（外设 TB 91/93 次传输），外设 C 各 1 PASS，DMA DDR=0/65536 各 2 PASS；
  Core/SoC C smoke 与 CoreMark performance/validation 均 PASS。
- TCM/Core-only CoreMark 仍为 RV32 2.897145、RV64 2.579496 CoreMark/MHz，
  不作为 DDR Cache 性能结论。DDR CoreMark、三主持续压力、完整 mdu-backends 矩阵、
  BRAM/综合/FPGA 时序未运行；保留既有非致命 lint 告警。
- 两仓独立更新 README 和维护文档；hgb 新增 understand/DCACHE_IMPLEMENTATION.md，
  更新 I$ 解读、Cache 设计状态与索引。理解与历史记录不复制到 rhbyv。
  当前仍是工作区交接，没有 Git commit/push/PR。

## 2026-09-29（Asia/Shanghai）— 两路 I$ 首版与 DDR 改码验证

- 在两仓既有 `s4/cache` 分支实现 I$ 交付，不回改 S2/S3/main；六级流水、load-use、
  MDU 边界和非对齐异常策略不变。D$ 仍未实现，后续按 WT/NWA 与 DMA 契约推进。
- 新增 `vsrc/soc/cache/{cache_port,cache_data_array,cache_meta_array,cache_refill,icache}.sv`：
  默认 4 KiB、两路、32 B 行、同步数据 RAM、一位 LRU；只缓存合法且整行位于 DDR 的取指。
  RV32/RV64 均发 8 笔 4 B 填行请求，部分失败不安装，按原请求仅回退一次。
- Core 只导出 `fence_i_commit`；更新 wrappers/TB 接线，SoC 搬迁原 I 响应缓冲至
  cache_port，保留 TCM 旁路交接和断环。FENCE.I 清 valid，旧填行粘滞 discard 并排空，
  不复位状态机丢失旧响应；普通 FENCE/分支不失效 I$。保留原注释与功能分块。
- 新增 `tb/cache/tb_icache.sv`、`icache_smoke.c` 和两个 runner；更新 Makefile、
  soc_files、SoC harness 的缓冲检查与被动统计。每位宽 Cache 5 PASS、0 SKIP：
  四种配置单测 + AXI DDR 的分支循环、CPU/DMA 修改预热函数、FENCE.I 集成。
  单测检查数 RV32 为 59/59/10/10，RV64 为 60/60/11/11；
  软件每位宽观察 99 hit、40 笔 DDR 取指、4 次 FENCE.I。
- 两仓均独立执行 RV32/RV64 完整回归：各 42 unit + 17 directed PASS，1 位宽 SKIP；
  Core-only ISA 为 58/58、78/78 PASS，各 2 SKIP（fence_i、ma_data）；
  SoC ISA 为 59/59、79/79 PASS，各 1 SKIP（ma_data）。
  SoC 模块各 5 PASS，外设软件各 1 PASS，DMA 的 DDR=0/65536 各 2 PASS；
  Core/SoC C smoke、CoreMark performance/validation 均 PASS。
- 默认 m0d0 的 TCM/Core-only CoreMark 周期成绩未退化：RV32 2.897145、
  RV64 2.579496 CoreMark/MHz。它们不是 DDR Cache 跑分。
  未运行 DDR CoreMark、完整 mdu-backends 矩阵、厂商综合、BRAM 映射或上板；
  lint 存在既有非致命告警，不宣称零告警。
- 两仓 README 各自更新功能入口，维护硬件目录/契约/规划/工作流；
  仅 hgb 新增 `understand/ICACHE_IMPLEMENTATION.md` 并更新设计稿与索引。
  hgb 的 LICENSE、软件路线和两仓 AGENTS 保持不变。当前为工作区交接，
  尚未 Git commit、push 或创建 PR。

## 2026-09-29（Asia/Shanghai）— 同步修复 IRQ 撤销与 MINSTRET

- 按用户确认在两仓 TCM/MMIO、完整 AXI/DMA、Cache 三阶段同步同一 Core/TB 修复；
  hgb 完整 S3 对应 soc/s3-dma-validation；main 与较早的 S3 单拍桥分支不动。
- IRQ pending 仅停止新取指，保留已接受请求；真正 Trap 才清 IF，避免撤销/屏蔽后丢指令。
- EX 对合法 MINSTRET/H 等待较老 MEM/WB 退休；普通 CSR 前递不变。RV32 显式写任一半
  抑制整个 MINSTRET 的自身退休增量。非对齐访问仍精确触发异常，ma_data 继续 SKIP。
- 新增退休计数参考模型，扩充中断撤销/CSR 屏蔽及同拍半宽写测试；保留注释与功能分块。
- 每分支双位宽均 42 unit + 17 directed PASS、1 SKIP；Core-only ISA 58/78 PASS、
  各 2 SKIP；SoC ISA 59/79 PASS、各 1 SKIP。C smoke、Core/SoC CoreMark 两模式、
  外设软件均 PASS；S2 SoC TB 每位宽 3 PASS，S3/S4 为 5 PASS，DMA 两配置均 PASS。
- 说明与完整验证边界见 understand/CPU_IRQ_COUNTER_FIX.md；更新硬件规划、外设契约。
  本轮本地提交，不推送、不合并 main；没有实现 Cache 或改变 ISA 非对齐访问策略。

## 2026-09-28（Asia/Shanghai）— Astra CPU 整体审核与 Cache 设计

- 按用户要求由 Astra 只读审核 pre-SoC CPU 全路径，对照 rhbyv `3936a52`，
  测试当前 `b30d8bc`；不回退 S0/S2 的错误响应、排序与中断接口。
- 复现三项未修复问题：IRQ 撤销可能丢失指令、MINSTRET EX 读遗漏前序退休、
  RV32 MINSTRET 半宽显式写未抑制整条计数器自身增量。
- 两种 XLEN 的 `make test` 均 42 unit + 16 directed PASS、1 SKIP；
  Core-only ISA 分别 58/58、78/78 PASS，各跳过 fence_i/ma_data。
  Astra 额外 5 次临时诊断共 6 项失败检查；不将常规回归通过称为无缺陷。
- 新增 `understand/CORE_ASTRA_REVIEW.md` 和 `understand/S4_CACHE_DESIGN.md`，
  更新索引。建议先关闭 CPU 缺陷，再按 I$ → WT/NWA D$ 实施，各 4 KiB、
  两路、32 B 行作为初始配置；明确真实 DDR 测试、FENCE.I、DMA 与错误回退。
- 本轮仅文档修改，未修改 RTL/正式 TB/脚本、未实现 Cache、未提交或推送；
  SoC 全套、CoreMark、多后端完整 CPU 矩阵、综合与上板未重跑。


## 2026-09-28（Asia/Shanghai）— S3 DMA 与仿真外存闭环

- `soc_top` 加入 CPU I/D + DMA 三主端口互连；DMA 以独立主端搬运，寄存器仍为
  MMIO 从端。DMA 只访问 TCM/已启用外存，任意错位和尾数可逐字节复制；
  完成字节数仅在成功写响应后增加。无效范围/重叠启动前拒绝；读写错误不回滚。
- IRQ 控制器新增 DMA 源 ID 7，状态采用 W1C 电平中断。DDR 窗口默认关闭，
  启用容量时由可综合本地端口接外部；仿真 harness 接单拍 AXI 桥与反压/故障 RAM。
  没有实现 DDR3 控制器、PHY、Cache、FPGA 综合或上板。
- `tb_dma_fabric` 验证跨 TCM/外存搬运、持续 CPU D 竞争、IRQ claim/complete、
  故障、非法命令、协调复位及复位后恢复；两种 XLEN 均 PASS。
  `soc-dma-software` 在 RV32/RV64 的无外存与 64 KiB 外存两种配置均 PASS：
  TCM 搬运、双向外存搬运、ID 7 handler、配置错误和外存取指。
- 原有 `make soc-test soc-lint` 两种 XLEN 均 PASS；完整 `make test`、
  Core-only ISA `58/58` 与 `78/78`、SoC ISA `59/59` 与 `79/79`、C smoke、
  CoreMark performance/validation 均通过。Core-only 跳过 `fence_i/ma_data`，
  SoC 仅跳过 `ma_data`。S3 不把仿真 RAM 当作 DDR3 性能结果。
- 同步硬件文档并新增 `understand/` 三篇专题解读；下一步从 `s4/cache`
  独立分支研究两路组相联 Cache 与 DMA 一致性。板级 DDR3 验证后推。

## 2026-09-28（Asia/Shanghai）— S3 起步：独立 AXI4 单笔桥

- 两仓从各自 S2 提交（rhbyv 58358a1 / hgb de67bbb）新开 soc/s3-axi-dma；
  S2 与 S1 检查点均保留。S2 分支已推送，未自合并 main。
- 新增 local_to_axi：32 位物理地址、XLEN 数据、固定 ID=0、单笔在途/单 beat；
  本地接受后寄存，AW/W 独立握手，B/R 完成后保持本地响应。无新增 Core 时延，
  因为本轮尚未接到 SoC 顶层，也没有打开 DDR/DMA 地址窗口。
- 拒绝非法本地格式与高地址截断；窄访问不改 byte lane；传播 SLVERR/DECERR，
  不发独占，异常多 beat 读排空到 RLAST。复位要求与外部从端协调，不假装可取消已接受写入。
- 新增 tb_local_to_axi 并纳入 soc-test，覆盖 35/51 次完成、每位宽 4 种协调复位，
  AW/W 先后、最早/延迟响应、反压、所有对齐 lane、错误和非法请求无副作用。
- rhbyv 重新执行双位宽 test、riscv-tests 和 soc-test：
  各 42 unit PASS、16 directed PASS / 1 位宽 SKIP；
  ISA 58/78 PASS，各 2 SKIP（fence_i、ma_data），原 SoC 三流程与新增 AXI 流程均 PASS。
  hgb 同步后独立运行两位宽 soc-test，结果一致。
- 本轮未重复运行 CoreMark：新增桥未接入已测的 Core/SoC 执行路径；S2 的四组
  performance/validation 结果仍作为该未改路径的基线，而非外存性能。
  DMA、三主仲裁、DDR 顶层/模型、burst 和板级验证均未完成，见 SOC_EXTERNAL_MEMORY.md。
- README 各自同步入口；完整记录仅在 hgb。当前无 GitHub CLI/API 凭据，无法自动创建 PR；
  分支推送后由维护者通过比较入口创建/审阅，不把“已推送”说成“PR 已提交”。

## 2026-09-28（Asia/Shanghai）— S2 外设、中断与完整 SoC 验收

- 完成 S1 顶层集成：ROM 跳转、共享物理 I/D-TCM、专用链接布局、SoC ISA/C/CoreMark harness。
  同 bank 跨 owner 交接隔一拍，SoC D 优先及 I 响应旁路缓冲切断真实组合环；
  独立互连仍可选原有轮询模式，不改变 Core-only 的单周期存储路径。
- S2 新增 UART ×2、机器/通用 Timer 各一、GPIO ×3、SoC 信息寄存器和六源中断汇聚。
  MMIO 接受沿产生一次副作用，响应可反压；设备边界与只读/W1C 寄存器见 SOC_PERIPHERALS.md。
- Core 实现 mie/mip、机器软件/定时器/外部中断；停止新取指并排空已入流水的操作。
  新增 next_pc 与 interrupt_entry，保存已退休分支/JAL/JALR 的实际后继；不取消已接受访存。
  同步异常优先；MRET 恢复，mtvec 仅 Direct，中断不计入 MINSTRET。未声称完整 PLIC。
- 新增中断单元/七场景整核 TB、外设握手 TB 和真正运行 C handler 的软硬件闭环；
  旧 TB 适配 IRQ 输入，CSR 测试不再把已实现的 MIE 当作非法地址。
- rhbyv 双位宽完整回归：各 42 unit PASS、16 directed PASS / 1 位宽 SKIP；
  Core-only ISA 58/78 PASS、各 2 SKIP（fence_i、ma_data）；
  SoC ISA 59/79 PASS、各 1 SKIP（ma_data），FAIL 0。
- SoC 三项 TB 均 PASS：轮询和 CPU 仲裁各 46/55 checks，外设 82/84 transfers。
  C 外设中断测试 3625/4169 周期；Core-only C smoke 3317/358，SoC C smoke 3323/364。
  六 MDU 后端矩阵另跑 RV32 78 / RV64 108 checks PASS。
- Core-only 与 SoC 均独立运行 CoreMark performance/validation、CRC 均正确：
  默认 m0d0、BTB64，RV32 32 次 / 11045355 ticks / 2.897145 CoreMark/MHz，
  RV64 28 次 / 10854767 ticks / 2.579512 CoreMark/MHz。ROM 启动多 6 拍但不在计时区间。
- hgb 同步后源码/测试/脚本/benchmark 与 rhbyv 逐目录一致；独立复跑两位宽
  soc-test、soc-software、soc-riscv-tests，结果相同；未声称 hgb 重跑全部 CoreMark。
- 用户已明确允许 README 功能与入口更新：两仓各自维护，保留 hgb 许可证及软件规划；
  解读和历史记录仅写入 hgb。未运行厂商综合或上板；DMA/DDR/Cache 留待后续。
  S1 独立检查点继续保留，不自合并 main。

## 2026-09-27（Asia/Shanghai）— S1 基础设施检查点（尚未完成顶层集成）

- 新增双主端口互连、同步逐字节写 TCM、ROM 复位跳转模块；每主端口最多一笔在途，
  同 bank 轮询、不同 bank 并行；反压时保持响应和仲裁选择，允许 IF 撤回未接受请求。
- 修正 ROM RV32 子字读取与类型包导入；保留模块头、中文协议注释和功能分块。
- 新增 `tb_soc_fabric` 和 `make soc-test`，两仓分别验证 RV32 46 / RV64 55 项检查 PASS。
- rhbyv 原有回归：每种位宽 41 unit PASS、15 directed PASS / 1 位宽 SKIP；
  ISA RV32 58 PASS、RV64 78 PASS，各跳过 fence_i、ma_data，FAIL 0。
  同步后 vsrc、tb、scripts 逐目录一致；hgb 未独立重跑整套 Core 回归。
- 这是用户要求的可回退检查点，不宣称完整 S1：SoC 顶层、专用镜像、SoC CoreMark 尚未接入。
  本次未重新跑 CoreMark、厂商综合或 FPGA；README、许可证和软件路线图保持原样。
- 后续先补齐 SoC 集成，再继续 S2 外设及机器中断；不包含 DMA/DDR 实现。

## 2026-09-27（Asia/Shanghai）— S0 访存完成、访问错误与排序契约

- Core 新增访问大小和 I/D 响应错误；Store 与 Load 都在 WB 接收一次完成响应。
  WB 输出补充总线异常后的提交包，错误访问不写寄存器，年轻 MEM 不产生副作用。
- IF 携带取指错误及 PC；D1 优先保留访问错误。FENCE/FENCE.I 在 D1 序列化，
  排空旧访存后从 WB 顺序 PC 恢复；FENCE.I 清除旧 BTB/PHT 与待训练项。
- 新增三个 SoC package（无函数）、地址译码和错误从设备；DDR 默认为关闭。
  TCM、外设及中断尚未接入，不能把 S0 说成完整 SoC。
- 新增地址/错误握手单元与统一内存整核测试，覆盖延迟写响应、三类访问错误、
  阻止年轻 Store、自修改代码及已训练的旧 BTB；同步旧 TB 的新接口与 Store ack。
- rhbyv 最终 RTL 回归：双位宽各 41 unit PASS、15 directed PASS / 1 SKIP；
  ISA RV32 58 PASS、RV64 78 PASS，各 SKIP fence_i、ma_data，FAIL 0；
  六后端矩阵分别 78/108 PASS，C smoke 为 3317/358 周期。
- CoreMark m0d0、BTB64，固定 RV32 32 迭代、RV64 28 迭代：
  performance 分别 11045355/10854767 ticks，2.897145/2.579512 CoreMark/MHz；
  performance/validation CRC 均正确，与 S0 修改前的同参数基线完全一致。
- hgb 同步后的 vsrc、tb、scripts、benchmark 与已测 rhbyv 快照逐目录比较一致；
  本轮未重复声称在 hgb 独立执行完整回归。未执行 FPGA 综合、时序或上板。
- 同步接口规范、硬件路线、目录和握手说明；README 功能简介更新暂被自动审核阻止，
  已请求维护者明确确认，尚未修改 README。

## 2026-09-27（Asia/Shanghai）— MDU 跨级实例与 MEM 内部拼包

- 以维护者修改并验证的 rhbyv 工作区为硬件同步来源；不在 package 中定义函数。
- `muldiv_unit` 移至 `core` 独立实例；`ex_mdu` 留在 EX 管理请求与 `issued_q`，
  `mem_mdu` 内化于 `mem_stage` 接收结果、拼包与前递，不增加结果寄存拍。
- EX/MEM 分别根据自己的流水包判断 M 指令，不跨级复用实时 `selected`。
- 保留 `issued_q`：WB 反压期间已接收的请求无需重复发射，随后 EX 可推进元数据。
- 保留维护者移除 `busy` 的接口调整；同步 TB 层级路径和独立 MDU 实例。
  MEM 单元测试增加结果未到、反压前递、响应握手与无效/异常包检查。
- 同步硬件路线、目录说明；hgb README 独立更新，软件路线与许可证不变。
- 前轮同架构回归：RV32/RV64 各 40 unit PASS、14 directed PASS / 1 SKIP；
  ISA 分别 58/78 PASS，各 2 SKIP（`fence_i`、`ma_data`），FAIL 0。
  六后端整核矩阵分别 78/108 PASS；C 冒烟和 CoreMark performance/validation
  两位宽 CRC 均通过。本次两仓库最终版本独立复跑 test 与 ISA，结果均与上述一致。
- 不包含 hgb 工作区中与同步无关的 `wb_stage.sv` 注释改动；该改动原样保留。
- 未执行 FPGA 综合、时序分析或上板；PR 由维护者审阅，不自行合并 main。

## 2026-09-25（Asia/Shanghai）— README 规约与 Cache/TCM/DMA/总线预案

- 两仓 `README.md` 均可在专用分支维护：rhbyv 保持简洁，不容纳理解文档、
  提交记录或当前阶段流水账；hgb README 随硬件事实更新，完整记录保存在此目录。
- 先以盘古 676-200K Pro 为板级目标，Zynq-7020 后适配；保留既有 Vivado Tcl，
  不假定盘古 DDR IP 为 AXI，也不把 Zynq PS DDR 视作无需 PS 初始化的纯 PL 资源。
- [设计草案](understand/THINKING.md) 区分 CPU I/D 接口、TCM、Cache、DMA 主/从端、
  内部互连和外部 AXI4 桥；写响应、DMA/Cache 一致性与 FENCE.I 是明确待审门槛。
- 本次只修改文档和 rhbyv 的 `.gitignore` 白名单，没有改 RTL、TB 或构建脚本；
  因此没有重新声称本次执行了仿真或板级验证。

### 上一轮两次提交：逐文件目的

以下是已完成的大轮次，而非本次架构预案新增 RTL。rhbyv 的提交依次为
`98373fe`、`42f6ee9`；hgb 的对应提交为 `f60fa61`、`d31ebbe`。

`98373fe`：修复 WB 慢 Load 时 MEM 已就绪前递被错误关闭、MDU 抓取旧操作数的问题；
没有前移 load-use 或改变六级边界。

| 文件 | 修改目的 |
|---|---|
| `scripts/verilator/run_mdu_backends.sh` | 将新增 M 前递整核用例纳入六后端矩阵。 |
| `tb/core/tb_core_m_forward.sv` | 新增慢 Load、MEM/WB 同名写入与 M 操作数回归。 |
| `tb/unit/tb_mdu_issue_control.sv` | 覆盖 MEM 优先于 WB 和未就绪生产者的发射许可。 |
| `tb/unit/tb_mem_stage.sv` | 验证 WB 反压时 MEM 已算好结果仍可前递。 |
| `tb/unit/tb_wb_stage.sv` | 验证 Load 响应等待与正常/异常提交条件。 |
| `vsrc/core/control/hazard_unit.sv` | 删去 D1 已转成异常后的重复 illegal 门控。 |
| `vsrc/core/core.sv` | 接入 MEM 前递的 MDU 就绪判断，精简预测更新推进门控。 |
| `vsrc/core/csr/csr_access_check.sv` | 去除被地址位只读规则覆盖的冗余 CSR 比较。 |
| `vsrc/core/execute/M_extension/ex_mdu.sv` | 澄清仅在依赖的前递结果未就绪时阻止请求。 |
| `vsrc/core/execute/M_extension/mdu_issue_control.sv` | 按最近的 MEM→WB 生产者判断两个 M 源操作数。 |
| `vsrc/core/execute/ex_exception_check.sv` | 复用统一的 EX 控制流判定函数。 |
| `vsrc/core/execute/ex_stage.sv` | 统一分支分类和有效门控，简化预测更新/重定向判断。 |
| `vsrc/core/frontend/if_stage.sv` | 合并重定向/flush 取消条件及顺序 PC 计算。 |
| `vsrc/core/lsu/mem_stage.sv` | 分离“结果可前递”与“包可推进”，删冗余请求判定。 |
| `vsrc/core/writeback/trap_controller.sv` | 复用无异常 retire 条件确定 MRET。 |
| `vsrc/core/writeback/wb_stage.sv` | 合并 Load 等待、正常提交与异常提交条件。 |
| `vsrc/pkg/core_types_pkg.sv` | 增加 EX 控制流分类辅助函数。 |

`42f6ee9`：EX 接受 M 请求时先将元数据寄存至 EX/MEM，MEM 等结果后拼包；
WB 反压时结果仍由 MDU 保持，不添加额外结果寄存拍。

| 文件 | 修改目的 |
|---|---|
| `scripts/rtl_files.f` | 将新增 `mem_mdu` 纳入可综合源码清单。 |
| `scripts/verilator/run_mdu_backends.sh` | 把边界用例纳入六后端整机矩阵。 |
| `tb/core/tb_core_m_boundary.sv` | 新增 EX/MEM 拼包、反压、前递边界整核测试。 |
| `tb/core/tb_core_m_trap.sv` | 适配 M 请求与提交分离后的 Trap 时序检查。 |
| `tb/unit/tb_ex_stage.sv` | 检查 EX 请求接受、元数据推进及 M 结果输出。 |
| `tb/unit/tb_mem_mdu.sv` | 新增 MEM 拼包/等待/响应握手单元测试。 |
| `tb/unit/tb_pipeline_ctrl.sv` | 验证 MEM 结果等待对年轻 EX 控制事件的优先级。 |
| `vsrc/core/control/pipeline_ctrl.sv` | 将 MEM 请求等待与 M 结果等待统一按年龄仲裁。 |
| `vsrc/core/core.sv` | 接入 `mem_mdu`、MDU 结果通路和 `mem_result_stall`。 |
| `vsrc/core/execute/M_extension/ex_mdu.sv` | 用 `issued_q` 记录已接受但尚未离开 EX 的请求。 |
| `vsrc/core/execute/M_extension/mem_mdu.sv` | 新增 EX/MEM 元数据与寄存 M 结果的无额外拍拼包。 |
| `vsrc/core/execute/ex_stage.sv` | 只推进 M 元数据，结果改由 MEM 拼入。 |

hgb 在上述两次提交还各自更新了 `docs/COMMIT.md`、
`docs/HARDWARE_ROADMAP.md`、`docs/PROJECT_STRUCTURE.md` 和
`docs/understand/M_EXTENSION.md`：同步修改记录、当前硬件边界、文件职责与
M 扩展时序解读；这些发布文档不反向放进 rhbyv。

## 2026-09-25（Asia/Shanghai）— MDU 结果与 EX/MEM 元数据汇合基线

`ex_mdu` 在请求接收后允许元数据进入 EX/MEM，并用 `issued_q` 处理较老指令反压期间
已启动但尚未交付的请求。新增 `mem_mdu`，在 EX/MEM 寄存器输出侧拼接 MDU 寄存结果；
`pipeline_ctrl` 对未完成的 MEM 结果维持年龄优先。更新文件表、模块/整核 TB 和
六后端矩阵，保留同步异常、取消和 ready/valid 的既有提交顺序。

验证：两种 XLEN 各 40 unit PASS、14 directed PASS、1 非适用位宽 SKIP；
riscv-tests 为 RV32 58 PASS、RV64 78 PASS，各 2 SKIP（`fence_i`、`ma_data`）。
六种 MDU 后端矩阵为 RV32 78 PASS、RV64 108 PASS；EX 适配器在两种 XLEN 下各
6 种后端 PASS。C 冒烟、CoreMark 校准、performance、validation 均通过。
固定基线相同迭代数，默认 m0d0、BTB 64：RV32 32 次/11045355 ticks，
`2.897145 CoreMark/MHz`；RV64 28 次/10854767 ticks，
`2.579512 CoreMark/MHz`。未进行 FPGA 综合或板级验证。


## 2026-09-24（Asia/Shanghai）— fix_M 前递修复与组合条件精简

范围：第一阶段基线，保留六级流水与现有 EX 等待 MDU 的寄存边界；不前移 Load-use。

- 修复慢 Load 停在 WB 时，MEM 已完成结果因无法推进而被关闭前递，导致 EX MDU 锁存旧操作数的问题。
- MEM 的 GPR/CSR 前递有效性与向 WB 推进许可分离；MDU 操作数就绪遵循 MEM 优先于 WB，支持较新同名写入覆盖。
- D1 负责将非法指令转换为异常；清理后级重复 illegal 检查，合并 WB 完成条件、EX 分支分类、IF 当前路径取消条件及 CSR 冗余只读比较。
- 保留模块说明、中文功能块与协议注释；没有改变 Load-use 位置、乘除法算法或请求/响应状态机。
- 新增 `tb_core_m_forward` 七场景；扩展 MEM、MDU 发射和 WB 真值测试，后端矩阵纳入新定向测试。
- 涉及 `vsrc/core/{control,execute,frontend,lsu,writeback,csr}`、`core.sv`、类型包、上述 TB 与后端矩阵脚本。

验证：两种 XLEN 各 39 项 unit PASS，14 项 directed 中 13 PASS、1 非适用位宽 SKIP；
三种 top 的 lint 均通过。riscv-tests 为 RV32 58 PASS、RV64 78 PASS，各 2 SKIP
（`fence_i`、`ma_data`）。C 冒烟各 1 PASS，CoreMark 校准、performance、validation 均通过。
默认 `MUL_IMPL=0 DIV_IMPL=0 BTB_ENTRIES=64`：RV32 32 次迭代/11346027 ticks，
`2.820371 CoreMark/MHz`；RV64 28 次迭代/11117855 ticks，`2.518471 CoreMark/MHz`。
六种 MDU 后端矩阵为 RV32 72 PASS、RV64 102 PASS，均无 FAIL/SKIP。
未运行 FPGA 综合或上板。


## 2026-09-02（Asia/Shanghai）— SYSTEM uOp 分类

状态：A0 学习分支上的适应性设计调整，尚未替代后续阶段实现。

### 评估结论

`ECALL`、`EBREAK` 和 `MRET` 使用相同的 `SYSTEM` major opcode，但不是普通
Zicsr read-modify-write 指令。三个 `is_*` 控制位允许无效组合，改用互斥的
`sys_op_e` 更适合作为译码结果：

```systemverilog
typedef enum logic [1:0] {
    SYS_NONE, SYS_ECALL, SYS_EBREAK, SYS_MRET
} sys_op_e;
```

`ECALL/EBREAK` 产生同步异常，trap commit 才更新 `mepc/mcause/mtval/mstatus`；
`MRET` 是特权返回指令，在 commit 恢复 `mstatus` 并重定向到 `mepc`。它们均不
应设置 `csr_valid/csr_write`，也不使用 `csr_cmd_e`。

### 本次调整

- 将 `uop_t.is_ecall/is_ebreak/is_mret` 合并为 `uop_t.sys_op`。
- 增加 ECALL、EBREAK、MRET 的完整 32-bit 编码。
- 增加 `tb_core_types`，检查零值 uOp、SYSTEM 分类互斥性和指令编码。

### 后续适配

A1 及以后阶段的 decoder、异常检测和串行化条件需要分别改为比较
`SYS_ECALL`、`SYS_EBREAK`、`SYS_MRET`。未来实现 S-mode/WFI 时再扩宽枚举并
增加 `SYS_SRET`、`SYS_WFI`，不提前把未实现指令声明为可执行功能。

## 2026-09-03（Asia/Shanghai）— 特权架构定义分层

状态：A0 审核后的适应性设计调整，于 2026-09-04 纳入本地提交。

### 评估结论

- `uop_t` 保存译码后的静态执行意图；`exception_t` 是各流水级可更新的动态状态，两者继续分离。
- `FU_LSU` 表示 Load/Store Unit，与 U-type 指令无关；LUI/AUIPC 复用 ALU。
- 指令编码与特权架构定义分层，避免 `pipeline_pkg` 持有 RISC-V 原因编号。

### 本次调整

- 将 `riscv_isa_pkg` 拆分为非特权的 `riscv_unpriv_pkg` 和特权架构的 `riscv_priv_pkg`。
- `ECALL/EBREAK` 归入非特权指令编码，`MRET`、机器级 CSR 与 trap cause 归入特权架构定义。
- 新增 `riscv_priv_pkg`，收纳特权指令、CSR 地址、trap cause 及机器中断字段。
- 增加 `mie/mip`、`MIE/MPIE`、`MSIE/MTIE/MEIE` 和对应 pending bit 的架构常量。
- Core 参数 assertion 在综合时通过 `` `SYNTHESIS `` 关闭，在 Verilator 仿真/lint 时保留。
- 新增 `tb_riscv_unpriv` 和 `tb_riscv_priv`，对 RV32/RV64 下的非特权/特权编码常量做模块级检查。

### 范围边界

本次只建立架构常量，不表示 A0 已实现异步中断。`mtime/mtimecmp`
属于平台级内存映射设备，后续由 interrupt/trap arbitration 消费 `MTIP`。

## 2026-09-04（Asia/Shanghai）— A0 审核完成

- RV32/RV64 的 core、simulation top 与 synthesizable top 均通过 Verilator lint。
- RV32/RV64 的 `tb_core_config`、`tb_core_types`、`tb_riscv_unpriv`、`tb_riscv_priv` 均通过。
- 本提交作为 A0 已审核基线，后续合并到 `stage/a1-rv32i-six-stage`。

## 2026-09-04（Asia/Shanghai）— A0 合并到 A1

### 合并处理

- 保留 A1 的 IF–D1–D2–EX–MEM–WB 数据通路，不回退为 A0 空框架。
- 同步 A0 审核后的 `sys_op_e`、特权/非特权 package 分层和异常类型归属。
- Decoder 与立即数生成器改为导入 `riscv_unpriv_pkg`。
- 保留已审核的中文学习注释，并保留 A1 的参数断言综合保护。

### 验证

- `make lint XLEN=32` 和 `make lint XLEN=64` 通过。
- `make unit XLEN=32` 和 `make unit XLEN=64` 的全部模块测试通过。
- `make directed XLEN=32` 通过，`tb_core_rv32i` 用 33 个周期完成。
- A1 的 directed test 明确限定 `XLEN=32`；RV64 整核指令行为由 A2 验收。

## 2026-09-10（Asia/Shanghai）— A1 审核改革固化

### 关键修改

- 将流水级控制统一为 `pipeline_actions_t`，按级表达推进、保持和清空，消除旧的分散 `hold/flush/bubble` 组合。
- 重构 IF 请求、响应与单项缓冲；重定向可以杀死在途错误路径响应，并保留后压下的有效指令。
- 将 load 请求发射与返回解耦：MEM 只负责请求，WB 等待响应并在返回后提交，流水线仅在真实内存等待时停顿。
- 按功能拆分核心模块中的组合逻辑和时序逻辑，保留并补充关键中文注释。
- 统一测试时序、具名指令编码和 PASS 判定，新增 IF、MEM、WB、流水线控制、存储握手、cache wait 与 load 流水验证。
- 新增仓库内 `AGENTS.md` 和 `MEMORY_HANDSHAKE.md`，固化代码分块、注释保护和回归规则。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 17 项全部通过。
- `make directed XLEN=32` 通过：cache wait 11 周期、load pipeline 18 周期、RV32I 32 周期。
- A1 仍是 RV32I 阶段，RV64 整核测试在 A2 功能合入后执行。

## 2026-09-10（Asia/Shanghai）— A1/A2 合入 A3

### 合并原则

- 以已审核 A1 的注释、功能分块、IF/MEM ready-valid 握手和 `pipeline_actions_t` 为基线，人工移植 A2/A3 功能。
- 保留 `riscv_unpriv_pkg` 与 `riscv_priv_pkg` 分层，不恢复旧 `riscv_isa_pkg`。
- A3 已包含 A2 历史，因此只将 A1 固化提交合入 A3，避免重复合并 A2。

### 关键修改

- 加入 RV64I 的 LD、SD、LWU、XLEN 位移和 W 类算术/移位，W 类结果统一符号扩展。
- 为 RV64 编码补充带上下文的 funct3/funct6 常量及 `enc_ld`、`enc_addiw`、`enc_addw` 等具名测试编码。
- 接入直接映射 BTB、非推测 GShare 和预测更新仲裁；只有流水级真正推进时才训练预测器。
- JAL/JALR 只更新 BTB，不进入 GHR；条件分支使用取指时保存的 PHT 索引训练。
- BTB miss 输出确定的空目标/类型，避免无效表项数据传播；同索引不同标签按直接映射规则替换。
- 预测器 RTL 按查表、训练计算和时序写入分块，并保留、补充必要中文注释。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 21 项全部通过。
- 两种位宽的 cache wait 均为 11 周期，load pipeline 均为 18 周期。
- 两种位宽的预测整核测试均执行 21 次分支、产生 7 次重定向。
- RV32I 整核测试 32 周期通过；RV64I 整核测试 28 周期通过，非适用位宽均明确报告 SKIP。

## 2026-09-12（Asia/Shanghai）— A3 审核版本检查点

### 固化范围

- 以用户审核和调整后的 A3 工作区为后续 A4 合并基线，不回退模块顺序、功能分块或中文注释。
- 保留 Core、Decoder、ALU、BTB、GShare、IF、Predictor、预测更新仲裁、Store 及 package 中的审核修改。
- 仅清理 6 处行尾空格，不改变 RTL 行为；未跟踪的 `README.md` 与 `riscv-tests/` 不纳入提交。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 21 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 全部通过；cache wait、load pipeline、预测器和两种位宽整核行为均保持原结果。

## 2026-09-12（Asia/Shanghai）— A3 基线合入 A4 验证分支

### 合并原则

- 以用户审核后的 A3 检查点 `11078d5` 为数据通路和注释基线，人工适配正确 A4 的 Zicsr、同步异常和 riscv-tests 功能。
- 保留 A3 的 IF request/response/buffer/kill、MEM 发请求/WB 收 Load 响应以及 `pipeline_actions_t`，没有回退到旧 A4 的 MEM 等响应设计。
- 冲突模块继续按照功能拆分组合与时序块，并保留、迁移或适应性修正已有中文注释。

### 关键修改

- 完成六种 Zicsr 指令、CSR 寄存器/立即数操作、相邻 CSR 旁路和 WARL 合法化；合法值同时用于 EX 旁路与 WB 提交。
- 实现 ECALL、EBREAK、MRET、非法指令、指令/Load/Store 地址未对齐的精确同步异常，以及 `mstatus/mtvec/mscratch/mepc/mcause/mtval/mcycle/minstret`。
- Trap、CSR 写入和退休计数统一由 WB 的真实 `commit_valid` 门控，Load 等待响应时不会提前或重复产生架构副作用。
- 将 D1/EX 序列化纳入 `PIPE_ADVANCE/HOLD/CLEAR`；IF flush 可以杀死在途年轻响应但不提前修改 PC，最终由 WB Trap/MRET 重定向。
- 预测更新仲裁在清除错误路径 pending 的同时保留引发 EX 重定向的老分支训练，A3 预测测试继续保持 21 次分支、7 次重定向。
- 不恢复旧 `riscv_isa_pkg`；非特权编码继续放在 `riscv_unpriv_pkg`，机器 CSR、MRET 和异常原因放在 `riscv_priv_pkg`。
- 测试编码增加 `enc_csrrw/enc_csrrs/enc_csrrc` 及立即数、ECALL、EBREAK、MRET 具名函数；所有 A4 TB 声明时间精度并使用确定性时钟沿采样。
- 新增 `tb_core_trap_wait`，验证延迟 Load 响应、单次请求、年轻 ECALL 顺序、错误路径清除和 handler 的 MCAUSE。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过，覆盖 core、sim_cpu_top 和 cpu_top。
- `make unit XLEN=32`、`make unit XLEN=64` 各 26 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项通过（另一位宽整核 ISA 用例明确 SKIP）。
- `make riscv-tests XLEN=32` 通过 `10/10`；`make riscv-tests XLEN=64` 通过 `13/13`。

## 2026-09-13（Asia/Shanghai）— A4 控制与异常路径模块化

### 关键修改

- 新增 `d1_exception_check` 与 `ex_exception_check`，分别承接译码后已知异常，以及前级异常继承、CSR 非法访问、访存地址和实际控制流目标检查。
- 新增 `csr_bypass`，独立处理 `EX/MEM > MEM/WB > csr_file` 的 CSR RAW 旁路优先级；CSR 提交许可仍由 WB 完整性控制。
- 新增 `serialize_controller`，保存异常/MRET 从发现到 WB 重定向期间的 pending 状态，并控制前端清空和取指请求许可。
- `pipeline_ctrl` 只在序列化事件赢得最老事件仲裁后输出 `serialize_start`，避免被更老重定向杀死的年轻请求错误锁住前端。
- 新增 `gpr_forward_t` 与 `csr_forward_t`，统一表达前递来源的有效位、地址和值；GPR/CSR 旁路均收进 EX 阶段。
- 两类前递结构归入 `pipeline_pkg`，并将仅处理 GPR 的 `operand_bypass` 更名为与 `csr_bypass` 对称的 `gpr_bypass`。
- CSR 的 WARL 合法化只在 EX 执行一次；WB 输出已完成指令的 CSR 提交通道，`csr_file` 只保存合法提交值和处理 Trap/MRET 状态变换。
- `fetch_ready` 与 `mem_issue_enable` 统一由 `pipeline_ctrl` 输出；MEM 许可只依赖更老的 WB 状态，避免经 MEM 前递、EX 重定向形成组合环。
- `trap_controller` 移入 `writeback/`，体现其根据 WB 提交包产生 Trap/MRET 架构副作用和重定向的职责。
- `fetch_enable` 改为语义明确的 `fetch_request_enable`；功能块注释保留说明并移除数字编号。
- 新增五个模块 TB，并扩充 MEM、WB、CSR file 与 `pipeline_ctrl` 对结构体通道、提交条件和控制许可的检查。

### 验证

- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 31 项全部通过。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项全部通过。
- `make riscv-tests XLEN=32` 通过 `10/10`；`make riscv-tests XLEN=64` 通过 `13/13`。

## 2026-09-13（Asia/Shanghai）— 项目文档与目录规则整理

### 关键修改

- 将阶段修改记录和存储器握手说明移动到 `docs/`，根目录只保留项目入口文件。
- 重写根 `README.md`，删除旧五级、Nexys A7 和 Cocotb 工作流描述。
- 新增项目目录、硬件路线、软件目标占位及仿真/上板说明。
- 审核嵌套 `riscv-tests` 的实际 dirty 状态，记录适配层边界；该目录不转换、不暂存，并在最终规则中作为只读 clone 忽略。
- `.gitignore` 改为根目录白名单，默认排除 build、logs、Vivado workspace 等生成物。
- 扩充根 `AGENTS.md`，固化注释、审阅、测试、文档同步、分支和 PR 规则。

### 验证

- 本次只修改文档和版本库组织，不改变 RTL 行为。
- `.gitignore` 白名单检查通过，新增 Markdown 没有行尾空白。
- 当前 RTL 最近回归保持：RV32/RV64 lint 通过，各 31 项 unit 通过，directed 通过，riscv-tests 为 RV32 `10/10`、RV64 `13/13`。

### 范围边界

A4 只实现机器模式同步异常。`mie/mip` 及软件、定时器、外部中断的编码已保留在
`riscv_priv_pkg`，但寄存器状态和中断仲裁留待后续阶段，不在本次为通过测试而伪实现。

## 2026-09-13（Asia/Shanghai）— 固定 riscv-tests 并接入 ECALL/tohost

### 关键修改

- 保留并适配用户新增的软件栈目标，当前 FPGA 上板目标继续使用 Vivado 与 Zynq-7020 PL。
- 新增 `docs/understand/SOFTWARE_TEST_STACK_GUIDE.md`，串联上游汇编、环境宏、链接、镜像、Verilator、存储器、流水线、Trap 与 `tohost` 判定。
- 将根目录 `riscv-tests/` 定位为父仓库忽略的只读样本；父仓库不修改或依赖该 clone。
- 将正式回归所需的 MI/UI `.S`、测试宏、`encoding.h` 和许可证固定到 `tb/riscv_tests/vendor/`，记录上游 riscv-tests `933a897` 与 env `6de71ed`。
- 本地环境补充 UI 测试族入口宏；runner 默认使用 vendor 快照，并分别维护 MI/UI 清单。
- PASS/FAIL 改为 `a7=93 + ECALL`，由 M-mode Trap handler 将 `TESTNUM` 写入 ELF 的 `tohost` 符号；普通被测 ECALL 仍交给测试自己的 handler。
- 删除会接管 DMem 地址的 `sim_test_device`；`sim_cpu_top` 只被动导出已握手 Store，TB 的 `store_result_monitor` 负责解释结果。
- directed TB 使用同一被动监视器但不依赖退出 ECALL，保持基础数据通路与 A4 Trap 故障可分离诊断。
- 新建 `docs/understand/` 存放协议和实现链路解读，并将存储器握手说明一并纳入。
- 更新 README、目录说明、仿真说明与 Agent 规则，统一上述边界。

### 验证结果

- `bash -n` 检查三个 Verilator runner 通过。
- `make lint XLEN=32`、`make lint XLEN=64` 通过。
- `make unit XLEN=32`、`make unit XLEN=64` 各 31 项通过，其中包含新的被动 Store monitor 测试。
- `make directed XLEN=32`、`make directed XLEN=64` 各 8 项通过。
- `make riscv-tests XLEN=32` 正式通过 `50/50`（MI 10 + UI 40）。
- `make riscv-tests XLEN=64` 正式通过 `65/65`（MI 13 + UI 52）。
- 两种位宽均显式跳过 `fence_i` 和 `ma_data`：前者需要 Zifencei 与可写指令存储一致性，后者要求未对齐访存直接完成。
- 本次没有修改可综合 Core，也没有修改根目录上游样本 clone。

## 2026-09-13（Asia/Shanghai）— A5 CoreMark 与周期性能闭环

### 关键修改

- 固定官方 EEMBC CoreMark `v1.01`（报告版本 1.0）源码和许可证，记录 commit
  `cfa9ab377835911f23d9b0831c7be302ed1f58de`；被测 `core_*.c` 与 `coremark.h`
  保持上游原样，平台适配独立放在 `benchmark/coremark/port/`。
- 新增裸机 BSP：`crt0.S` 设置 `gp/sp/mtvec`、清零 `.bss` 并经 ECALL/`tohost`
  退出；链接脚本、字符 Store、`memcpy/memset` 和软件乘除共同支持无 M 扩展的 C 程序。
- `mcycle/minstret` 改为固定 64 位状态；RV32 新增 `mcycleh/minstreth` CSR 与原子高低高
  读取，RV64 仍从低地址访问完整计数器。CSR 访问检查和两种位宽单元测试同步更新。
- 新增 C 冒烟，覆盖 `.data/.bss`、栈、函数调用、32/64 位软件乘除、Store 与计数器；
  新增通用 benchmark TB，并仅为长程序把仿真 IMem/DMem 参数化扩至 128 KiB。
- 新增镜像构建、仿真构建和 CoreMark runner。runner 先校准迭代周期，再以 performance
  与 validation seeds 各运行不少于 10 个归一化秒，并检查官方 CRC 成功文本。
- CoreMark 长程序发现一处控制缺陷：较老 JALR 重定向清除了错误路径异常，却未清除
  已登记的序列化 pending，导致永久停取指。`serialize_controller` 现由最终选中的任意
  较老重定向完成或取消 pending；新增短叶子返回后紧跟非法填充的定向回归。
- 新增 `docs/understand/COREMARK_AND_PERFORMANCE.md`，区分 CoreMark/MHz、实际
  CoreMark/s、Fmax 和 CoreMark/LUT，并同步 README、目录、软硬件路线和仿真说明。

### 验证结果

- RV32/RV64 的 core、`sim_cpu_top`、`cpu_top` lint 均通过；新增计数器逻辑无宽度警告。
- `make unit XLEN=32/64` 各 31 项全部通过。
- `make directed XLEN=32/64` 各执行 9 项：8 项 PASS，另一位宽 ISA 用例明确 SKIP；
  新的 JALR/序列化取消用例两种位宽均为 18 周期。
- `make riscv-tests XLEN=32` 通过 `50/50`（MI 10 + UI 40）；RV64 通过 `65/65`
  （MI 13 + UI 52）。两种位宽仍只跳过 `fence_i` 与 `ma_data`。
- C smoke 通过：RV32 3945 周期，RV64 2494 周期。
- CoreMark performance/validation 均报告 `Correct operation validated`。RV32 performance
  为 11 次迭代、11,148,066 ticks、`0.986718 CoreMark/MHz`；RV64 为 10 次迭代、
  12,004,387 ticks、`0.833029 CoreMark/MHz`。
- vendor 文件逐字节匹配上游 `v1.01`，四个新增 runner 通过 `bash -n`，`git diff --check`
  通过。Vivado、真实 Fmax、utilization 与上板 CoreMark 未执行，留待 A6。

## 2026-09-13（Asia/Shanghai）— 拆分序列化完成与取消通道

### 关键修改

- 将 `serialize_controller.serialize_complete` 恢复为单一含义：只表示 WB Trap/MRET
  完成自身序列化；新增 `serialize_cancel`，明确表示 D1/EX 较老控制流重定向杀死了
  错误路径上的年轻序列化事件。
- Core 分别连接 `wb_redirect.valid` 与“最终选中且非 WB”的重定向，不再用一个名为
  complete 的端口混合两种原因；控制器内部仍让释放事件优先于同拍开始事件。
- 扩充控制器单元测试，分别验证正常完成、错误路径取消和同时开始/取消的优先级。
- 新增 Taken Branch 后紧跟非法顺序路径的整核测试，与既有 JALR 用例共同覆盖两类
  EX 重定向取消场景。

### 验证结果

- `make unit XLEN=32/64` 各 31 项全部通过。
- `make directed XLEN=32/64` 各执行 10 项：9 项 PASS，另一位宽 ISA 用例明确 SKIP；
  Branch 取消用例两种位宽均为 12 周期，JALR 取消用例仍为 18 周期。
- RV32/RV64 的 core、`sim_cpu_top`、`cpu_top` lint 均通过。
- `make riscv-tests XLEN=32` 保持 `50/50`，RV64 保持 `65/65`；既定的 `fence_i` 与
  `ma_data` 仍明确 SKIP。
- C smoke 保持 RV32 3945 周期、RV64 2494 周期。
- CoreMark performance/validation CRC 均通过，周期和成绩不变：RV32
  `0.986718 CoreMark/MHz`，RV64 `0.833029 CoreMark/MHz`。

## 2026-09-16（Asia/Shanghai）— 阶段 B 启动与设计评估

- 按用户要求暂缓 A6，从 A5 `main` 创建并切换到 `stage/b-rv32-rv64-m`。
- 同步当前开发目标；用户已确认 B 保留六级主流水，先完成 RV32M/RV64M 与
  CoreMark，再恢复 A6 上板，之后依据实测时序考虑加深流水。
- 补充 MDU 请求/响应、操作数锁存、结果反压和按指令年龄取消的设计边界；
  仿真与综合共享可综合 RTL，算法和具体延迟仍待评审，尚未实现硬件 M。
- 补充未来机器模式中断、访存错误和 MMIO 不可重复副作用的目标，不扩展本次 RTL 范围。
- 本次只创建分支和修改目标文档，未修改 RTL、未运行回归、未提交或推送。

## 2026-09-16（Asia/Shanghai）— B 阶段基础 RV32M/RV64M

### 实现与时序边界

- 在 `stage/b-rv32-rv64-m` 保留已审阅的六级主流水与有用注释，新增
  `execute/mul_unit.sv`、`div_unit.sv`、`muldiv_unit.sv`，不依赖厂商 primitive/IP。
- `core_types_pkg` 新增 `muldiv_op_e/muldiv_req_t` 和 uOp M 控制；非特权编码与
  Decoder 启用全部 8 项 XLEN M 指令及 RV64 的 5 项 W 指令，`misa.M` 固定报告为 1。
- 乘法以 16×16 无符号小块乘积、分组求和和最终结果三组寄存器实现，高半积按
  MULH/MULHSU/MULHU 作补码修正；除法采用 radix-2 恢复算法，普通操作迭代有效
  位宽次，W 只迭代 32 次。除零/最小负数除以 -1 返回 ISA 规定值，不产生 Trap。
- 请求在 E0 握手时锁存实际前递操作数：乘法 E2 后响应有效，普通除法 E(L+1) 后
  有效，特殊除法 E0 后有效；交付还需响应握手。Verilator 与综合使用同一数据路径。
- EX 保存单条在途状态，接收请求后撤销 valid，保持完成结果直至 EX/MEM 接收；
  `pipeline_ctrl` 增加 EX 等待与独立发射许可，较老 MEM/WB 无反压时继续排空。
  取消来自会杀死当前指令的较老 WB 重定向，不接受年轻 D1 异常取消。
- Core 在 D2/EX HOLD 时保存 WB 已提交的 GPR 新值，避免较老 WB 排空、旁路消失
  后读到过期操作数；流水包注释同步说明 HOLD 保持指令身份而允许该操作数刷新。

### 测试与文档

- 新增乘法、除法、统一 MDU 和 EX 四个 unit TB，以及全部 M 指令、延迟访存与
  精确 Trap/MRET 三个 directed TB。共享检查器采用独立宽算术参考、固定种子和
  显式求值顺序，覆盖符号、W、输入变化、固定延迟、反压、取消、复位和后端交替。
- 同步 Package/Decoder/CSR/流水控制单元测试及 RTL 清单；从既有 pinned Git
  对象复制 21 个 UM `.S` 与 2 个 Makefrag，逐字节保持上游，补充 vendor 清单。
  根目录 `riscv-tests/` 仅只读访问，不恢复其已有工作树差异，不修改或提交该 clone。
- 全部仿真显式启用 `--assert`。当前 Verilator 会在部分循环内 `$finish` 后落入
  超时 `$fatal`，且可能返回 0：12 个旧 directed/ISA/benchmark harness 改为先跳出
  采样循环，未完成才报超时，最后统一结束；不改变程序或硬件预期。
- unit/directed/ISA/benchmark runner 拒绝含 `%Fatal/%Error/Assertion failed` 的
  日志，不能仅靠进程返回码或 PASS 文本判定成功。
- benchmark 默认改用 `rv32im_zicsr/rv64im_zicsr`，port 编译信息同步；保留
  RV32 宽整数 ABI helper，官方 CoreMark 源码未改动。
- 新增 `docs/understand/M_EXTENSION.md` 与 `docs/PLATFORM_ADAPTATION.md`；同步
  README、项目目录、仿真说明、硬件/软件路线与性能解读。平台目标同时覆盖
  Zynq-7020 与紫光同创盘古 676-200K Pro；厂商工程、BRAM/时钟/IO 与约束在平台层隔离。

### 最终验证结果

- `make test XLEN=32/64` 均通过：每种位宽 3 个顶层 lint、35 unit PASS；13 项
  directed 中各 12 PASS、1 非适用位宽 SKIP。新 M 整核程序为 RV32 33 条退休/
  242 周期、RV64 50 条退休/595 周期；M wait 为 121/185 周期，M trap 为 119/183 周期。
- 最后对固定种子检查器的求值顺序整理后，重新运行两种位宽全部 35 项 unit，均 PASS。
  mul/div/统一 MDU 分别为 RV32 516/516/1060 项检查，RV64 644/1028/1700 项检查。
- `make riscv-tests XLEN=32`：`58/58` PASS（MI 10 + UI 40 + UM 8），FAIL 0；
  `XLEN=64`：`78/78` PASS（MI 13 + UI 52 + UM 13），FAIL 0。每种位宽显式
  SKIP 2 项 UI：`fence_i`、`ma_data`；其他超出当前平台的测试族未纳入。
- `make benchmark-smoke XLEN=32/64` 各 1 PASS：3334/371 周期。
- `make coremark XLEN=32/64` 各完成校准与 performance/validation；四次正式运行
  CRC 均 PASS，计时区间均超过 10M 周期。RV32 performance 为 28 次迭代/
  11,067,231 ticks、`2.529991 CoreMark/MHz`；validation 为 11,094,314 ticks。
  RV64 performance 为 26 次迭代/11,406,036 ticks、`2.279495 CoreMark/MHz`；
  validation 为 11,456,652 ticks。
- `SYNTHESIS` 宏下 RV32/RV64 Core lint 均通过；这不是 FPGA 综合。当前没有新的
  WIDTH/LATCH/UNOPTFLAT/MULTIDRIVEN 警告，既有未使用信号/参数等告警仍保留。
- 负向诊断确认故意失败的断言和 1 周期 ISA 超时均非零退出；正向最终日志无致命
  错误。23 个新增 vendor 文件逐字节匹配 pinned commit；全部 runner `bash -n`
  与 `git diff --check` 通过。
- 未执行 Vivado、盘古厂商工具、DSP 映射、实现时序或上板，不能将仿真分数当作
  FPGA Fmax/板级成绩。本次留在开发分支工作树，未提交、合并或推送。

## 2026-09-18（Asia/Shanghai）— M 扩展可选算法与统一握手

### 范围与接口

- 按本次授权在 `stage/b-rv32-rv64-m` 继续完善，沿用用户已整理的
  `execute/M_extension/`，保留有用注释与功能分块。未恢复或提交本轮开始已有的
  无关工作树改动；未修改上游 riscv-tests、CoreMark vendor 或厂商工程。
- 保留 `core_types_pkg::muldiv_req_t`：它描述跨周期请求快照；组合 ALU/branch
  继续使用显式端口。新增 `ex_mdu`，集中请求拼接和 EX 发射/等待适配，移除
  `ex_stage` 中的 MDU pending 寄存器及直接握手组合块。
- `muldiv_unit` 唯一拥有 IDLE/RUN/RESULT、ready/valid、busy 和最终结果保持。
  `mul_unit/div_unit` 改为共用 ISA 语义层，算法使用 start/done；下层不再复制
  外部反压状态机。取消/复位清除全部计算有效状态，优先于接收和交付。

### 算法与时序

- 乘法保留先算 U×U、再按 MULH/MULHSU 修正高半积的方式。新增 `mul_dsp`
  （16×16 `*` 部分积）、`mul_booth_wallace`（Radix-4 编码与真实 3:2 压缩树）、
  `mul_shift`（逐位移位加法）；`wallace_tree` 负责压缩到两行。
  原来的位权分组加法保留在 DSP 后端，明确它不是 Wallace 树。
- 除法先处理除零/最小负数除以 -1，再 abs、无符号幅值运算、符号恢复和 W
  扩展。新增 `div_shift` 与 `div_srt4`，数据路径均不使用 `/` 或 `%`。
  SRT 包含有符号部分余数、完整精度 QDS、Q/Q-1 在线转换及末余数修正；
  `div_srt4_qds/div_srt4_otf` 独立成模块。采用固定二进制缩放和较宽通路，
  尚未优化归一化、截断 QDS 或 carry-save 余数，也未推断 FPGA 性能优劣。
- `MUL_IMPL=0/1/2` 选择 DSP/Booth-Wallace/移位；`DIV_IMPL=0/1` 选择移位/SRT。
  默认 0/0，Make 和所有 Verilator runner 同步参数，编译时只实例化选中后端。
  厂商 IP 留待未来评估，平台目标仍为 Zynq-7020 与盘古 676-200K Pro。
- 请求 E0 握手后，DSP/Booth 乘法 E3、移位乘法 E(XLEN+1)、移位除法 E(L+1)、
  SRT E(L/2+3)、特殊除法 E1 后 rsp_valid 有效，L 为有效除法位宽；实际交付
  还需下一个 ready 上升沿。统一结果寄存器使默认乘法/特殊除法各多一拍。
  六级主流水和原有按指令年龄处理等待/取消的规则不变。

### 验证与测试适配

- `make test XLEN=32/64` 均通过：每种位宽 3 顶层 lint、38 unit PASS、
  directed 12 PASS / 1 非适用位宽 SKIP。
- `tb_muldiv_backends` 六种组合各完成 RV32 1576、RV64 2536 项独立算术及
  协议检查，覆盖全部适用指令、随机大小除数、W、精确延迟、快照、反压、
  乘法/除法各自的运行中与结果待交付时取消/复位，以及交替后端。
- `tb_mdu_unsigned` 穷举 65536 对 8 位输入：乘法 196608 次、非零除法
  130560 次比较，五种 SRT 商位与末余数正负两条路径均覆盖。
  `tb_div_srt4_components` 另完成 QDS 130815 次、在线转换 5120 次检查。
- 标准 riscv-tests：RV32 58 PASS（MI 10 + UI 40 + UM 8），RV64 78 PASS
  （MI 13 + UI 52 + UM 13），各 FAIL 0；各 SKIP `fence_i`、`ma_data` 两项。
- 新增 `make mdu-backends` 与 runner：先生成正式 ISA 镜像，再对六种组合各跑
  三个 M 整核 TB 和全部 UM。最终 RV32 66/66、RV64 96/96 PASS。
  矩阵初次在移位乘法下发现旧 TB 固定九拍 Load 无法覆盖“MDU 结果等待 WB”，
  因而将该配置 Load 延迟延长为 XLEN+9；没有删除覆盖断言或改变 RTL。
  修改后完整重跑两个位宽的六组合整核/UM 矩阵，全部通过。
- C smoke 两种位宽均 PASS，3335/372 周期。默认 CoreMark performance/validation
  四次 CRC 均通过：RV32 28 迭代、performance 11,330,319 ticks、validation
  11,357,402 ticks、2.471246 CoreMark/MHz；RV64 25 迭代、performance
  11,202,057 ticks、validation 11,250,847 ticks、2.231733 CoreMark/MHz。
  分数变化来自真实延迟，旧分数作为历史结果保留。非默认算法未做正式 CoreMark 跑分。
- 两种位宽 × 六种配置的 `SYNTHESIS` 宏 Core lint 通过；未执行实际 FPGA
  综合/实现/上板。修改过的 runner `bash -n` 与 `git diff --check` 通过。
- 同步 README、硬件路线、目录、仿真/上板、平台适配、M 扩展解读与性能说明。
  本次未提交、合并或推送，供后续逐模块审核。

## 2026-09-22（Asia/Shanghai）— B 阶段 MDU 完善与双仓库发布分工

### RTL 与接口

- `mul_dsp` 化简为单个完整 `*`，不再手工构造 16 位部分积；Booth 编码、Wallace
  3:2 压缩树和最终进位传播加法继续保持独立模块边界。
- `muldiv_unit` 在后端 `done` 当拍直接给出响应，仅在 EX/MEM 反压时进入 RESULT
  保留结果，消除统一包装器原有的额外完成周期。除零和有符号溢出仍在请求沿保存
  ISA 规定结果，不启动真正除法器。
- Radix-4 SRT 改为归一化除数、显式 PD 表、截断 carry-save QDS、3:2 余数压缩、
  Q/Q-1 在线转换和最终余数修正；RV64 W 形式只迭代 32 位有效宽度。
- 新增依赖感知的 `mdu_issue_control`。接口命名为 `mdu_operands_ready`，只阻止依赖
  尚未返回 WB Load 的 MDU；无依赖运算可以与存储器等待重叠，写入 x0 不构成依赖。
- `pipeline_ctrl` 显式输出 `d1_flush`：WB/EX 重定向和 EX 序列化清除年轻 D1 更新，
  D1 自身重定向/序列化不会误杀自己的训练；predictor arbiter 同步清除 pending D1，
  同时保留引发 EX 重定向的老分支训练。
- M 扩展按 `mul/booth-wallace`、`div/srt4` 重新组织，源码清单按子模块先于顶层排列。

### 验证

- `make test XLEN=32/64` 均通过：每种位宽 39 unit PASS；13 项 directed 中
  12 PASS、1 个非适用位宽用例 SKIP。SRT 组件完成 QDS 134870、CSA 4096、
  OTF 5120 项检查；8 位无符号后端穷举 65536 对输入全部通过。
- 六种乘除后端整机矩阵全部通过：RV32 66 项、RV64 96 项。标准 riscv-tests
  保持 RV32 58/58、RV64 78/78，各自明确跳过 `fence_i` 与 `ma_data`。
- benchmark smoke 为 RV32 3318 周期、RV64 365 周期。CoreMark performance 与
  validation CRC 全部正确；默认 0/0 得分为 RV32 `2.821267 CoreMark/MHz`、RV64
  `2.490061 CoreMark/MHz`。SRT 配置得分相同，说明该负载不足以区分除法器。
- `git diff --check` 通过；未执行 Vivado、盘古综合、实现、时序分析或上板。

### 仓库职责

- `rhbyv-cpu-forlinux` 保留硬件 RTL、测试、工具脚本和硬件工作流文档，不再包含
  `docs/COMMIT.md`、`docs/understand/` 或软件路线图，也不把这些内容并入 README。
- `hgb-aisystem_riscv` 成为协作发布和未来软件栈仓库，接收硬件快照、修改记录与
  理解文档。rhbyv 的重大提交先在 hgb 创建对应分支并通过 PR 审阅；hgb 的软件侧
  修改默认不反向同步到个人硬件仓库。
