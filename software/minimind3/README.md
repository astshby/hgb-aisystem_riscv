# MiniMind-3：FP32 与全整数 C 推理

本目录仅保留 C FP32 原模型和 `w8a16_int` 全整数推理。普通编译、分词、生成均无需 Python、PyTorch 或 CUDA。默认单轮对话、关闭思考、贪心选择 Token。

从仓库根目录执行：

```sh
cd software/minimind3/c_runtime
make -j4 PRECISION=fp32
./minimind3.elf --prompt '请介绍一下你自己'
make -j4 PRECISION=w8a16_int
./minimind3.elf --prompt '请介绍一下你自己' --max-new-tokens 64
```

不指定 `PRECISION` 时为 `fp32`。`main.c` 顶部的 `prompt` 保留为 `hello, how are you?`；修改后重新 `make` 即可。命令行 `--prompt` 优先。

## 配置与装载

- `MAX_SEQ_LEN=2048`：输入（含对话模板）与输出的总容量；模型配置的最大位置为 32768，增大容量同时增加 KV Cache 内存，不保证更长上下文的回答质量。
- `MAX_NEW_TOKENS=256`：默认生成上限；运行时可用 `--max-new-tokens N` 覆盖，实际输出同时受总容量、结束 Token 限制。
- 整数 RoPE 表已导出 2048 个位置；增大 `MAX_SEQ_LEN` 前，先以相同容量重新 `make export-integer`。FP32 RoPE 在运行时计算。
- `MODEL_STORAGE=embed`（默认）：二进制参数经 `.incbin` 编译成只读 `.o`，生成可独立运行的 ELF。
- `MODEL_STORAGE=file`：从外部文件装载；默认相对路径要求在 `c_runtime` 中运行，也可显式指定路径：

```sh
make -j4 PRECISION=w8a16_int MODEL_STORAGE=file
./minimind3.elf --model assets/model_w8a16_int.bin --tokenizer assets/tokenizer.bin --prompt '你好'
```

FP32 的外部权重改为 `assets/model_fp32.bin`。每种精度、装载方式和编译配置使用独立构建目录；`minimind3.elf` 指向最近一次 `make` 选择的程序。`make run PRECISION=w8a16_int ARGS='--prompt 你好'` 可直接运行指定模式。

`make PRECISION=w8a16_int hex` 按每行一个小端 32 位字生成参数 HEX；FP32 同理。`make clean` 仅清理构建产物，保留参数与原始模型。已移除测试、校准目标及中间混合精度模式。

## 可选：重新导出参数

已存在 `assets/*.bin` 时不需要此步骤。Git 不保存大权重和导出二进制；新克隆需要恢复官方模型后重新导出。

官方来源为 Hugging Face `jingyaogong/minimind-3`，锁定 revision `f92512d4cd6142fa9acc0d6022375049a8974bf6`。将该版本的 `model.safetensors` 放在 `model/`；其余官方配置已保留，`model_sha256.json` 记录所有源文件校验值，导出时逐个检查。

从本目录创建独立的导出环境，只安装三个固定依赖：

```sh
python3 -m venv .venv-export
.venv-export/bin/pip install -r requirements-export.txt
cd c_runtime
make export PYTHON=../.venv-export/bin/python
make export-integer PYTHON=../.venv-export/bin/python MAX_SEQ_LEN=2048
```

FP32 导出直接通过 NumPy＋safetensors 将官方 FP16 精确转换成 FP32，并导出 ByteLevel BPE、Unicode 分类表。整数导出直接读取 FP32 文件，生成 INT8 矩阵、整数尺度、INT16 Norm 参数及非线性/RoPE 表，不需要中间量化文件。`assets/manifest.json` 和 `integer_manifest.json` 记录布局、来源、大小及 SHA256；Embedding 与 LM Head 共用一份权重。

## 模块与部署边界

`main.c` / `integer_main.inc` 是入口；`src/tokenizer.c` 负责分词；`src/model.c` / `backend_cpu.c` 是 FP32 模型及算子；`src/integer_*.c` 是整数参数装载、缩放、算子与模型；`platform_host.c` / `platform_integer.c` 集中处理宿主内存、文件、输出和计时。

FP32 链接 `-lm`，关闭 fast-math。全整数运行使用 INT8 权重、INT16 状态、INT64 累加，整数动态尺度及查表，统一尺度 INT32 logits 选择 Token；保留饱和、下溢和查表范围统计，计时也为整数，不链接 `-lm`。

可通过 `CC`、`CROSS_COMPILE`、`CFLAGS`、`CPPFLAGS`、`LDFLAGS`、`LDLIBS` 指定工具链和编译配置。当前交付为本机 C11 工程；交叉编译不代表已在开发板运行，后续仍需替换平台接口、裸机启动及内存布局，并接入总线/加速器。

## 本次迁移验证（2026-10-23）

在分支 `codex/minimind3-two-runtimes` 精简迁移，未改硬件及其他软件。新导出工具在禁止导入 PyTorch/Transformers 的环境中运行；FP32、分词参数、2048 位置整数参数均与迁移前逐字节一致。分别保存中文、英文提示的 8 Token 基线；迁移后两种精度、embed/file 两种装载的文本、Token 与逐层 trace 均与各自迁移前基线一致。整数 ELF 检查浮点指令、软浮点辅助函数及 libm 依赖；该检查不代表回答质量评估。本次未重跑 20 路误差诊断。

验证基点为主仓库 `91e33f748d3812ccb936018b291a8e9d168863e5` 加本次未提交源码，使用默认 GCC 构建参数（`-O3 -std=c11 -fno-fast-math -ffp-contract=off`）、容量 2048、生成默认 256。两种装载均按上述 `make` 命令构建，验证运行加 `--max-new-tokens 8 --output-ids IDS --trace TRACE`，提示分别为 `你好，请介绍一下你自己。` 与 `Explain what a CPU does.`，共 8 次迁移后一致性检查通过。临时构建日志、基线和审计记录位于系统临时目录的 `minimind_migration/`，不纳入工程。

默认 embed ELF 的 SHA256：

```text
fp32       f4bb664fde895e41c9d92125a61d99ef61561c036ddc2e60e0f21f7b98c059b4
w8a16_int  03599d7d13456df88ffbe58e389d1f20e7a3f6a27a62226690543c270f6fe0eb
```

## W8A16 矩阵加速器与 Verilator 对比

新增可选 SoC 加速器，源码位于 `vsrc/soc/mm3/`。它处理七个 Linear 和 LM Head 的完整整数路径：INT8×INT16、INT64 累加、整数行尺度、向量最大值统计、统一输出尺度、最近偶数舍入和饱和。普通输出为 INT16，Head 为同尺度 INT32。其余算子仍由整数 C 执行；FP32 与默认宿主提示词保持原行为。

从仓库根目录运行：

```sh
make mm3-accel-unit XLEN=32
make mm3-accel-unit XLEN=64
make mm3-accel-soc XLEN=32
make mm3-benchmark XLEN=32 MM3_CASE_JOBS=4
make mm3-model-compare XLEN=32
```

依赖完整的 Verilator 安装、宿主 C 编译器、RISC-V GNU 工具链及现有资产。模拟构建使用项目既有 Python 镜像转换工具及标准库夹具/报告工具；裸机 ELF 的推理不运行 Python。`VERILATOR` 可指定工具入口，`VERILATOR_ROOT` 可指定运行库；`RISCV_TOOL_ROOT` 指定交叉工具链目录。

- 默认采用 `scripts/verilator/p1_core_config.sh` 的当前 P1 配置。`MM3_CORE_PROFILE=environment` 才使用外部提供的 CPU 配置；两后端始终使用同一 ELF、同一 CPU/DDR 参数和同一内存布局。
- `MM3_MAC_LANES=16`，支持 1/2/4/8/16/32 路；`MM3_SIM_SEQ_LEN=64`；`MM3_SIM_NEW_TOKENS=2`；容量不得超过当前资产及固定仿真布局支持的 2048。
- `MM3_CASE_JOBS` 控制独立矩阵案例并发数，默认 1、最多 8；`MM3_SIM_PARALLEL=2` 默认并行运行同一案例的两个 RTL 实例，可设 1。`JOBS` 控制 Verilator 编译并发。
- `MM3_MAX_CYCLES` 为每个实例的 64 位周期上限，默认 `1000000000000`。长任务每百万周期记录进度；达到上限返回失败，不能把超时当作通过。
- 构建缓存按 CPU、XLEN、MAC 路数、容量和生成上限隔离。每次执行固定脚本、ELF、源码和资产快照，结果在 `build/mm3/.../runs/`，日志及 JSON 在 `logs/mm3/`。`logs/mm3/latest-<类型>-rv32` 等链接指向相应最新运行。

`mm3-accel-unit` 比较独立 C 参考与 RTL 的 1600 组乘除、舍入和饱和标志，以及 13 组 GEMV（含真实模型尺寸、6400×768 Head、最大内积和非整除尾部），并检查文件损坏、后端错误传播、上下文和分配失败。负面用例中的 `Invalid...` 或加载失败是预期诊断，最终 PASS 和进程状态才是验收依据。

`mm3-accel-soc` 由真实 RTL CPU 操作 MMIO，比较相同程序的两个后端，并检查原 DMA 与加速器并发、Cache 所有权和分配失败。完整输出向量及 scale 会与独立宿主 C 逐字节比较，不能只凭摘要判断通过。

`mm3-benchmark` 使用真实第一层七个权重矩阵和 Head，随后比较单层。矩阵和单层采用从已校验资产导出的**描述符夹具**，不为每个微基准重复运行整文件 CRC；计算仍全部发生在 RTL CPU 和加速器中。它们不能代替完整模型装载验收。

`mm3-model-compare` 的 CPU 实际执行原模型加载器的 CRC、索引、尺度和参数检查，分词“你好”/“Hi”、运行全部八层并最多生成两个 Token；另做固定 Token 追加以覆盖 KV Cache。分别运行无 trace 的性能测试及带完整节点数据的正确性测试。全模型纯软件 RTL 仿真可能非常耗时，应先查看小矩阵和单层实测，再安排长任务。

性能以仿真 `mcycle` 为准，包含硬件方案的缓冲准备、Cache 维护、MMIO、DMA 和等待；模型装载、分词和输出另列。软件和加速器在计时前执行相同的冷 Cache 准备。JSON 记录 CPU、驱动和硬件阶段周期，STALL 项与阶段周期可能重叠，不应再次相加。诊断 trace 运行不生成加速比。没有综合、布局或上板结果时，不把仿真周期换算成已实现的 FPGA 频率。

MMIO、数据通路和验证记录见仓库 `docs/understand/SOC_SYSTEM.md` 的 MiniMind 章节。

## 暂停时的设计与验收交接（2026-10-26）

**以下为暂停时快照；后续已按用户指令恢复，最新状态见本节末尾“恢复后的验收”。整体验收尚未完成。** 本次交接检查未发现本任务的 runner、simulator 或 Verilator 编译进程；已有日志、镜像和源码全部保留。未完成运行没有 CPU 状态检查点，恢复时必须从启动重新执行，不能从日志中的周期续跑。

源码位于分支 `codex/minimind3-w8a16-accelerator`，基点为 `9a31933977133426536b9b38af4a3eb797c014c6`，实现和交接记录保存在此专用分支；具体提交可用 `git log -1` 查看。下列结果针对各运行冻结的源码，不能把基点提交号当成包含新加速器的提交，也不能把早先快照的通过自动推广至全部当前文件。

### 已有设计

| 部分 | 当前实现与边界 |
|---|---|
| RTL | `vsrc/soc/mm3/`：定点数学、块读取、GEMV 与 MMIO；默认 16 路 INT8×INT16，INT64 累加，逐行 61 位有效中间数，全向量最大值决定输出尺度；INT16 激活 / INT32 logits |
| SoC | 新设备编号 15，MMIO `0x10050000`，默认关闭；与原 DMA 通过双客户端仲裁共享原 256 位块出口，不另设 DDR 计算模型 |
| C 后端 | 原整数 Linear 保留为 CPU 基准，经统一分发选择加速器；硬件错误向上返回，不静默回退；CPU 继续执行其余整数模型运算 |
| 驱动 | 对齐缓冲、发布输入前 Cache clean、完成后 Cache flush、MMIO 轮询及 64 位阶段计数；两个后端预留同样内存 |
| 裸机 | 同一 ELF 由启动配置选择后端；128 MiB 仿真 DDR 存权重、状态及堆，ITCM 放代码；整数计时和输出，不链接 libm |
| 验证入口 | 四个根 Make 目标已加入；真实矩阵、单层、完整模型入口都已有实现，但入口存在不等于对应验收完成 |
| 限制 | 专用裸机平台为单次启动的 bump allocator，`free` 不回收；固定 DDR 布局和 trace 容量不等于通用长期运行 BSP |

数据流、完整 MMIO 表、状态机握手和 Cache 所有权见 [SoC 设计说明](../../docs/understand/SOC_SYSTEM.md#minimind-w8a16-可选矩阵加速器)。

### 已完成检查

| 检查 | 已有证据与结果 |
|---|---|
| 整数数学和 GEMV 单元，RV32/RV64 | `logs/mm3/run-unit32-complete.log`、`run-unit64-complete.log`：各 1600 组数学用例、13 组 GEMV，累加、中间尺度及输出与 C 精确一致；含 6400×768 Head、尾部、极值、反压、错误和复位恢复 |
| 装载/失败传播 | 同上 `MM3_RUNTIME`：损坏/截断/CRC 正确但尺度非法、Token/上下文边界、分配失败、后端错误传播通过 |
| 内存与未定义行为检查 | `sanitizer.log`、`runtime-sanitizer.log`：已有算术与 runtime ASan/UBSan 检查通过；不代表整模型 RTL 已通过 |
| 宿主行为保留 | `host-current.txt` 及 `build/mm3/host-before.*`、`host-current.*`：中文短提示 2 Token 和完整整数 trace 与修改前一致；FP32 可构建，未新做完整 FP32 精度评估 |
| 实际 CPU / MMIO / DMA / Cache，RV32/RV64 | `default-entry-soc32.log`、`default-entry-soc64.log`：两后端完整输出和 scale 与宿主 C 一致；并发 32 KiB 原 DMA 与加速器、邻接保护及 4 个预期分配失败通过 |
| 默认 CPU 配置回归 | `regression-test-default-rv32.log`、`regression-test-default-rv64.log`：各 80 PASS、2 SKIP |
| P1 CPU 基础单元 | RV32/RV64 各 57 PASS；见 `regression-test-p1-rv32.log` 的 unit 部分及 `regression-unit-p1-rv64.log`；P1 directed 尚有下述失败 |
| P1 ISA | RV32 58/58，RV64 78/78；各另跳过 fence_i、ma_data；见 `regression-riscv-tests-rv32.log` / `regression-riscv-tests-rv64.log`（以实际日志文件名及 PASS 汇总为准） |
| P1 benchmark / CoreMark | 两宽度 smoke、performance、validation 已通过；CoreMark/MHz：RV32 3.036833、RV64 2.948412；见 `regression-*rv32.log` / `regression-*rv64.log`；这些是 CPU 回归，不是模型加速比 |
| SoC 回归与 lint | 两宽度 decode、fabric、DMA、profile、throughput、local TCM 已有通过日志；加速器开关 lint 对照无新增结构警告位置，仍有 10 个基线位置，不称为零警告 |
| 无浮点审计 | 已构建裸机镜像的反汇编/符号审计通过；只覆盖已有镜像，不代表板上验证 |

8 路 MAC 另有一次较早的 RV32 单元通过记录（`run-unit32-lanes8.log`），当时是 11 组 GEMV；其余可配置路数尚不能一概标为通过。

### 已实测周期和误差

下面是 **RTL CPU 周期**，硬件一侧包含驱动、缓冲、Cache、MMIO 和 DMA 开销。计时区间不含装载、分词与控制台输出；DDR 等待计数与阶段计数有重叠，不能重复相加。所有结果均是整数 C 基准与硬件的一致性，**不是相对 FP32 的量化误差**。

最新 SoC 小矩阵（17×33）冷 Cache 对照：

| CPU | 软件周期 | 加速器周期 | 区间加速比 |
|---|---:|---:|---:|
| RV32 P1 | 279766 | 5821 | 48.0615× |
| RV64 P1 | 183588 | 5156 | 35.6067× |

对应运行为 `logs/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s64-g2/20261026T112142Z-71862/` 和 RV64 同配置目录下的 `20261026T112302Z-72215/`；`report-m0-c0-t0.json` 保存完整输出一致性和周期分项。并发 DMA 对照分别为 45.6891×、33.4293×，见同目录 `report-m4-c0-t0.json`。

真实第一层矩阵权重、固定测试输入的 RV32 P1 对照如下。每项输出整数及 scale 与宿主参考精确一致，最大绝对误差和 RMSE 均为 0；这些结果不等于完整网络轨迹一致：

| 矩阵（行×列） | 软件周期 | 加速器周期 | 区间加速比 |
|---|---:|---:|---:|
| Q 768×768 | 21513240 | 227716 | 94.4740× |
| K 384×768 | 10760606 | 118425 | 90.8643× |
| V 384×768 | 10763397 | 118445 | 90.8725× |
| O 768×768 | 21526081 | 227696 | 94.5387× |
| Gate 2432×768 | 68137738 | 703389 | 96.8706× |
| Up 2432×768 | 68152645 | 703393 | 96.8913× |
| Down 768×2432 | 43932763 | 442847 | 99.2053× |

证据目录：`logs/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s71-g2/20261026T103324Z-58554/`，分别是 `report-m1-c0-t0.json` 至 `report-m1-c6-t0.json`。配置为 16 MAC、P1、128 MiB 同时序 DDR、同 ELF；该快照 ELF SHA256 为 `a0a1cf82271b99163d163a0180f9c8b10085fed9d2e74ea5894ba0a5f6d1bf0e`，源码归档 SHA256 为 `cec95033f5e5959bac6b0ae00f0bb061232dec36c0897b2187ddcf8f4ced969e`。真实矩阵基准容量为 71；完整模型试跑容量为 72，不能混作默认 64 的同一实验。

### 未完成、失败和恢复顺序

| 项目 | 停止时状态 / 后续要求 |
|---|---|
| 真实 Head 的 SoC 软件/硬件对照 | 硬件实例有 PASS，但软件日志止于约 173000000 周期，无配对报告；不能通过。单元 Head 通过不能替代此项 |
| 真实单层 | 尚无配对 PASS 报告；需完成整层节点、scale、KV 对照与周期统计 |
| 完整八层模型 | 中文无 trace 试跑日志止于约 187M/188M 周期，两个后端均未记录 MODEL_LOADED；没有模型生成验收结果。见 s72 配置 `20261026T103503Z-58801/m3-c0-t0-b*.log` |
| 全模型正确性 | “你好”与“Hi”、带 trace、分词/逐节点/KV/logits/Token 文本对照、至少一次新增位置的固定 Token KV 步均待完成 |
| 全模型性能 | prefill、首 Token、decode、整体周期和端到端加速比待实测；目前不能声称整体模型加速成功 |
| P1 通用 directed 回归 | `tb_core_branch_serialize_cancel.sv` 仍访问 legacy 内部信号，P1 编译失败；需适配监视器并重跑。未改 CPU RTL 绕过，不得把默认配置回归当作 P1 全回归 |
| 当前最终源码统一重验 | 期间修正过公平内存布局、输出逐值比较、RV64 console/tohost 字节通道和 trace 头；结果按冻结快照记录。恢复后应对最终源码统一验收，旧中断/替换运行不作最终证据 |
| 工程外验证 | 未做综合、资源/时序、布局布线或上板；本阶段本来只限 Verilator |

恢复时先完成 Head → 单层 → 完整模型性能 → 完整模型 trace，处理 P1 directed 兼容问题，再统一检查最终快照。可以使用本节前面的四个根 Make 入口；它们会新建运行目录并重新执行，不会自动跳过先前成功项或续跑 CPU 状态。长任务默认上限很大，重新启动前应按可用时间设置 `MM3_MAX_CYCLES` 和并行数。本次停止后未再次运行这些命令。

已用工具为 Verilator 5.044（`v5.044-52-g7e7b6d7fb`）、RISC-V GCC 13.2.0。该主机原来缺少完整 Verilator 运行库，本次匹配源码支持目录放在 `/tmp/mm3-verilator`，不是持久系统安装；重启/清理临时目录后需恢复完整工具环境。各运行的 metadata、源码归档、ELF 和镜像位于 `build/mm3/.../runs/`，原始日志与 JSON 位于 `logs/mm3/`，均为忽略产物，Git 不保存它们。

模型 SHA256：`48a892f78228d3b3f5d4a89f8cbeaa70e44384ee180fa493f53a7ba04e777b56`；tokenizer SHA256：`4486dea9dea95002c93390179d2c4205affa83bdd33ac739995cfe32401c78df`。参数版本未重新量化。暂停的机器可读汇总见 `logs/mm3/progress.json`。

### 恢复后的验收（2026-10-26）

已按“继续完成”恢复。新增以下检查及修正，未把尚在执行的长任务记为 PASS：

- **修正结束判据**：专用 `tb_mm3_soc` 改用 `store_result_monitor`，按完整动态 ID 关联 Store 请求、成功响应与正常退休；同时覆盖 P1 的两个退休槽。控制台只作进度观察。旧版按写请求结束的运行属于早期证据，不替代此次严格判据。
- **严格 SoC 回归通过**：`logs/mm3/strict-soc32.log`、`strict-soc64.log`，两宽度的小矩阵、并发 DMA、Cache 路径及四个预期分配失败均通过。两后端的输出整数、scale 与宿主参考完全一致；区间周期仍分别为 279766/5821（RV32）、183588/5156（RV64）。等待退休只改变测试台结束时间，没有改变 ROI 周期。
- **MAC 参数覆盖补齐**：RV32 的 1/2/4/8/32 路分别跑完 1600 组数学、13 组 GEMV 和 runtime 检查，进程退出码均为 0；16 路沿用已通过的 RV32/RV64 结果。日志为 `logs/mm3/unit-lanes<N>-rv32.log`。这取代早先“8 路仅 11 例”的覆盖记录；非默认路数尚未逐一做全模型 SoC 验收。
- **P1 功能检查与警告分开记录**：原 `run_scoreboard.sh` 每宽度通过 16 项后，被 LSU `UNOPTFLAT` 警告门限拦住；原 SoC runner 每宽度通过 request_queue 后同样被警告门限拦住。随后用冻结的功能检查脚本继续剩余 7 项和 4 项，两宽度均退出 0。因此专用 P1 功能合计各 23 项、SoC 各 5 项通过。证据为 `regression-scoreboard[-soc]-rv*.log`、`scoreboard[-soc]-functional-remaining-rv*.log`；**原 runner 的严格警告门限仍未通过**，未修改或弱化仓库原 runner。
- **警告基线核对**：从基点用 `git archive` 提取源码到临时目录，对相同参数单独 lint，比较类别、源文件和行号；结果保存在 `logs/mm3/p1-warning-baseline/`。不能把基点已有组合环警告称作本次加速器新增问题，也不能据功能通过声称没有警告。原 legacy directed TB 不适配 P1 的问题仍单列保留。
- **完善模型计时口径**：性能版 prefill 改为包含完整输入循环与 CPU 控制的连续区间，区间内不打印进度；trace 版允许打印，但不报告性能加速比。生成、固定 Token KV 步仍分开计数。矩阵 ROI 和已有矩阵周期表不受此改动影响。
- **构建环境恢复**：恢复了匹配版本的 Verilator 临时支持目录；MiniMind runner 将 ccache 写入工程 `build/`，避免受限环境向用户缓存目录写入失败。`prepare` 内部入口可冻结完整运行镜像后退出，不执行 DUT。

严格判据的 Head 与单层 trace 对照已从复位开始，运行记录：

```text
build/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s64-g2/runs/20261026T143541Z-resume-7/
logs/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s64-g2/20261026T143541Z-resume-7/
```

最终连续 prefill 计时版本的完整模型运行记录：

```text
build/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s64-g2/runs/20261026T144324Z-resume-7/
logs/mm3/rv32-p1r1q32i2-scoreboard-s1j8m4-o1-f3-l16-s64-g2/20261026T144324Z-resume-7/
```

完整模型包含中文/英文、性能/trace 四组，每组 CPU/加速器两个实例；均使用对应组内相同 ELF、冷 Cache 与相同 DDR 模型。`replay.json`、`replay_runner.py` 保存实际参数、父快照、镜像和模拟器摘要；CPU 从启动重新执行，没有用宿主替代任何 DUT 运算。镜像来自 `20261026T144243Z-7` 的 prepare 快照。更早的 `20261026T142734Z-resume-4` 和 `20261026T143743Z-resume-6` 因验收判据或计时口径更新而停止，不作最终验收。

宿主黄金参考已生成：中文输入 18 Token，生成 ID `[1968,1364]`；英文输入 19 Token，生成 ID `[1602,36]`。含固定 KV 步后位置分别为 20、21，trace 大小分别为 6206984、6517332 字节，均小于 11 MiB 诊断容量。**这些是宿主参考结果，不是 RTL 已完成的结果。**

长运行尚未形成全部配对报告；完成时应以对应 `report-*.json` 的 PASS 和真实退出状态更新表格。日志中的 `MM3 PROGRESS` 只说明仿真在前进。按当前实测周期与速度，完整软件路径预计为天级长任务；中断不保存 CPU 状态。完整模型精度、KV/logits 一致性与端到端加速比仍待结果，不宣称该阶段完成。
