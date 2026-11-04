# FPGA 与 PDS

平台：Pango PDS 2025.2 ADS，器件 PG2L200H-6IFBB676。

FPGA 适配已完成：完整 YOLO + HDMI 工程通过综合、布局、布线、时序分析与位流生成，
C10 工作档六个时钟域均达到时序要求，布线无未布通网络。板级整网验收仍在进行，
当前进度与证据边界见 [YOLO_BRINGUP_STATUS.md](YOLO_BRINGUP_STATUS.md)。

## 时钟档

| 档位 | 名称 | Core / SYS / DDR-user / 外设 / NPU（MHz） | 用途 |
|---|---|---|---|
| C10 | yolo_sys | 83.806818 / 102.430556 / 125 / 65.848214 / 92.1875 | 工作档 |
| C11 | yolo_half | 41.903409 / 51.215277 / 125 / 32.924107 / 46.09375 | 半速诊断 |
| C12 | yolo_quarter | 20.951704 / 25.607638 / 125 / 16.462053 / 23.046875 | 四分之一速诊断 |

视频由独立 PPLL 提供 148.5 MHz，DDR 用户时钟由 DDR IP 提供，两者不随上表变化。
C11/C12 用于在更宽时序余量下定位板级问题，不作为性能数据。

## C10 实测

| 时钟域 | Fmax |
|---|---:|
| clk_core | 85.9387 MHz |
| clk_sys | 108.0885 MHz |
| ddrphy_sysclk | 132.6612 MHz |
| clk_periph | 72.8046 MHz |
| clk_npu | 95.5526 MHz |
| clk_video | 162.8928 MHz |

六域 WNS 为正，slow/fast 全部内部 setup/hold、恢复、MPW、CDC/Gray 与 DDR PHY 检查通过，
未布通网络 0。资源：LUT 94,202、FF 73,263、DRM 169 格、APM 86 单元。

## 运行约定

- 统一入口为 `scripts/pango/run_phase.ps1`，每个阶段启动前检查 Windows 可用物理内存
  与可用提交内存均不少于 6 GiB 时才开始；不允许临时降低门限。
- 默认 8 线程，可用 `HGB_PDS_THREADS` 覆盖；一次只运行一个 PDS 工程。
- 布局与布线使用 `normal` 模式；`fast` 模式内存占用低但时序质量不足，只用于快速试跑。
- 生成 IP、原生工程、网表与原始报告放在 `$PDS_WORK_ROOT`，`reference` 子目录只读。
- 结果记录包含分支/提交、构建参数、固件身份、命令与日志位置；不把工具估计写成板上结果。

完整命令、约束说明、历史阶段与失败处理见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。
