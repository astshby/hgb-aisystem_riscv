# 文档入口与源码范围

`main` 已通过 PR #5 合入 `rt-thread-port` 的首版软件适配。RT-Thread 的构建、DMA/TCM 地址规划、测试和未实现边界见 [首版 BSP](RT_THREAD_PORT.md)。MES2L676-200HP 的目标、实现、改动文件、时序和 Windows/WSL2 综合复现统一见 [FPGA demo 报告](FPGA_DEMO_REPORT.md)；此报告取代两份重复的板级进度文档，原架构文档和阶段历史保留。

`SOC/all` 是 hgb 的历史协作开发分支，源码包含 S5 写回/写分配 Cache、DMA、TCM 和 MMIO。本目录保留完整的接口、阶段解读和软件路线文档；当前 `main` 已包含这些 SoC 内容及首版 BSP。rhbyv 保留阶段分支供逐步学习，hgb 的旧阶段分支已并入 `SOC/all` 的提交历史。

| 阶段 | hgb 历史提交 | rhbyv 学习分支 | 当时实现的边界 |
|---|---|---|---|
| Core/M | `9427fe5` | `main` | 六级 Core、M 扩展 |
| S2 | `de67bbb` | `SOC/tmc-mmio` | ROM、TCM、MMIO、IRQ |
| S3 AXI 检查点 | `a2f7726` | 无独立对应分支 | 本地到 AXI 桥，尚无完整 DMA |
| S3 DMA 验证 | `f714fba` | `soc/s3-axi-dma` | 第三主端、DMA、仿真外存闭环 |
| S4 | `4f0ddcb` | `s4/cache` | I$、WT/NWA D$ |
| S5 | `909ac2d` | `s5/cache-up` | WB/WA D$、维护协议、FENCE.I clean |

`SOC/all` 延续 S5 源码并合入文档整理。历史提交可用 `git show <提交>:<路径>` 读取，不需要恢复已删除的 hgb 阶段分支。rhbyv 的 S3 与 hgb `f714fba` 在硬件、测试、脚本、benchmark 和 Makefile 上逐文件一致；两仓的 README、协作文档和软件路线各自维护。

修改 RTL 前查 [SoC 访存契约](SOC_BUS_CONTRACT.md)、[外设连接图与寄存器](SOC_PERIPHERALS.md)、[AXI/DDR 边界](SOC_EXTERNAL_MEMORY.md)。按源码学习从 [understand 导读](understand/README.md) 开始；运行命令见 [仿真工作流](SIMULATION_AND_FPGA.md)，目标见 [硬件路线](HARDWARE_ROADMAP.md) 与 [软件路线](SOFTWARE_ROADMAP.md)。历史变更仍保存在 [COMMIT.md](COMMIT.md)。
