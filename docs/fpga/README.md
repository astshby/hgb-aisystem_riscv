# FPGA 与 PDS

当前 YOLO C10 诊断已完成布线和短时上板，完整系统仍无启动服务；
最新进度、过温与串口结论见 [YOLO_BRINGUP_STATUS.md](YOLO_BRINGUP_STATUS.md)。
下列 C6/C7/C8 文字是早期阶段快照，不能替代该报告的最新状态。

Windows PDS 2025.2 ADS、PG2L200H-6IFBB676。当前演示配置为：

| 用途 | 档位 | Core/SYS/DDR-user/外设/NPU，MHz | 视频 |
|---|---|---|---|
| 无 NPU 完整系统 | C6 | 100/100/125/60/无 | 无 |
| YOLO | C7 | 90/100/125/60/100 | PPLL 148.5 MHz |
| YOLO 后备 | C8 | (900/11)/100/125/60/100 | PPLL 148.5 MHz |

2026-10-30，无 NPU C6 最终布线 Fmax 为 87.3057/98.2415/122.5490/72.2201 MHz，
0 未布通，Core 未达到 100 MHz；该工程使用自动 CoreMark 固件。
交互固件和新增视频/YOLO 组合尚未布线、未上板。
系统仍用一颗 GPLL 分频，视频另用 27 MHz 输入 PPLL，DDR IP 内部时钟另计。
完整结果、约束缺口、视频/驱动仿真证据与历史表见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。
完整 320 应用已通过电脑 C + 真实 UART/NPU/AXI/视频 RTL 联合仿真；DDR 为行为模型，
未执行完整 RV32 整网，交互固件与显示通路仍没有布局布线或上板结果。

统一入口要求 8 线程，可用 `HGB_PDS_THREADS` 覆盖；place/route 使用 normal，
不传 PDS 2025.2 不支持的 performance 模式或旧 router-thread 选项。
生成 IP、工程、网表和原始报告放在 `$PDS_WORK_ROOT`，`reference` 子目录只读。
每阶段检查至少 6 GiB 物理和提交余量，不自动修改分页文件或终止无关进程。
