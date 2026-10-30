# hgb-aisystem：四域 RISC-V SoC

本分支保存无 NPU 的 Core/SoC、公共仿真、分层裸机 CoreMark 和上板串口交互程序。
首次获取使用 `git clone --branch main https://github.com/astshby/hgb-aisystem_riscv.git`。
程序源码、依赖准备和可执行命令见[软件复现说明](software/README.md)。
设置 `RISCV_TOOL_ROOT` 后依次运行 `make software-doctor`、`make software-prepare`、
`make software-build XLEN=both`、`make software-test`；这些入口不需要历史 `build`。
RT-Thread 的源码、构建入口和专用测试保存在 `all`。
Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休；ROB16、int8/mem4、LQ4/SQ4、
forward3、Tournament1、RAS0、OOO0，正常 ALU/Load/DSP 为 8/10/10 级。
RV32 优先优化，RV64 验证功能，C 扩展尚未实现。

当前运行候选为 C9 `main_margin2`：Core/SYS/DDR-user/外设 =
88.75 / 98.611111 / 125 / 68.269231 MHz。系统 GPLL 的 VCO 为887.5 MHz，
输入分频/倍频/反馈分频为10/1/71，输出分频为10/9/13；DDR用户钟由DDR IP提供。
原C6的100 MHz Core目标和实测报告继续保留，新档需要重新验证物理时序。
TCM 和 Cache 当前与 Core 同域，SYS 包含总线与 DMA。配置目标与综合、布线测量分别记录。
基线和 PDS 执行入口共同维护；本轮选定 timing-v2：8线程、fanout64、retiming开启、
算术资源共享关闭、布局双输出LUT合并关闭、布线时序权重80，normal布局/布线、
GP/route recovery和route_optimize开启。原timing-v3的128/90保留。
每次运行前重新检查Windows物理与提交内存余量均至少6 GiB。

设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin。`make help` 显示可执行入口：

```bash
make check XLEN=32
make check XLEN=64
SOFTWARE_OPT=O3 make score COREMARK_PLATFORM_OUT=build/score-O3 \
  COREMARK_PLATFORM_ARGS='--clocks main_margin2 --iterations 64 --jobs 1 --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2'
make coremark-board XLEN=32
make coremark-board-test
```

新裸机UART固件回车/P运行performance、V运行validation，返回64位周期/CRC后再次READY；
电脑用`scripts/coremark/host.py`接收计算。CoreMark双宽真实SoC串口闭环已通过：P/V、CRLF单触发、64位回传、DONE/READY及PC解析。
2次迭代的短测formal=0，尚无正式十秒或板上成绩；RT终端的历史结果见`all`。
C9完整交互固件使用`build/coremark-board/rv32-O3-i0-b115200`，生产ID为`ea1773fca42aa7c6`。
硬件`82cbf7a`的综合估计Core/SYS/DDR-user/外设为83.5307/110.0987/144.7387/93.3476 MHz；
综合阶段Core低于所选88.75 MHz；随后完整布线得到Core/SYS/DDR-user/外设
90.3702/107.5410/131.9784/78.5252 MHz，C9四工作域setup通过、0未布通。
DDR PHY仍有1端点setup−0.028 ns，I/O缺35输入/73输出delay，整机尚未全部闭合，Core100 MHz也未达到。
旧C6 `b94580c`物理Fmax为
90.6208/100.9082/124.1619/73.0004 MHz、0未布通，保留为历史记录。
新旧时钟、策略和RTL均有差异，频率差额不能归因单项修改。
后续工具修复已补DDR生成RCF的暂存/加载/哈希，并提供I/O分类，115项工具测试通过。
上述物理原件未加载RCF，修正后的输入尚未重新运行PDS；PHY和I/O后续比较交B，本机不追加运行。
本轮双宽公共回归合计368 PASS/8 SKIP，786项源SHA起终相同；20项定向验证不重复计入。
两个可选SoC短测延期，未计入SKIP；新C9分层CoreMark与UART复测交B。

软件默认 `SOFTWARE_OPT=O3`，可选 O2/Ofast。公共配置见
`scripts/hardware_profile.json`，当前应用范围见 `scripts/branch_profile.json`。
本次基线测量显式选择 I$16 KiB、D$8 KiB、bank XOR mask2；通用 API 的4/4 KiB默认值保留历史兼容。
O3/64轮M0 performance/validation：RV32为3.590617/3.570731，RV64为3.145656/3.133377 CoreMark/MHz。
真实TCM的旧C6成绩为3.095736/3.081770。B需从当前P2源重建并冻结C9软件bundle；
旧ELF拒绝C9/C10，不能直接沿用旧档分数。两种存储路径分别记录。
M0 使用 TB 一周期存储；`core_tcm`、`soc_tcm`、`soc_ddr` 分别测真实 Core+TCM、
SoC+TCM、SoC+Cache+DDR。CoreMark/MHz 的分母均为 Core 计时区周期。
RT-Thread已移到`all`，不参加这组CoreMark测量。
短仿真和64轮仿真均须另核对实际计时时间，满十秒后才满足正式 CoreMark 时间要求。

发布分支按`main / yolo / minimind / all`整理。YOLO和MiniMind分别保留对应上板程序；
`all`保存两套加速器、全部软件与RT-Thread，仅用于联合仿真。历史`baseline-*`提交保留。
YOLO用途分支已集成`demo/yolo-full-network@8a8f484`的完整程序：同C程序与真实NPU/总线/UART/显示RTL联合仿真通过，
另有真实RV32/RV64驱动短测。C10整网复测与上板由A负责，没有板测结果。
本分支不保留加速器实体源码、专属软件或专属执行入口。

详细配置、数据和待办见[项目介绍](docs/PROJECT_INTRO.md)、
[系统结构](docs/understand/SOC_SYSTEM.md)、[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。
本地工作区[record.md](../record.md)保存各次镜像、命令和测量记录。
