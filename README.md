# hgb-aisystem：YOLO 演示分支

当前GitHub可获取基线为`yolo@3780a75`。本分析分支为`diag/yolo-startup-review-20261101`，
用于核对合并时间线和完整SoC启动问题；原报告的c3905ae/b504824诊断代码尚未上传。
分支关系和具体定位顺序见[上板状态与源码核对](docs/fpga/YOLO_BRINGUP_STATUS.md)。


克隆本分支：`git clone --branch yolo https://github.com/astshby/hgb-aisystem_riscv.git`。
程序、模型和测试集均有版本库入口，见[软件复现说明](software/README.md)和[YOLO 命令](software/yolo/README.md)。
设置工具链并安装固定 Python 依赖后，执行 `make software-prepare`、
`make software-build XLEN=both`、`make software-test`，无需旧 build 或 YOLO-accelerate 工作目录。


本分支保存共享 Core/SoC、128-MAC YOLO NPU、UART 图片服务和 1080p HDMI 显示。
分层 CoreMark 在 `main`，RT-Thread 在 `all`；本分支没有这两套应用代码或执行入口。
模型名称为 MiniMind，它的独立发布分支为 `minimind`。

Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4；
正常 ALU/Load/DSP 为 8/10/10 级。当前共享 Core 与 `main` 的 `82cbf7a` 逐文件一致，
包含 CMP 载荷写使能分离、操作数捕获预览；四路 Store hint 默认保留。
I$/D$ 本轮明确使用 16/8 KiB、bank XOR mask2，ITCM/DTCM 各 64 KiB。

当前时钟档为 **C10 `yolo_sys`**：Core/SYS/DDR-user/外设/NPU =
**83.806818 / 102.430556 / 125 / 65.848214 / 92.1875 MHz**，视频为独立 **148.5 MHz**。
系统GPLL使用125 MHz输入、I/M/F=8/1/59、921.875 MHz VCO，输出分频11/9/14/10。
旧C1–C8继续保留。本轮完整程序＋HDMI P&R正常完成，Core/SYS/DDR-user/外设/NPU/视频Fmax为
85.9387/108.0885/132.6612/72.8046/95.5526/162.8928 MHz，六域达到C10工作档、0未布通。
slow/fast全部内部setup/hold、恢复、MPW、CDC/Gray及DDR PHY无失败；PHY最小setup+0.045 ns。
实际工作频率仍为上述PLL配置，板级I/O有36输入/103输出通用delay提示，尚无bitstream或板测。

设置 `RISCV_TOOL_ROOT` 为交叉编译器bin目录，`PDS_HOME`/`PDS_WORK_ROOT`为工具和原生工程目录。
完整固件入口默认O3、HDMI=1、115200波特率，RV64默认从随库保存的GCC/Newlib源码
构建纯RV64IM数学库；无需本机工具链源码树。`YOLO_SOFTMATH_ARCHIVE`可显式指定已核验的库。
历史C10构建使用的库SHA256为
`819a14079182697a3ea1331886c5dc66239393ba215fe91a370c7a6059c8d467`。

```bash
make yolo-demo-test
make yolo-demo-build XLEN=32 YOLO_OUT=build/yolo-board-rv32
make yolo-demo-build XLEN=64 YOLO_OUT=build/yolo-board-rv64
python3 scripts/yolo/firmware.py verify --output build/yolo-board-rv32
make yolo XLEN=32
make yolo-driver-test XLEN=32
make yolo-video-test XLEN=32
```

固件保留真实名称`program.elf`，`manifest.json`记录27份源文件、完整应用角色、配置、固件ID及ELF/HEX哈希。
ID字符串随DTCM初始化，原串口协议不变。生产程序已包含模型装载、83层卷积图调度、非卷积算子、
解码/NMS、回传图像和视频提交；复位后发READY，每轮上传/DETECT完成后返回结果并再次READY。
PC入口为`scripts/yolo/host.py --port COM5 status|model|upload|detect|read|selftest`。

当前发布输入源码为`45de647`，两宽生产镜像ID分别为`6aff928ff969d57d`、`adcd70b68d805fcf`，
均通过源码、ISA、ELF/HEX和TCM初始化核验。新C10真实RV32驱动通过3个卷积、171个输出及5个量化值；
新SYS/外设频率下的AXIL32视频完整帧、A/B切换、反压、欠载恢复和I2C通过。
RV64新档driver/video复测留给后续调试；本轮没有重复数小时整网。

此前同C程序＋真实NPU/总线/UART/视频RTL的320整网联合仿真已通过83 Conv、5775300个INT32、3个框，
实际UART收图/回图、1080p扫描后回READY；C图调度在电脑执行，DDR为行为模型。
完整RV32板端整网、Flash启动与板上HDMI仍待验证，当前没有FPGA实物FPS。

完整生产PDS输入使用：

```bash
python3 scripts/pango/prepare_yolo_application.py \
  --firmware-dir build/yolo-board-rv32 --xlen 32 --synthesis-strategy timing-v2 \
  --ip-dir "$PDS_WORK_ROOT/work/clocks-c5-yolo-20261029/ddr-ip/candidate/ddr3_test" \
  --output "$PDS_WORK_ROOT/work/yolo-full-c10-new"
python3 scripts/pango/prepare_yolo_application.py \
  --verify --output "$PDS_WORK_ROOT/work/yolo-full-c10-new"
```

每次选新输出目录。此入口固定NPU＋HDMI、C10、I16/D8/hash2、真实交互固件，
不把旧卷积小程序改名为loader。timing-v2使用8线程、fanout64、retiming开启、算术共享关闭、
normal布局/布线、LUT合并关闭、route权重80；新工程尚需综合、原生CDC绑定和完整物理验收。
RCF补充已通过74项纯工具测试：新工程冻结生成IP的pnr/ddr3_test.rcf并加载board_ddr.rcf。
离线输入在$PDS_WORK_ROOT/work/release-ab-20261030/yolo-c10-rcf-inputs，
原有RTL、固件、时钟、策略逐项一致，compile仅增加RCF加载，未重新运行综合或布线。
本轮原始物理工程未加载RCF，结果与修正入口分开；后续原生网名、加载和性能比较交A。
具体原生执行命令、输入身份和失败路径处理见[FPGA适配](docs/fpga/FPGA_ADAPTATION.md)，
程序证据与缺口见[项目介绍](docs/PROJECT_INTRO.md)。
