# hgb-aisystem：RISC-V 双发射 SoC 与 YOLO 加速平台

## 分支获取与启动回归

一次完整 `git clone` 会取回 main、yolo、minimind、all 的远端分支；默认只检出一个。
`git branch -a` 查看全部分支，`git switch yolo` 切换到本应用。首次从唯一的
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


本仓库是一套可综合、可布局布线的 RISC-V SoC 工程：自研双发射乱序执行核心、
TCM/Cache/DMA/AXI 总线系统、128-MAC YOLO 卷积加速器、1080p HDMI 显示链路，
以及配套的裸机固件、上位机工具与 PDS 物理实现流程。

FPGA 适配已完成：Pango PDS 2025.2 的综合、布局、布线、时序分析与位流生成全部跑通，
[Windows 下的 PDS 适配](#windows-下的-pds-适配)。

## 系统组成

| 部分   | 说明                                                                                           |
| ------ | ---------------------------------------------------------------------------------------------- |
| Core   | RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4；ALU/Load/DSP 8/10/10 级     |
| SoC    | ITCM/DTCM 各 64 KiB、I$ 16 KiB、D$ 8 KiB（bank XOR mask2）、AXI 互连、DMA、MMIO、跨时钟域 FIFO |
| 加速器 | 128-MAC INT8 卷积阵列，完整 YOLOX-tiny 网络调度（83 层卷积 + 非卷积算子 + 解码/NMS）           |
| 显示   | AXIL 视频通道，1080p HDMI 输出，独立 148.5 MHz 时钟域                                          |
| 存储   | DDR3，用户时钟 125 MHz，由 DDR IP 提供；TCM/Cache 与 Core 同域                                 |

## 时序与资源结果

完整 YOLO + HDMI 工程在 C10 档（Core/SYS/DDR-user/外设/NPU/视频 =
83.806818 / 102.430556 / 125 / 65.848214 / 92.1875 / 148.5 MHz）的实测：

| 时钟域        |         Fmax |
| ------------- | -----------: |
| clk_core      |  85.9387 MHz |
| clk_sys       | 108.0885 MHz |
| ddrphy_sysclk | 132.6612 MHz |
| clk_periph    |  72.8046 MHz |
| clk_npu       |  95.5526 MHz |
| clk_video     | 162.8928 MHz |

六域 WNS 均为正，slow/fast 全部内部 setup/hold、恢复、MPW、CDC/Gray 与 DDR PHY 检查通过，
布线全部完成。资源占用：LUT 94,202、FF 73,263、DRM 169 格、APM 86 单元。

## 仓库结构

```
vsrc/core/     Core：取指、译码、发射、执行、访存、退休
vsrc/soc/      SoC：TCM/Cache、AXI、DMA、MMIO、NPU、视频、DDR 适配
vsrc/cpu/      FPGA 顶层、PLL、DDR/视频桥、启动观测
third_party/   YOLO NPU RTL
tb/            单元、核心、riscv-tests 适配与 PDS 工具测试
software/      裸机固件、YOLO 应用、上位机串口工具
scripts/       仿真、PDS、固件与测试入口
docs/          项目介绍、学习总结与 FPGA 适配说明
```

## 分支

| 分支       | 内容                                        |
| ---------- | ------------------------------------------- |
| `main`     | 无加速器的四域 SoC、分层 CoreMark           |
| `yolo`     | 本分支：YOLO NPU、UART 图片服务、1080p HDMI |
| `minimind` | MiniMind 原作者程序与整数模型               |
| `all`      | 上述应用与一份独立 RT-Thread 应用           |

## 软件与固件

固件源码、模型与测试集均随仓库提交；`build/` 只保存编译产物，删除后可重新生成。
仓库内置示例图片与模型：`tb/assets/yolo/`（`dog.jpg`、`dog-192x144/320/416.rgb`、
`black-16x16/320/416.rgb`）与 `software/yolo/assets/`（`yolox-tiny-320.bin`、
`yolox-tiny-416.bin`、权重哈希与模型锁文件）。

```bash
make software-list
make yolo-demo-build XLEN=32 YOLO_OUT=build/yolo-board-rv32
make yolo-demo-test
python3 scripts/yolo/firmware.py verify --output build/yolo-board-rv32
```

生产固件保留真实名称 `program.elf`，`manifest.json` 记录源文件、配置、固件 ID 与
ELF/HEX/TCM 哈希。RV32/RV64 发布镜像 ID 分别为 `6aff928ff969d57d`、`adcd70b68d805fcf`。
上位机入口为 `scripts/yolo/host.py --port <串口> status|model|upload|detect|read|selftest`。
详细说明见[软件复现](software/README.md)与[YOLO 命令](software/yolo/README.md)。

## 环境要求

| 用途       | 版本与说明                                                                     |
| ---------- | ------------------------------------------------------------------------------ |
| 操作系统   | Windows 11（PDS 仅 Windows 本地运行）+ WSL2 Ubuntu 22.04（固件与 Python 工具） |
| 仿真器     | Verilator 5.052                                                                |
| 交叉工具链 | GCC 16.1.0，需支持 `rv32im_zicsr`/`ilp32` 与 `rv64im_zicsr`/`lp64`             |
| 物理实现   | Pango PDS 2025.2 ADS                                                           |
| 器件       | PG2L200H-6IFBB676                                                              |
| 脚本环境   | Python 3.10 及以上、Git、Make、C/C++ 编译器                                    |
| 内存       | 每个 PDS 阶段启动前 Windows 可用物理内存与可用提交内存均不少于 6 GiB           |

外部路径统一由环境变量给出：`RISCV_TOOL_ROOT`（交叉编译器 bin）、`PDS_HOME`（PDS 安装目录）、
`PDS_WORK_ROOT`（原生工程根目录）、`RTTHREAD_ROOT`（仅在 `all` 分支使用）、
`COREMARK_REPLAY_DIR`（仅在基准复现时使用）。

## Windows 下的 PDS 适配

PDS 只在 Windows 本地运行；固件与 Python 工具可在 WSL/Linux 完成。所有路径由环境变量给出，
不使用固定盘符或用户目录。

1. 设置环境变量：`PDS_HOME` 指向 PDS 安装目录，`PDS_WORK_ROOT` 指向原生工程根目录
   （每次运行在其下新建一个目录），`RISCV_TOOL_ROOT` 指向交叉编译器 bin。
2. 生成 DDR IP：`powershell -File scripts/pango/generate_ddr_ip.ps1`，产物目录作为
   后续 `--ip-dir`。
3. 构建固件：`make yolo-demo-build XLEN=32 YOLO_OUT=build/yolo-board-rv32`，
   `--firmware-dir` 指向该输出目录。
4. 暂存原生工程（输出目录必须为空）：

   ```powershell
   python scripts/pango/prepare_project.py --output "$env:PDS_WORK_ROOT\work\<run>" `
     --ip-dir <生成IP目录> --firmware-dir build\yolo-board-rv32 `
     --firmware-role yolo-interactive --xlen 32 --synthesis-strategy timing-v2 `
     --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2 `
     --soc-profile full --core-backend scoreboard --retire-entries 16 `
     --split-issue-queue 1 --limited-integer-ooo 0 --scheduler-forward-mode 3 `
     --integer-queue-entries 8 --memory-queue-entries 4 --predictor-mode 1 --ras-enable 0 `
     --board-clock-profile 10 --npu-enable --video-enable 1
   ```

5. 综合：`powershell -File scripts/pango/run_phase.ps1 -Project <run>.pds
   -LogDirectory <run>\logs -Phase synthesis -PdsHome $env:PDS_HOME`。
6. 原生 CDC 审计与绑定：按 [FPGA 适配](docs/fpga/FPGA_ADAPTATION.md) 中的
   `prepare_cdc_audit.py` / `query_cdc.tcl` 流程生成 `cdc-scope-receipt.json`。
7. 实现：`-Phase implementation -ImplementationScript implement_cdc.tcl`，
   阶段顺序为 dev_map → place → route → route_optimize → report_timing。
8. 生成位流：该步骤已随工程暂存为 `gen_bitstream.tcl`；设置 `HGB_PDS_PROJECT`
   指向工程 `.pds` 后由 `pds_shell -file gen_bitstream.tcl` 执行，产物写入同一运行目录。

每个阶段启动前都检查 Windows 可用物理内存与可用提交内存均不少于 6 GiB；不足时先释放内存，
不要降低门限。完整命令、输入哈希与日志位置见 [FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。

## 测试

```bash
make test XLEN=32
make test XLEN=64
make riscv-tests XLEN=32
make riscv-tests XLEN=64
make benchmark-smoke XLEN=32
make coremark XLEN=32
```

`make test` 不含 riscv-tests 与基准测试。测试台声明 `timeunit 1ns`、`timeprecision 1ps`，
使用确定性的时钟沿激励并打印 `PASS`。

## 文档

| 文档                                                                 | 内容                                     |
| -------------------------------------------------------------------- | ---------------------------------------- |
| [docs/PROJECT_INTRO.md](docs/PROJECT_INTRO.md)                       | 目录、参数、环境、仿真与 FPGA 测量       |
| [docs/understand/](docs/understand/README.md)                        | SoC、双发射、DDR/AXI、FPGA、优化五份总结 |
| [docs/fpga/FPGA_ADAPTATION.md](docs/fpga/FPGA_ADAPTATION.md)         | PDS 流程、约束、时序与资源结果           |

