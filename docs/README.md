# 文档入口

> 写作约束：[skills/regulation.md](../../skills/regulation.md)。所有新增和修改的 Markdown 都按这份约束写。

| 文档 | 内容 |
|---|---|
| [PROJECT_INTRO.md](PROJECT_INTRO.md) | 项目目录、参数、环境、仿真性能、FPGA 性能、功能、未来 |
| [understand/README.md](understand/README.md) | 五块学习总结：SoC、双发射、DDR/AXI、FPGA、优化 |
| [fpga/FPGA_ADAPTATION.md](fpga/FPGA_ADAPTATION.md) | PDS 流程、C6 最终布线、视频/驱动验证及历史 Fmax |

工作区根目录还有三份交接文档：

- `ITERATIONS.md`：每次迭代的目的、优势、代价。
- `OPTIMIZATION_PLAN.md`：逐步优化建议和分支顺序。
- `HANDOVER.md`：当前代码位置、问题、环境、下一步。

`docs/COMMIT.md` 不再存在。历史阶段记录已合并到上述文档，逐条提交用
`git log`/`git show` 查。

## 源码入口

- `vsrc/core/`：Core。
- `vsrc/soc/`：SoC。
- `vsrc/cpu/`：FPGA wrapper 和 DDR 桥。
- `tb/`：测试。
- `scripts/`：仿真、PDS、loader。
- `benchmark/`：裸机 CoreMark；通用启动/runtime 在 `software/common/baremetal/`。

修改 RTL 前先看对应学习文档和测试；功能和性能边界以源码、正式契约和实测日志为准。
