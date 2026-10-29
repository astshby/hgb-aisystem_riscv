# 项目配置与测量

## 目录与公共配置

`vsrc/core` 保存共享 Core，`vsrc/soc` 保存 TCM/Cache、AXI、DMA、MMIO 和跨域接口，
`vsrc/cpu` 为 FPGA 顶层。`scripts/hardware_profile.json` 固定 Core 参数、容量和目标时钟；
`scripts/branch_profile.json` 记录当前分支保留的应用。`make help` 只显示存在的应用。
Core 为 RV32/RV64 IM+Zicsr，双发射、按序双退休，ROB16、int8/mem4、LQ4/SQ4，
正常 ALU/Load/DSP 为 8/10/10 级；C、F/V、MMU/Linux 未实现。

目标 Core/SYS/DDR-user/外设为 100/80/125/25 MHz，选用加速器时增加独立 100 MHz 域。
ITCM/DTCM 各 64 KiB，I$/D$ 各 4 KiB、两路、32 B 行；I$ 当前填充粒度 4 B。
TCM 与 Cache 命中逻辑仍在 Core 域；Core 与它们进一步分域仅是未来候选。
SYS 负责统一 AXI 仲裁，DDR 与外设分别通过 FIFO 跨域。DMA 是 SYS 域主设备，
CPU 提交地址/长度/方向、启动、核对完成和处理 Cache 所有权；不允许 DMA 写 START 等控制寄存器。

| 发布分支 | CoreMark | RT-Thread | 加速器 |
|---|---|---|---|
| main | M0 与三层实际硬件 | 独立应用 | 无 |
| baseline-yolo | 无 | 无 | YOLO |
| baseline-minimind | 无 | 无 | MiniMind |
| baseline-all | M0、三层与 YOLO 并发层 | 一份独立应用 | 分别选择 YOLO / MiniMind |

所有分支保留公共功能、ISA、AXI、CDC、UART 下载验证。加速器分支不携带 CoreMark 算法、
跑分脚本或 RT-Thread。原作者 MiniMind C 代码、模型锁和导出工具保留在 MiniMind/all。

## 环境与命令

实测工具为 GCC 16.1.0、Verilator 5.052、Windows PDS 2025.2 ADS。
外部路径使用 `RISCV_TOOL_ROOT`、`PDS_HOME`、`PDS_WORK_ROOT`、`RTTHREAD_ROOT`。
依赖 `riscv-tests` checkout 只读、不作为本轮新子模块提交。

`make check XLEN=32|64` 运行通用功能、scoreboard、ISA、SoC、五组时钟、AXI 和 C smoke。
`make loader-host-test` 与 `make loader-soc-test XLEN=32|64` 检查下载协议和 UART 实际引脚。
本分支应用入口以 `make help` 为准。
软件默认 O3，用 `SOFTWARE_OPT=O2|O3|Ofast` 覆盖。Ofast 本轮没有稳定额外收益，未设为默认。

## 加速器与 FPGA 边界

MiniMind 迁入同一五域系统，100 MHz 域中的算子通过独立 AXI 主口访问共享 DDR；
CPU 控制窗口为 `0x20000000`。双宽单层 38 命令与参考字节一致，
RV32/RV64 为 4,680,438/4,678,859 TB 周期，各 59,857 次外部主口读命令。
完整运行库每宽 4 次正常及 4 次预期错误通过，包含 CPU/加速器对照与 32 KiB DMA 并发。
RTL 未运行完整八层、多 Token 或语言质量测试。

## MiniMind 常驻交互软件

`software/minimind3/demo/` 提供初始化一次、READY、UTF-8 输入、逐 Token 回传、DONE、
再次 READY 的独立入口，原作者 `baremetal/main.c` 和 `c_runtime/integer_main.inc` 保持原样。
模型与 tokenizer 只装载一次；每轮清零八层 KV、pos 和统计量，并回收本轮临时内存。

原生 C 测试使用真实八层整数运行库，12 PASS / 0 SKIP，包括中文模板、重复请求、
原作者入口输出对照、长度/UTF-8/context 错误恢复和资产 CRC 校验。
两次短请求各输入 2 Token、生成 1 Token，pos 均为 2，完整 KV 哈希均为 3763136066；
常驻分配 66,298,944 B，峰值 RSS 66,048 KiB。单 Token 检查没有语言质量结论。
RV32/RV64 固件编译通过，使用真实 UART MMIO 与原加速器驱动，尚未运行这套固件的 RTL 或板级验证。

设置 `MM3_DEMO_ASSETS` 为已有 `model_w8a16_int.bin`、`tokenizer.bin` 的已校验资产目录，
设置 `RISCV_TOOL_ROOT` 为交叉编译器 bin，再执行：

```bash
: "${MM3_DEMO_ASSETS:?设置已校验资产目录}"
export MM3_DEMO_ASSETS
export MM3_DEMO_OUT="${MM3_DEMO_OUT:-$PWD/build/minimind-demo}"
make minimind-demo-native
printf 'Hi\r\nHi\r\n' | "$MM3_DEMO_OUT/minimind-interactive" \
    --model "$MM3_DEMO_ASSETS/model_w8a16_int.bin" \
    --tokenizer "$MM3_DEMO_ASSETS/tokenizer.bin" --raw --max-new-tokens 1
make minimind-demo-test
make minimind-demo-build XLEN=32
make minimind-demo-build XLEN=64
python3 scripts/demo/minimind_uart.py asset-header \
    --model "$MM3_DEMO_ASSETS/model_w8a16_int.bin" \
    --tokenizer "$MM3_DEMO_ASSETS/tokenizer.bin" \
    --output "$MM3_DEMO_OUT/asset-header.bin"
```

板级程序要求 ITCM 固件与 DDR 数据预装，生成目录的 `board-build.json` 列出地址、长度与哈希。
资产头在 `0x80400000`，模型在 `0x81000000`，tokenizer 在 `0x85000000`；启动时校验头及资产 CRC。
现有 HGB1 下载器只接受 `0x80000000–0x80020000` 的 DDR 窗口，无法装载约 64 MB 模型。
TF 驱动及大资产 UART 传输尚未实现；资产头生成不包含数据搬运。
电脑工具 `scripts/demo/minimind_uart.py` 支持 `decode --input ... --output ...` 解析保存的回传，
也提供 `chat --port ... --prompt ... --output ... --raw-log ...`，待板侧数据装载和固件运行通过后使用。

标准综合按五种实际硬件分别测资源和域内 Fmax，不将核级最高值用作完整系统频率。
本轮没有 P&R、bitstream 或板级结果。原生综合与内存检查位于 `$PDS_WORK_ROOT/work/four-branches-20261027/`。
CDC/PHY/I/O 的原始跨域报告与域内路径分别呈现，不用 false path 隐藏真实同步路径。

## 本轮标准综合

本轮各配置的 Fmax/WNS、LUT/FF/DRM/APM、最差路径和未完成项，
见 [FPGA 实测表](fpga/FPGA_ADAPTATION.md#2026-10-27-标准综合实测)。本分支表只列自身保留的硬件。
双宽五域仿真已通过。PDS 在 RTL/RAM 推断阶段产生 14 个加速器数组多写 RAM 警告，约 59 分钟后按维护者决定停止；没有 MiniMind Fmax 和资源结果，独立域 100 MHz 仍是配置目标。
没有本轮布局布线或上板成绩。已完成的仿真和原生综合绑定各自冻结输入，文档更新不改变测量来源。
