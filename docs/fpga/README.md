# FPGA 与 PDS

Windows PDS 2025.2 ADS、PG2L200H-6IFBB676。Core/SYS/DDR-user/外设目标为
100/80/125/25 MHz，选择 YOLO 或 MiniMind 时增加 100 MHz 加速域。

见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。本轮只运行标准综合；新版本没有 P&R 或板级结果。
生成 IP、工程、网表和原始报告保存在 `$PDS_WORK_ROOT`，`reference` 子目录只读。
每次综合/实现前检查至少 6 GiB 物理与提交余量；不自动调整分页文件或终止无关进程。
