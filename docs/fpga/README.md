# FPGA 适配

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。详细流程、结果和边界见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。

当前基线为 `baseline-rv32-soc-20261025`，Core 采用 RAS0、OOO0、ROB32、int8/mem4、
forward3、Tournament1，正常流水为 8/10/10。Core+TCM、片上 SoC、完整 DDR3 SoC
三组已完成标准综合，Core 估计分别为 96.8523/91.7600/84.4523 MHz；资源及详细
双模式成绩见[项目介绍](../PROJECT_INTRO.md)。三组均未布局布线，未上板。
后续先完成当前网表的 CDC 绑定和时序检查，再标准 place/route/route_optimize；
每个原生阶段入口的 Windows 物理可用和提交余量各至少 6 GiB。

以下为 2026-10-23 的历史 S4 诊断记录，从 `soc/p2-p3-clock-study@e088a9d` 新建
`fpga/s4-layered-characterization`。RV32 固定 P1 Core：双发射、ROB32、int8/mem4、
有限整数乱序、forward3、Tournament/RAS、DSP/SRT4，ALU/Load/DSP 为8/10/10级。
RV64只做功能仿真。当前集成树的≥85MHz还没有标准布局布线结果。
七组RV32分层综合已完成并核对输入/报告哈希；测量代码为 `eacef6a`，
Flash等价索引兼容修正为 `3f7402a`。双宽测量壳8项、修正后Flash定向/时钟4项、
整机Flash/DMA 2项及工具113项均PASS/0 SKIP；本轮CoreMark未重跑。

- H0测Core，H1测Core+TCM/Cache，H2测四域软SoC至DDR AXI；三者使用独立扫描输入保持/输出快照壳。
- 真实PLL、DDR控制器/PHY和管脚为H3板级整机，单列验收。H0/H1/H2没有板级时钟实现证明。
- 物理工具仍用Windows PDS 2025.2，工程、网表和原始报告置于`$PDS_WORK_ROOT/work/`新目录。
- Core综合最差集中在RAS恢复；SYS在C1为复位释放扇出，在C4为B响应选择/仲裁；DDR组受扫描壳影响。fill8尚无频率不回退证据，默认fill4保持。
- 原生对象绑定未完成，全部内部路径仍正常计时。新PLL/DDR/IO及真实布线分别验收。
- H0标准实现候选已准备；19:29提交余量13.616GiB，尚未启动place。建议入口46GiB提交/6GiB物理余量，阶段内双6GiB；不改分页或结束无关进程。
- 只用标准place、route和route_optimize。估算时序与布线后Fmax分别记录，历史P0/P1.1a结果不代替当前树。
- 2026-10-23 增加C1/C4物理暂存（schema 9）；`board_clocks.fdc`只生成GPLL时钟和不确定性，不加载CDC例外、I/O delay或false path。C1综合PASS：76,298 LUT、61,092寄存器、36 DRM、4 APM、0 latch；估计Core 36.5150MHz（RAS恢复45级），SYS 84.1326MHz。PLL站点、DDR IP共存、place/route/bitstream和烧板仍未完成。

新增入口为 `scripts/pango/prepare_measurement.py`，旧 `prepare_project.py` 的
schema8仍只对应板级profile0。新测量结果和精确命令集中在工作区三个交接文档
及其本地日志索引。没有生成bitstream、烧板或十秒CoreMark验收。
