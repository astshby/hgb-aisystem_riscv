# 理解与学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。本目录只保留五块总结，详细历史实现用 Git 分支和提交查。

| 块 | 文档 | 读完应能回答 |
|---|---|---|
| SoC 系统 | [SOC_SYSTEM.md](SOC_SYSTEM.md) | IF、双数据口与 DMA 怎样访问 TCM/ROM/MMIO/DDR；请求、响应、owner、错误和中断怎样闭合 |
| 双发射 | [DUAL_ISSUE.md](DUAL_ISSUE.md) | 两条指令何时能配对；第二槽、退休队列和完成口怎样工作 |
| DDR 与 AXI | [DDR_AXI.md](DDR_AXI.md) | 标准 AXI、Pango 原生口、块传输、Cache 行和 DMA 的边界 |
| FPGA | [FPGA_LEARNING.md](FPGA_LEARNING.md) | 历史频率解耦与新 P0 怎样验证；复位、资源和标准 PDS 怎样影响 Fmax |
| 优化 | [OPTIMIZATION.md](OPTIMIZATION.md) | CoreMark 口径；第四、六、十轮为什么是负优化；下一步先改什么 |

建议顺序：

1. 先读 SoC 系统，建立一次请求从 Core 到设备的完整路径。
2. 再读 DDR/AXI，理解外存和 Cache 行传输。
3. 读双发射，理解为什么 Core-only 和 SoC 的供给能力不同。
4. 读 FPGA，理解频率边界的代价。
5. 最后读优化，把周期、频率和资源放在一起看。

修改 RTL 前先查对应契约和测试。本文只保留结论，不复述全部历史。
