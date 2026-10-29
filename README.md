# hgb-aisystem：四域 RISC-V SoC

本分支保存无 NPU 的 Core/SoC、分层裸机 CoreMark 和独立 RT-Thread。
Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休；ROB16、int8/mem4、LQ4/SQ4、
forward3、Tournament1、RAS0、OOO0，正常 ALU/Load/DSP 为 8/10/10 级。
RV32 优先优化，RV64 验证功能，C 扩展尚未实现。

完整系统的 C6 目标为 Core/SYS/DDR-user/外设 = 100/100/125/60 MHz。
TCM 和 Cache 当前与 Core 同域，SYS 包含总线与 DMA。配置目标与综合、布线测量分别记录。
基线和 PDS 执行入口共同维护；选定策略为 8 线程、fanout128、布局双输出 LUT 合并关闭、
布线时序权重90，布局和布线均使用 normal 模式。每次运行前重新检查物理与提交内存余量。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示可执行入口：

```bash
make check XLEN=32
make check XLEN=64
SOFTWARE_OPT=O3 make score COREMARK_PLATFORM_OUT=build/score-O3 \
  COREMARK_PLATFORM_ARGS='--clocks main60 --iterations 64 --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2'
make rt-thread-fetch
make rt-thread XLEN=32
make coremark-board XLEN=32
make coremark-board-test
make rt-thread-demo XLEN=32
make rt-thread-demo-test
```

新裸机UART固件回车/P运行performance、V运行validation，返回64位周期/CRC后再次READY；
电脑用`scripts/coremark/host.py`接收计算。独立RT终端支持STATUS/PING/ECHO/DEMO，
不参加裸机CoreMark。CoreMark双宽真实SoC串口闭环已通过：P/V、CRLF单触发、64位回传、DONE/READY及PC解析。
2次迭代的短测formal=0，尚无正式十秒或板上成绩；新RT终端仍只有构建/软件测试。
正式交互固件的C6条件候选`b94580c`已完成唯一一次追加布局布线，
Core/SYS/DDR-user/外设Fmax为90.6208/100.9082/124.1619/73.0004 MHz，0未布通。
Core100与DDR125 MHz尚未收敛，本轮停止迭代、不自动升级baseline；旧自动固件的物理记录保留。
双宽回归368 PASS/8 SKIP，固定64轮三层与双宽UART的周期均不变。

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共配置见
`scripts/hardware_profile.json`，当前应用范围见 `scripts/branch_profile.json`。
本次基线测量显式选择 I$16 KiB、D$8 KiB、bank XOR mask2；通用 API 的4/4 KiB默认值保留历史兼容。
O3/64轮已测 M0 performance/validation 为3.590617/3.570731 CoreMark/MHz；
真实 TCM 为3.095736/3.081770。两者的存储路径分别记录。
M0 使用 TB 一周期存储；`core_tcm`、`soc_tcm`、`soc_ddr` 分别测真实 Core+TCM、
SoC+TCM、SoC+Cache+DDR。CoreMark/MHz 的分母均为 Core 计时区周期。
RT-Thread 为独立应用，不参加这组 CoreMark 测量；程序主体在 DDR，热 trap 驻 ITCM。
短仿真和64轮仿真均须另核对实际计时时间，满十秒后才满足正式 CoreMark 时间要求。

YOLO 保存在 `baseline-yolo`，MiniMind 保存在 `baseline-minimind`；
`baseline-all` 保存两套加速器和全部软件，仅用于联合仿真。
完整YOLO演示的本地交付为`demo/yolo-full-network@8a8f484`：同C程序与真实NPU/总线/UART/显示RTL联合仿真通过，
另有真实RV32/RV64驱动短测；尚未推送合并到上述发布分支，没有板测结果。
本分支不保留加速器实体源码、专属软件或专属执行入口。

详细配置、数据和待办见[项目介绍](docs/PROJECT_INTRO.md)、
[系统结构](docs/understand/SOC_SYSTEM.md)、[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。
工作区 `2-coremark/record.md` 保存各次镜像、命令和测量记录。
