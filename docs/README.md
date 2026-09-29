# 文档入口与分支范围

本目录包含最新硬件接口说明、分阶段解读和软件路线图。正式 SoC 接口文档以 `s5/cache-up` 为参照；旧分支保留同样的文档入口用于对照，不能据此认定该分支已有 S5 的硬件。先用 `git branch --show-current` 确认源码阶段。

| 分支 | 此分支源码的范围 | 与 S5 文档的关系 |
|---|---|---|
| `main` | 六级 Core、M 扩展 | SoC 章节是后续功能参考 |
| `SOC/tmc-mmio` | ROM、TCM、MMIO、中断 | DMA/AXI/Cache 是后续功能参考 |
| `soc/s3-axi-dma` | 早期 AXI 边界 | DMA 完整验证与 Cache 尚待后续分支 |
| `soc/s3-dma-validation` | DMA 与仿真外存闭环 | Cache 是后续功能参考 |
| `s4/cache` | I$ 和 WT/NWA D$ | S5 写回与维护状态尚未实现 |
| `s5/cache-up` | WB/WA D$、DMA 交接、FENCE.I 写回 | 当前正式接口的实现参照 |
| `docs/soc-learning-map` | 文档整理 | 源码承接 S5 |

接口查 [SoC 访存契约](SOC_BUS_CONTRACT.md)、[外设连接图与寄存器](SOC_PERIPHERALS.md)、[AXI/DDR 边界](SOC_EXTERNAL_MEMORY.md)。需要按源文件读代码时，从 [understand/ 导读](understand/README.md) 进入；它把前置知识、SoC 理论、各分支实践分开。运行命令见 [仿真工作流](SIMULATION_AND_FPGA.md)，目标见 [硬件路线](HARDWARE_ROADMAP.md) 与 [软件路线](SOFTWARE_ROADMAP.md)。

`docs/COMMIT.md` 是既有历史记录，本次文档整理不改其内容。不同分支的历史记录保留各自原文；切换分支时可用当前源码、正式接口与对应阶段解读交叉检查。
