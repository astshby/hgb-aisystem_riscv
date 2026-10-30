# hgb-aisystem：all 联合仿真

本分支保存最新共享 Core/SoC、YOLO、MiniMind、分层 CoreMark、三套交互程序及唯一一份 RT-Thread。
`main` 为无 NPU 的 CoreMark 系统，`yolo` 与 `minimind` 分别保存各自硬件与程序；
本分支只做仿真，不生成第四套 FPGA 物理镜像。

`soc_all_system` 同时实例化两套加速器。YOLO 控制窗口为 `0x20000000–0x2000ffff`，
MiniMind 为 `0x20010000–0x20010fff`，PLIC 源 ID 分别为 8、9，原 1–7 号设备不变。
两核各有独立时钟、CDC 与同步释放复位。MiniMind DDR 主口和可选 HDMI 读取在现有第四主端前
按突发公平仲裁，读写 owner 独立，保持全局 AXI ID 宽度。下游反压期间保留归属，公共复位同时取消各端旧事务。

发布程序均保留：CoreMark 的 READY→P/V→原始64位周期/CRC→DONE/READY；
YOLO 的上传→整网推理→框和叠框图回传→1080p显示→READY；MiniMind 的常驻模型文本会话。
YOLO 与 MiniMind 的完整板端运行、Flash/TF 资产装载尚未验收。MiniMind 作者数学/RAM模块保持原样，
多写 RAM 综合问题仍待作者侧修复；本分支没有完整模型推理或布局布线的新成绩。


本轮 RV32/RV64 真 Core 小程序各通过两次复位启动、两核地址/PLIC claim/清除和 MiniMind GEMV，
每宽 MiniMind 实际发出 6 笔读、4 笔写。独立仲裁补测为 66 读/65 写，持续双 AR 公平 15 次、
双 AW 公平 16 次，并覆盖三种公共复位取消。双宽 soc-test 各 12 PASS、SoC/联合顶层 lint 通过；
VIDEO_ENABLE=1 的 RV32 lint 通过，未运行真实 MiniMind 与 HDMI 同时扫描。
软件/工具合并测试 213 PASS / 8 SKIP；跳过 7 项 MiniMind 实模型和 1 项 YOLO 实模型资产测试，
对应资产环境未设置，旧完整模型证据单独保留。没有新 RT-Thread 终端 RTL 或上板结果。

先设置 `RISCV_TOOL_ROOT` 为 RISC-V 工具链 bin。常用入口如下：

```bash
make all-system-lint XLEN=32
make all-system-lint XLEN=64
make all-system-test XLEN=32
make all-system-test XLEN=64
make soc-test XLEN=32
make soc-test XLEN=64
make yolo-demo-test
make minimind-demo-test
make coremark-board-test
make rt-thread-demo-test
make rt-thread-fetch
make rt-thread XLEN=32
```

`all-system-test` 使用真实 RV32/RV64 Core、两原始加速器及 AXI/CDC/PLIC，运行小程序检查独立地址、
完成/错误中断、MiniMind DDR GEMV、公共复位再启动；另测双主口突发、反压、归属和取消。
它不执行 YOLO/MiniMind 完整模型。`tb_soc_system` 保留原单应用回归，`soc_all_system` 是双核联合入口。

MiniMind 原单核驱动默认地址保持 `0x20000000`；本分支的联合程序须编译
`-DMM3_MMIO_BASE=0x20010000u`。`scripts/demo/build_minimind_board.sh` 已默认使用联合地址，
独立 `minimind` 发布分支仍使用原地址。RT-Thread 不参加裸机 CoreMark 测量。

当前无 NPU 已测物理结果来自 `b94580c`：Core/SYS/DDR-user/外设
90.6208/100.9082/124.1619/73.0004 MHz；新增双核、视频和后续 Core 修改不继承这套物理结果。
C9/C10 及 8线程、normal、fanout128/route90 与独立64/80对照入口保留为工具配置，
本分支没有启动 PDS。详细证据与待办见[项目介绍](docs/PROJECT_INTRO.md)、
[FPGA说明](docs/fpga/FPGA_ADAPTATION.md)和[系统结构](docs/understand/SOC_SYSTEM.md)。
