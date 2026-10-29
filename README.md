# hgb-aisystem：Core/SoC 与 YOLO 演示

Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4，
forward3、Tournament1、RAS0、OOO0；正常 ALU/Load/DSP 为 8/10/10 级，尚无 C 扩展。
当前工作分支在 `7b52026` 上补全 YOLOX-Tiny 的模型导出、C 图执行、UART 服务和 1080p 显示通路。
CoreMark 与 RT-Thread 的正式演示在无 NPU 的 main 分支单独验证，RT-Thread 不参与 CoreMark。

截至 2026-10-30，验证范围如下：

| 测试 | 结果与执行方式 |
|---|---|
| YOLOX-Tiny 416，83 Conv / 266 节点 | 33 分 28.7 秒通过；电脑执行 C 图，卷积使用真实 AXI/CDC/NPU RTL，无 RISC-V Core |
| RV32/RV64 真实 Core 驱动 | 各通过 3 个小卷积、171 个输出、5 个量化值；未执行完整网络 |
| 1920×1080 视频 RTL | 双宽通过完整帧 CRC、A/B 切换、AXI 反压、欠载恢复及 49 项 MS7210 初始化 |
| 真实 UART + 原 C 应用短流程 | 两轮上传/回读、SELFTEST、原视频驱动与 A/B 全帧 CRC 通过；CPU 在电脑执行 |
| 320 模型完整应用联合仿真 | 已启动，尚无 PASS；不计为完整 RV32 整网通过 |

YOLO C7 目标 Core/SYS/DDR-user/外设/NPU 为 **90/100/125/60/100 MHz**，视频独立为 **148.5 MHz**。
系统仍用一颗 GPLL 分频，视频另用 27 MHz 输入的 PPLL，DDR 保留控制器自己的时钟结构。
目标频率不等于布线 Fmax。无 NPU C6 的最终布线 Fmax 为 Core/SYS/DDR-user/外设
**87.3057/98.2415/122.5490/72.2201 MHz**，0 未布通，Core 尚未达到 100 MHz。
该工程装入自动 CoreMark 固件；交互固件与新增视频硬件均未布线、未上板。

设置 `RISCV_TOOL_ROOT` 后使用以下入口；输出已有内容时换用新目录：

```bash
make yolo-demo-test
make yolo-demo-build XLEN=32
make yolo-demo-build XLEN=64
make yolo XLEN=32
make yolo-video-test XLEN=32
make yolo-driver-test XLEN=32
```

`yolo-demo-test` 只跑协议、导出、图算子、服务与视频 C 短测；`make yolo` 保留原卷积/DMA 回归。
`yolo-io-test` 生成真实 I/O RTL 库并跑短测，完整联合运行必须显式调用 `yolo-demo-cosim-full`，
并提供已导出模型、RGB 图片和 I/O 库。命令与证据见[项目介绍](docs/PROJECT_INTRO.md)。
RV64 完整固件使用纯 RV64IM 软浮点库，源码根通过 `RISCV_GNU_SOURCE_ROOT` 提供。

板端服务按 READY→上传→DETECT→框结果/画框图片→显示完成→READY 循环。
PC 工具为 `scripts/yolo/host.py --port COM5 status|model|upload|detect|read|selftest`；
模型、图块和整帧均核对 CRC32。预载模型经过 CRC/图结构检查，不代表 Flash 启动已接通；
模型 UART 命令已有软件测试，尚无板上约 5 MB 模型全传结果。

历史裸机数据：M0 O3 64 次为 3.590617/3.570731 CoreMark/MHz，真实 TCM 为
3.095736/3.081770；短仿真没有达到正式十秒要求。分层结果、历史综合和布线分别记录在
[项目介绍](docs/PROJECT_INTRO.md)、[系统结构](docs/understand/SOC_SYSTEM.md)和
[FPGA 适配](docs/fpga/FPGA_ADAPTATION.md)。历史提交用 `git log`/`git show` 查询。
