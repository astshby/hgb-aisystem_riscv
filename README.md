# hgb-aisystem：MiniMind

## 分支获取与启动回归

一次完整 `git clone` 会取回 main、yolo、minimind、all 的远端分支；默认只检出一个。
`git branch -a` 查看全部分支，`git switch minimind` 切换到本应用。首次从唯一的
origin 同名分支切换时，Git 会建立本地跟踪分支；不要使用 `--single-branch` 限制获取范围。

```bash
make boot-count-test XLEN=32
make boot-count-test XLEN=64
python3 -m unittest tb.scripts.test_scoreboard_runner
```

继承 main PR #33 的修复：显式检查 FIFO 深度 2/4/8、ROM→ITCM、ISS 双出双入、
整数/访存 IQ、恢复与退休；每宽度九个用例。修正 PASS 后仍有致命错误时的判定、
三处 SKIP 输出，以及独立 SoC 启动脚本在空构建目录中的输出目录创建。
编译使用单线程，`logs/boot-count/` 保存命令与源/日志哈希。
独立启动可通过 `P2_LOG_ROOT` 和 `P2_BUILD_ROOT` 分离日志和模型，避免不同分支互相覆盖。

这组测试覆盖公共 Core/SoC 启动；本分支的专属程序、NPU 和模型验证使用下方原有入口。
生产 RTL、原固件、模型及默认时钟保持本分支配置。后续 hgb 偶尔继续紫光适配，
rhbyv 独立推进 Zynq-7020，逐项吸收已验证经验。


克隆：`git clone --branch minimind https://github.com/astshby/hgb-aisystem_riscv.git`。
程序与锁定整数模型随 Git 保存，见[软件复现说明](software/README.md)。设置工具链与 Python 依赖后，
依次执行 `make software-prepare`、`make software-build XLEN=both`、`make software-test`。
原 FP32 权重恢复和重新导出命令为 `make minimind-assets-rebuild`，不需要旧 build。


MiniMind 整数算子、原作者软件与五域 SoC，无 CoreMark/RT-Thread。Core 使用 ROB16、int8/mem4、LQ4/SQ4、forward3、Tournament1、RAS0、OOO0。
RV32 优先优化，RV64 验证功能。正常 ALU/Load/DSP 为 8/10/10 级，C 扩展尚未实现。

Core/SYS/DDR-user/外设目标为 100/80/125/25 MHz。所选加速器另用独立 100 MHz 域。
这些是配置目标，综合估计另列，本轮没有布局布线或上板结果。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示本分支入口：

```bash
make check XLEN=32
make check XLEN=64
make minimind XLEN=32
make minimind XLEN=64
```

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共 Core/SoC 配置在
`scripts/hardware_profile.json`，分支功能在 `scripts/branch_profile.json`。

CPU 经 0x20000000 配置算子；NPU 独立 AXI 主口读写共享 DDR，系统 DMA 可并行运行。
双宽 38 命令单层与参考一致，运行库 CPU/加速器对照及 32 KiB DMA 并发通过。
RTL 尚未完成全八层、多 Token 和语言质量测试；先按软件 README 恢复锁定模型。

常驻交互软件位于 `software/minimind3/demo/`，保留原作者 C 入口。
原生整数程序完成真实八层推理、连续两轮请求及原作者输出对照，软件测试 12 PASS / 0 SKIP；
RV32/RV64 的真实 UART 与原加速器驱动固件编译通过。每轮重置 pos/KV，结束后返回 READY。
这部分没有运行 RTL、上板或语言质量测试。TF 驱动和大模型 UART 装载尚未实现；
现有 HGB1 的 DDR 窗口只有 `0x80000000–0x80020000`，不能装载约 64 MB 模型。
新资产头用于校验预装 DDR 数据，模型、tokenizer 与固件数据仍需后续装载通路。
软件命令见[项目介绍](docs/PROJECT_INTRO.md#minimind-常驻交互软件)。

说明见[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)、
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。全部源码与可选应用集中保存在 all；
本分支只保留上述应用。历史分支已保存为本地 archive 标签，详细变更用 git log/git show 查询。

MiniMind 的五域仿真通过；本次 PDS 出现多写 RAM 推断警告，约 59 分钟后按维护者决定停止。
资源与 Fmax 尚未取得，独立域 100 MHz 为目标。存储 bank/写端口/同步读结构列为待修，
详见 [FPGA 状态](docs/fpga/FPGA_ADAPTATION.md#2026-10-27-标准综合状态)。
