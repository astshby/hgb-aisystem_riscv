# FPGA 与 PDS

Windows PDS 2025.2 ADS、PG2L200H-6IFBB676。当前用途分支的目标为：

| 用途 | 档位 | Core/SYS/DDR-user/外设/NPU，MHz |
|---|---|---|
| 无NPU完整系统 | C6 | 100/100/125/60/— |
| YOLO | C7 | 90/100/125/60/100 |
| YOLO后备 | C8 | (900/11)/100/125/60/100 |

见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。新档已开始仿真验证，尚无对应P&R或板级结果；旧C5结果单列。
物理阶段默认尝试4线程，可用`HGB_PDS_THREADS`覆盖；布局/布线使用normal模式。
生成 IP、工程、网表和原始报告保存在 `$PDS_WORK_ROOT`，`reference` 子目录只读。
每次综合/实现前检查至少 6 GiB 物理与提交余量；不自动调整分页文件或终止无关进程。
