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
