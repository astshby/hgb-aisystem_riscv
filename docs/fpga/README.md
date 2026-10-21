# FPGA 适配

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。详细流程、结果和边界见 [FPGA_ADAPTATION.md](FPGA_ADAPTATION.md)。

当前要点：

- PDS 2025.2，工程放 `$PDS_WORK_ROOT\work\` 新目录。
- 当前候选：RV32 scoreboard i2/ROB16、full、local TCM 0、块口全开；ALU/Load/DSP 为 8/10/10 级。
- CMP `2b49c77` 的 r12 标准 PDS：87.8837 MHz、85 MHz WNS +0.386 ns、TNS 0、零未布通，物理 LUT/FF 46,457/32,096。
- ISS `85ab1ca` 完整双宽回归与八次重放通过，r13 完整标准 PDS 为 82.8726 MHz、WNS −0.302 ns、86 个 slow setup 失败端点、零未布通，频率验收失败。
- 原 input 默认值阻塞已在 `c04c588` 修复；旧 i1 的物理结果仅用于历史对照。
- 每个 PDS 阶段前清理自有可丢弃缓存，Windows 物理可用量和提交余量分别至少 6 GiB；与仿真/编译分时运行。
- 125 MHz setup 未收敛，没有 bitstream、烧板或十秒 CoreMark。
