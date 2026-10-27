# MiniMind-3：FP32 与全整数 C 推理

本轮五域集成仿真通过；PDS 多写 RAM 推断待修，未取得资源/Fmax。100 MHz 为配置目标。
详见 [FPGA 状态](../../docs/fpga/FPGA_ADAPTATION.md#2026-10-27-标准综合状态)。

2026-10-27：本轮已迁移到主 SoC 五域接口，原作者 C 算法、模型锁和导出工具保留。
Core/SYS/DDR-user/外设/NPU 目标为 100/80/125/25/100 MHz，设备控制窗口为 `0x20000000`。
CPU 配置算子，算子通过独立 AXI 主口读写 DDR，系统 DMA 可并发搬运；Cache 所有权由软件维护。
`make minimind XLEN=32|64` 分别执行运行库及 38 命令单层验证。
双宽单层与参考完全一致，RV32/RV64 为 4,680,438/4,678,859 TB 周期。
每宽另有 4 次正常及 4 次预期分配失败通过，包含并发 32 KiB DMA。
本轮 TRACE=0，尚未完成全八层、多 Token、LM Head、语言质量或上板验证。
锁定模型先按下文恢复。软件默认 O3，`SOFTWARE_OPT` 可选 O2/Ofast；整数 ABI 和算法未改。

宿主生成工程保留 C FP32 原模型和 `w8a16_int` 全整数推理；`operators/` 另提供硬件算子参考与驱动。普通编译、分词、生成均无需 Python、PyTorch 或 CUDA。默认单轮对话、关闭思考、贪心选择 Token。

从仓库根目录执行：

```sh
cd software/minimind3/c_runtime
make -j4 PRECISION=fp32
./minimind3.elf --prompt '请介绍一下你自己'
make -j4 PRECISION=w8a16_int
./minimind3.elf --prompt '请介绍一下你自己' --max-new-tokens 64
```

不指定 `PRECISION` 时为 `fp32`。`main.c` 顶部的 `prompt` 保留为 `hello, how are you?`；修改后重新 `make` 即可。命令行 `--prompt` 优先。

## 原作者算子交付记录（2026-10-27）

以下保留原作者的算子、模型和数值记录。旧提交为 `codex/mm3-integer-operators`，
基点 `cbf5a035a21570a24c9885e45543e7023b55ba28`；旧单时钟记录使用不同 Core/总线配置。
当前入口已统一为主 SoC 五域 `tb_mm3_system`，控制经 `mm3_axi_subsystem` 的 AXI CDC，
内存通过独立 AXI 主口访问共享 DDR。旧兼容顶层已从当前树移除，历史见本地 archive 标签。
当前双宽单层、运行库与 DMA 结果见本文开头和项目介绍；下方较早周期不替代本轮结果。
`make mm3-layer-soc TRACE=1` 可另做中间 trace 检查，本轮裁剪复测使用 TRACE=0。

### 用户功能简测结果（2026-10-27，后续更新）

用户自行运行后，已读取实际 `actual.report.json`、38条命令 trace 和仿真日志确认：

| 项目 | 结果 | 测试台总周期 |
|---|---|---:|
| ADD / MUL / RMSNorm / RoPE / Softmax / SwiGLU | 各3条命令，C/Python与RV32 RTL输出/尺度一致 | 28570 / 26930 / 27055 / 27490 / 8690 / 35035 |
| GEMM / KV | 各2条命令，比较通过 | 1230 / 1820 |
| T=4 Attention | 1条命令，比较通过 | 156370 |
| 单 Token、第0层独立RTL链，TRACE=1 | 38条命令、中间trace及最终4736字节全部一致 | 3592430 |
| 同一单层真实RV32 CPU＋驱动，TRACE=1 | 38条命令、中间trace及最终4736字节全部一致 | 3617344 |

CPU程序自身计数区间为3615099周期，测试台为3617344，二者起止点不同。上述不是纯CPU软件与加速器的加速比，两条路径都执行硬件算子。仿真墙钟约169秒/233秒，运行时存在两个任务并行的主机资源竞争，不能用墙钟推算硬件加速。

此次严格整数比较的最大绝对误差/RMSE均为0。另对本条输入14次Norm比较新NR与旧sqrt算法，最大 max_abs 为 `1.8625883058120962e-09`，最大的单次RMSE为 `7.419110002443212e-10`；这只代表该单Token夹具的局部观察，不代表任意输入、完整八层或语言质量。

证据根目录为 `build/mm3-ops/ac60559d357f5ce9/runs/`：独立链 `20261027T021116Z-342120-layer-independent/`，CPU链 `20261027T021142Z-342526-layer-soc/`；每个目录含 `simulation.log`、`actual.report.json`、`fixture.json`、配置/源码SHA与逐算子trace。参数摘要仍为 `ac60559d357f5ce9`；本次用户工具为 Verilator 5.045 devel，ELF及源码身份以各运行目录记录为准，不沿用首次静态编译的ELF SHA。

发现并修复静态脚本缺陷：原来 `if rg ...` 在未安装rg时把退出127当成无匹配，错误打印PASS。新的 `mm3_audit.py` 仅依赖已必需的Python；发现浮点/结构问题返回1，证据缺失或不可读返回2，直接调用使失败中止，不再依赖rg。已做合成文本的正负用例和缺文件用例，并只读取现有日志补做RV32/RV64 ELF、整数对象、算子链结构共6项审计，均通过；结果在 `logs/mm3-ops/ac60559d357f5ce9/audit-recheck.json`。原始含“rg未找到”的PASS不能单独用作完整静态审计证据。

本次仅检查用户已启动任务及产物，没有启动/重启仿真。RV64功能、完整八层/多Token、综合、时序、资源和上板仍未验收。下方“首次实现阶段”保留当时静态交付记录，其中待运行状态已由本节的RV32简测结果更新。

### 本轮做了什么

- 将 RTL 拆为 `vsrc/soc/mm3/{common,gemv,gemm,ew_add,ew_mul,rmsnorm,rope,softmax,swiglu,kv_cache,attention,top}/`。原 GEMV 算法移到 `gemv/mm3_gemv_accel.sv`，旧寄存器和共享 DDR 出口继续保留；新 `top/mm3_accel.sv` 仲裁旧 GEMV 与描述符算子命令。
- 新增默认 **8×8 寄存器化脉动 GEMM**，支持 QK 的 INT16×INT16、转置 B，以及 PV 的 UINT16×INT32，INT64 累加；支持分块、输入元素步长和非整除尾部。默认 GEMV 仍为 16 路，向量算子 8 路。
- 新增整数 ADD/MUL、RoPE、Softmax、融合 SwiGLU、KV 读写和 GQA Attention 调度；Attention 的 QK/PV 共用上述真实 GEMM，不由宿主代算。
- RMSNorm 新增平方规约树、512 项 LUT 和两次 Newton 倒平方根；阶段间有真实寄存器。常量工具同时生成可综合 case ROM 与 C 表，不依赖 DW 或 `$readmemh` 初始化计算 ROM。
- `software/minimind3/operators/` 提供 128 字节命令 ABI、整数 C 软件参考、MMIO/Cache 驱动和裸机单层入口。新后端按命令分发，独立于旧 `IRuntime`；原宿主推理、默认提示词、原有 FP32/全整数运算保留。
- `scripts/verilator/mm3_integer_reference.py` 为独立 Python 整数参考，不依赖 PyTorch；`mm3_fixture_ops.py` 从锁定参数抽取单层夹具，`mm3_compare_ops.py` 做严格字节比较。生成结果仅供比较，后级计算使用前级 DUT 实际输出。
- 新增 CPU-free BFM 算子链测试台和真实 P1 CPU＋Cache＋MMIO/DMA 入口。默认均为第 0 层、Token ID 1、位置 0、无历史 KV；另有长度 4 的 Attention 用例。二者没有执行 LM Head、完整八层或文本生成。

### 唯一配置源

修改 [`vsrc/soc/mm3/mm3_config.h`](../../vsrc/soc/mm3/mm3_config.h)，再运行根目录 `make mm3-config`。注释为中文，宏必须写成十进制整数；SV 包和 C/RTL 常量表由脚本生成，不手工编辑。

| 宏 | 默认 | 含义与约束 |
|---|---:|---|
| `MM3_GEMV_LANES` | 16 | 1/2/4/8/16/32；旧入口仍允许显式 `MM3_MAC_LANES` 覆盖 |
| `MM3_GEMM_ROWS/COLS` | 8/8 | 脉动 PE 行列数，允许 1..16 |
| `MM3_VEC_LANES` | 8 | 平方规约/向量乘法的组宽，1/2/4/8/16 |
| `MM3_MAX_VECTOR` | 2432 | 新向量算子容量；旧 GEMV 仍可输出 6400 行 Head |
| `MM3_NORM_MAX_LEN` | 768 | Norm 容量及离线长度倒数表上限 |
| `MM3_SEQ_CAP` | 64 | 硬件 KV/Attention 容量，和宿主 `MAX_SEQ_LEN` 分开 |
| `MM3_GEMM_MAX_M/N/K` | 16/96/96 | 缓冲容量；N/K 必须覆盖 96 和上下文容量 |
| `MM3_DDR_BYTES` | 134217728 | 默认 128 MiB；与本次测试的 DDR 地址窗口一致 |
| `MM3_RSQRT_LUT_BITS/ITERS` | 8/2 | 默认两区各 256 项、两次迭代；允许 bits=4..10、iters=1..3 |
| `MM3_TEST_LAYER/POSITION` | 0/0 | 第一版夹具固定第一层、位置零；其他值会拒绝 |
| `MM3_TEST_TOKEN_ID` | 1 | 可改为 0..6399 的输入 Token，不进行分词 |
| `MM3_TEST_ATTN_LEN` | 4 | 独立 Attention 长度，2..上下文容量 |
| `MM3_MAX_COMMANDS` | 256 | 单层命令/比较区域容量，最多 512 |
| `MM3_TIMEOUT_CYCLES` | 50000000 | 测试台及 CPU 每命令超时保护；周期计数为 64 位 |

768、2432、96、8 个 Q 头、4 个 KV 头、6400 词表是锁定模型维度，不是并行度。脚本检查这些值，不能只改头文件来改变已有权重。例：将 GEMM 改成 4×8，仅修改 `MM3_GEMM_ROWS`，重新生成配置后运行测试；若上下文改为 128，`MM3_GEMM_MAX_N/K` 也至少改为 128，重新评估片上缓冲与仿真资源。

生成的 `build/mm3-ops/config/config.json` 保存完整配置及头文件 SHA256；构建目录使用前 16 位摘要。当前默认摘要 `ac60559d357f5ce9`。代码变化由 Make/Verilator 重建；运行产物另有唯一目录，配置变化不会混用旧目录。

### 你来运行的入口

从仓库根目录执行，先保证完整 Verilator 安装的 driver 位于 PATH；`VERILATOR_ROOT` 必须指向与 driver 同版本的安装目录。仅有 `verilator_bin` 不够。RISC-V 默认从 PATH 找 `riscv64-unknown-elf-*`，也可用 `RISCV_TOOL_ROOT` 指向工具 bin 目录；`HOST_CC`、`VERILATOR`、`JOBS` 可覆盖工具和内部编译并行度。

```sh
# 只生成配置/ROM；不会计算模型
make mm3-config
# 只做语法、编译、整数对象/ELF 审计和 RTL lint；不启动仿真
make mm3-static-check

# 以下才会计算数值或运行仿真，由你自行执行
make mm3-ref
make mm3-op-test OP=rmsnorm
make mm3-op-test OP=all
make mm3-attn-test
make mm3-layer-test
make mm3-layer-test TRACE=1 JOBS=4
make mm3-layer-soc XLEN=32 TRACE=1 JOBS=4
```

`OP=all` 依次运行 add、mul、rmsnorm、rope、softmax、swiglu、gemm、kv；旧 GEMV 单元入口仍为 `make mm3-accel-unit XLEN=32`。`JOBS` 控制 Verilator 编译，不把一个模型分解为并行仿真。

`mm3-ref` 先生成 Python 结果，再执行宿主 C，整数向量、尺度与 KV 的原始字节一致才继续。所有 RTL 入口也先做此预校验，公共准备失败会立即退出，不继续运行 RTL。`mm3-layer-soc` 在预校验夹具上启动真实 RISC-V 驱动，无需再做全模型 CRC 和分词。宿主只预装初始输入/权重、生成参考和收集结果；没有 DPI 数学或宿主推理替代 DUT。

默认单层链：输入 Norm → Q/K/V 三个 Linear → 每头 Q/K Norm → RoPE → KV 写入 → Attention → O Linear → 残差 → Norm → Gate/Up → 融合 SwiGLU → Down → 残差。最终比较 768 个 INT16、输出 `IScale`、新增 K/V 和逐头尺度。GEMM 小用例包含转置、输入行填充步长、UINT16 概率和非整除尾部；Softmax 含均匀/单点/不均匀；向量含全零、正负极值和尾部。BFM 含响应反压稳定性、忙时重启拒绝、DONE/ERROR 保持与清除、非法零长度和输出邻接填充检查。上述是**待执行用例范围**，不是通过结果。

运行目录和定位：

- 构建/夹具：`build/mm3-ops/<摘要>/`、`fixtures/<case>/`；首次数值参考需要现有 `c_runtime/assets/model_w8a16_int.bin` 和 `integer_manifest.json`，会检查完整 SHA/长度，不重新量化。
- 独立运行：`build/mm3-ops/<摘要>/runs/<UTC>-<PID>-<case>-<route>/`。保留初始 image、命令、比较区域、Python expected、C 日志/报告、实际输出、`simulation.log`、配置、提交和源码逐文件 SHA；CPU 路径另保留裸机 ELF。
- 默认比较结果：`actual.report.json`，严格一致才有 `PASS MM3_COMPARE`。测试台自己的 `PASS MM3_PROGRAM/MM3_LAYER_SOC` 仅表示程序/协议完成，必须同时检查比较器。
- `TRACE=1`：每命令完成后保存 `trace/op-NNN.bin`，与 `expected-op-NNN.bin` 对比，在报告中列出不一致命令；宿主 C 同时写入 `c-trace/op-NNN.bin` 作同样比较。即使算子覆盖写同一块 DDR，也在覆盖前取样。默认不保存这些中间快照。
- `fixture.json` 的 `norm_vs_legacy`：用相同输入比较新 NR 与旧平方根算法，记录恢复真实值后的最大绝对误差、RMSE；不要求旧算法逐位一致。C/新 Python/RTL 之间仍要求整数/尺度严格一致。该字段在你运行参考前没有实测值。
- 静态日志：`logs/mm3-ops/<摘要>/`；完成的测试另有 `logs/mm3-ops/latest-<case>-<route>-rv<宽度>` 链接。原有 `logs/mm3/` 与完整模型长回归入口保留，不自动调用。

### 首次实现阶段的静态检查和未验收项（历史记录）

本轮仅运行配置/常量生成、Python `py_compile`、Shell `bash -n`、C 编译、RTL lint 和 Verilator C++ 模型的**编译**，未执行生成的模型。实际工具为 Python 3.12.3、GCC 13.3.0、RISC-V GCC 13.2.0、Verilator 5.044（`v5.044-52-g7e7b6d7fb`）。

| 实际命令/检查 | 本轮结果 | 证据 |
|---|---|---|
| `make mm3-config` / 生成文件 `--check` | 完成 | `common/mm3_config_pkg.sv`、`common/mm3_tables_pkg.sv`、`operators/mm3_tables.h` |
| `make mm3-static-check`：Shell/Python 语法、宿主参考/驱动编译 | 通过，未运行参考 | `host-build.log`、`static-report.json` |
| RV32/RV64 裸机 ELF、整数算子对象编译及反汇编审计 | 通过，无浮点指令/软浮点调用，未执行 ELF | `cpu-rv*-build.log`、`operators-rv*.dump`、`*-unresolved.txt` |
| 新算子链与旧 GEMV 单元 RV32/RV64 lint | 通过 | `lint-program-rv*.log`、`lint-legacy-unit-rv*.log` |
| 真实 P1 SoC RV32/RV64，设备关闭/开启 lint 对照 | 新增结构警告 0；基线有 10 处结构警告，未消除 | `lint-soc-rv*-enable*.log`；检查 LATCH/MULTIDRIVEN/UNOPTFLAT/ALWCOMBORDER |
| RV32 独立链 Verilator `--cc` 及生成 C++ 编译 | 完成；只生成/编译库，未启动仿真 | `codegen-rv32.log`、`codegen-cxx-build.log` |
| C/Python 数值、RTL 功能、反压/错误用例、单层误差/周期 | **待你运行** | 下表预留 |
| 综合、布局布线、时序、面积、功耗、上板 | **未执行** | 没有结果，不继承 hn_lab 的验收结论 |

复现记录以 `logs/mm3-ops/<摘要>/static-report.json` 为准，包含检查时提交、工作区 dirty 状态、工具版本、配置、源码逐文件 SHA 和两个 ELF SHA。`git rev-parse HEAD` 可查看交付提交；报告在提交前生成时 `commit` 是基点，须同时使用其源码 SHA，不能误认为只检查了旧代码。整数参数本轮仅做文件校验：64,929,156 字节，SHA256 `48a892f78228d3b3f5d4a89f8cbeaa70e44384ee180fa493f53a7ba04e777b56`，源 revision `f92512d4cd6142fa9acc0d6022375049a8974bf6`。未导出或运行模型。

| 待用户执行 | 整数/尺度一致 | 新 Norm 相对旧版 max_abs / RMSE | 周期 | 日志/结论 |
|---|---|---|---|---|
| C / 独立 Python | 待运行 | 待运行 | — | 待填写 |
| RMSNorm / 其他单算子 | 待运行 | 待运行 | 待运行 | 待填写 |
| 长度 4 Attention | 待运行 | — | 待运行 | 待填写 |
| 单 Token 第 0 层独立 RTL 链 | 待运行 | 待运行 | 待运行 | 待填写 |
| RV32 真实 CPU＋驱动单层 | 待运行 | 待运行 | 待运行 | 待填写 |

当前版本没有新算子的数值通过证据，不能据此宣称精度、周期加速或时序满足目标。详细格式、算法和连接见 [SoC 算子设计](../../docs/understand/SOC_SYSTEM.md#整数算子扩展2026-10-27)。

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

数据流、完整 MMIO 表、状态机握手和 Cache 所有权见 [SoC 设计说明](../../docs/understand/SOC_SYSTEM.md)。

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
