# FPGA 适配与综合

## 配置与入口

Windows PDS 2025.2 ADS，器件 PG2L200H-6IFBB676，HMIC_S 1.10 DDR3 IP。
生成 IP 和原生工程使用 `$PDS_WORK_ROOT` 的新目录；`reference` 只读。
`PDS_HOME` 指向 Windows 工具安装。Linux Verilator 通过不代表板上通过。

Core 为 ROB16/int8/mem4、RAS0、OOO0、Tournament1、forward3、MUL0/DIV1。
C1 目标 Core/SYS/DDR-user/外设 = 100/80/125/25 MHz。
`pango_soc_pll` 为功能域生成时钟，DDR 用户时钟来自 DDR IP；选定加速器使用额外 100 MHz 输出。

`prepare_project.py --core-backend scoreboard --board-clock-profile 1` 暂存无加速器板级工程；
加 `--npu-enable` 或 `--mm3-enable` 选择对应加速器。两标志互斥，分支未保留的设备不能选择。
加速器专用分支从 `branch_profile.json` 读取默认设备，all 默认无设备。
默认入口已选择 scoreboard/C1；显式 legacy 使用原共同时钟，仍可显式覆盖时钟档。
四分支各 64 项 PDS 工具测试通过。暂存前需 `make loader XLEN=32` 与完整生成 DDR IP 目录。

标准综合使用 ADS `synthesize -ads -selected_syn_tool_opt 2`，单线程，增加路径报告深度；
不启用快速布局布线，本轮不执行 P&R。每个工程保留编译 Tcl、FDC、镜像、源码哈希和原始报告。

## 2026-10-27 标准综合状态

五域目标 Core/SYS/DDR-user/外设/NPU 为 100/80/125/25/100 MHz。
本次原生 PDS 在 RTL/RAM 推断阶段运行约 59 分钟，尚未生成完整资源和 Fmax 报告。
维护者选择先交付其他四组，将 MiniMind 记为待修；已仅停止本次 PDS 父子进程，保留工程和日志。

PDS Sdm-2010 指出 14 个加速器数组不支持同周期多写 RAM，包括 GEMV 的 x/row_m/row_e、
ops engine 的 abuf/asbuf/auxbuf/bbuf/bsbuf/desc/kbuf/ksbuf/vbuf/vsbuf 和 softmax 的 order。
这表明当前写法未得到相应 RAM 推断；尚无最终映射报告，不能填写 LUT/FF/DRM/APM 或推算 Fmax。
小型 rd_busy_q/wr_busy_q 控制寄存数组的同类警告另列，不能混作大容量 RAM 问题。

本次五域接口、双宽单层 38 命令、运行库与并发 DMA 仿真通过。100 MHz 是 NPU 目标，不是已测频率。
原生输入为 99c2890、O3 UART loader，模型从 DDR 读取；目录为
`$PDS_WORK_ROOT/work/four-branches-20261027/soc_minimind/`。
`user-stop.json` 记录停止原因，`native-synthesis.stdout.log` 保留推断警告。
本地摘要为 `logs/four-branches-20261027/minimind-synthesis-status.json`。

下一步在独立分支处理存储 bank、写端口、地址宽度和同步读边界，保持原算法、模型维度与参考输出，
重跑算子/单层/双宽系统验证后再做标准综合。没有 P&R、bitstream 或板级结果。

## 结果解释

Fmax 是对应域内路径的综合估计，不等于已上板频率。WNS、资源、最差路径、跨域报告分别呈现。
没有运行布线时，routed Fmax/WNS/unrouted nets 记为未测，不能写零未布通。
各层同一 Core 的综合值会因 TCM、总线和其他模块的实际扇入/扇出变化而不同。

2026-10-26 历史 Core+TCM 为 104.712 MHz、26400 LUT/19663 FF/32 DRM/4 APM；
同日完整 YOLO 系统 Core/SYS/DDR-user/外设/NPU 为
89.3096/83.8926/144.6969/89.0076/112.3343 MHz，71659 LUT/66825 FF/162.5 DRM/86 APM。
这两组属于旧源码/镜像；日志曾被维护者清理，本轮新结果单独保留在
`$PDS_WORK_ROOT/work/four-branches-20261027/`，不能继承旧结果当作新验收。

旧 P0 有约 85 MHz 标准布线结果，后续源变化不自动继承。新 SoC 的 CDC payload/Gray
端点绑定、skew、DDR PHY/I/O 和板上启动仍需后续验收。不能用 false path 隐藏真实同步路径，
也不能修改约束数字来宣称时序闭合。

## 内存与启动

每阶段开跑前至少 6 GiB 物理与提交余量。WSL 的可回收文件缓存也可能占 Windows 提交预算。
本轮只对自己生成且闲置的构建文件使用 POSIX_FADV_DONTNEED，保留文件和日志；
随后再次查询 Windows 计数。未修改 pagefile、未终止无关进程。
综合结束/错误后记录结果，运行期间约十分钟查看一次即可。

bitstream 可包含 ROM/TCM 初值；配置 Flash 先恢复 FPGA 逻辑，CPU 才从 ROM 启动。
板上 DDR 初始化、软件搬运、Cache 维护和 UART 时基必须按实际域频率工作。
Flash 物理管脚接入与完整冷启动尚待板级验证。RT-Thread 仿真预装 DDR，
加速器仿真使用预装模型/输入；这些不等于 Flash 到 DDR 的完整上板流程已完成。
