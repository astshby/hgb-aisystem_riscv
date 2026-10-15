# FPGA RT-Thread / CoreMark：目标、实现与综合报告

更新：2026-10-15。本报告是板级工作的统一入口；阶段历史保留在 [COMMIT.md](COMMIT.md)。

## 目标与本 PR 的交付边界

在 MES2L676-200HP（PG2L200H-6IFBB676）上，以六级 RISC-V Core 运行 RT-Thread 与 CoreMark：
主程序、数据、线程栈和工作集使用真实 DDR3，热代码由硬件 DMA 从 D-TCM 装载到 I-TCM，
通过板上 CP2102 对应的 SoC UART 下载应用并输出 CRC、周期和成绩。乘法选 DSP（`MUL_IMPL=0`），
除法选 Radix-4 SRT（`DIV_IMPL=1`）；目标 SoC 100 MHz，DDR 用户域优先同步、必要时 CDC。

**本 PR 交付可从干净检出重建的 RV32 综合基线及软件模型验证，尚不交付时序达标或实板 demo。**
提交采用已评审的单时钟硬件基线：SoC 与 DDR 用户接口共用实际 125 MHz，生产 UART 为 115200。
100 MHz CDC/寄存边界实验因时序失败已归档恢复，不属于本 PR 的产品 RTL。100 MHz 仍是后续目标。

## 已实现的完整链路

```text
ROM → I-TCM loader → SoC UART / HGB1 / CRC → DDR 镜像发布和读回
    → DDR 中的 RT-Thread + CoreMark → DMA：D-TCM 热镜像 → I-TCM
    → FENCE.I → UART 输出 CRC/cycles → 驻留等待 r → 重测
```

| 部分 | 实现与边界 |
|---|---|
| SoC/DDR 接口 | `pango_200hp_top` 接参考时钟、DDR IP、复位和 UART；`pango_ddr3_bridge` 转换本地单在途请求与 256-bit 原生用户接口，处理地址单位、byte lane、掩码和响应 |
| 软件布局 | DDR 文件段 `0x80000000–0x8001ffff`，工作集 `0x80020000`，scratch `0x8003f000`；热区 VMA `0x0100e000`、LMA `0x0110c000`；RV32/RV64 实际 DMA 984/976 B |
| UART 下载 | HGB1 header/段表/块 CRC、范围和重叠校验、ACK/NAK、失败重试、D$ flush/invalidate 与读回、FENCE.I 跳转；应用驻留并接受 `r` 重测 |
| RT-Thread/CoreMark | DDR 主代码/数据/栈布局、performance/validation、2000 B 工作集、DMA 热执行与频率/配置/64 位周期输出；短时模型 CRC 不算正式成绩 |
| ADS 适配 | 同值无类型参数和显式 package 类型引用，保持 RTL 行为；未修改六级 Core、DSP/SRT 算法或 CoreMark vendor |
| 可复现综合 | 入库板级 IDF/FDC；PowerShell 调用 WSL 编译生产 loader、隔离生成 IP、暂存相对路径工程、原生 ADS 综合、全量 TCM 初值与精确字节哈希检查 |

板上两片 x16 DDR3 合成 x32；依据《MES2L676-200HP 硬件使用手册 v1.2》第 15–17 页，LOC 与候选元数据已核对 73/73 DDR/参考时钟、71/71 活动 PAD。
实际颗粒为 XCCC256M16EP-EINAY，当前 HMIC 采用板厂兼容说明中的 MT41K256M16XX 预设；
逐项颗粒时序等效、PHY 校准与真实读写仍未验收。数字 RAM/原生接口模型不代表板载 DDR3。

## 哪些文件实现了什么

| 文件/目录 | 相对已合并 PR #5 的变更 |
|---|---|
| `vsrc/cpu/pango_200hp_top.sv`、`pango_ddr3_bridge.sv` | 新板级顶层和原生 DDR 用户接口桥；DSP/SRT 配置明确 |
| `vsrc/pkg/core_types_pkg.sv`、`vsrc/soc/{soc_top.sv,memory/tcm_controller.sv}` | 已验证的 ADS 等价语法适配 |
| `software/loader/`、`scripts/loader/`、`tb/loader/` | 两阶段 UART 下载、CRC/错误恢复、DDR 发布/读回和主机/SoC 测试 |
| `software/rt-thread/`、`scripts/rt-thread/`、`tb/soc/tb_rt_thread_coremark.sv` | DDR CoreMark 布局、驻留重测、DMA 热装载及数字 UART 集成 |
| `scripts/pango/`、`scripts/pango_files.f`、`ip/pango/mes2l676_200hp_ddr3.idf` | 源列表、板级约束、固定 IP 配置、跨 Windows/WSL 构建、综合/INIT/manifest 门槛 |
| `tb/unit/tb_pango_ddr3_bridge.sv` | 原生接口地址/掩码、错误与反压定向测试 |
| `scripts/verilator/`、`Makefile` | 新目标入口、配置传递、SRT 宿主构建和既有 ISA 适配 |
| `README.md`、本报告、相关 docs | 统一目标/实现/复现/限制，合并两份重复板级进度文档；保留原架构与阶段历史 |

末尾清单列出本 PR 的全部文件；提交不包含生成 IP RTL、厂商安装包、网表、bitstream、个人路径或历史 WSL 镜像。

## 时序分析：优化了哪里，哪些未采用

下表均为实际 PDS post-route 报告。除首行基线外均为已恢复的实验，**不混入本 PR 产品 RTL**。
WNS 跨时钟/构建不能直接当作同条件优化收益。

| 实验与涉及模块 | 切断/简化的依赖 | SoC MHz | WNS ns | 结论 |
|---|---|---:|---:|---|
| 本 PR 硬件基线 | 原 SoC 请求/响应通路 | 125 | −17.625 | 可综合、可布通，setup 未达标 |
| 外设请求缓冲：fabric/SoC | 请求与 owner 寄存，隔离外设目标 | 125 | −18.573 | 瓶颈转移，未采用 |
| IF 请求缓冲：SoC | IF→I-Cache 请求寄存 | 125 | −17.040 | 改善 0.585 ns，响应反馈仍在 |
| 组合边界：fabric/SoC | IRQ/GPIO 请求寄存 + IF/FENCE.I 边界 | 125 | −18.681 | 未收敛，未采用 |
| DDR PREPARE：bridge | 接受请求先快照，下一拍校验/打包 | 125 | −16.208 | 改善 1.417 ns，旧 bridge 末段被切断 |
| EX 独立地址：EX | 访存异常地址绕开通用 ALU 比较链 | 125 | −17.867 | 原链消失，分支/IF 成新瓶颈 |
| execute-only：EX/fabric/SoC | 排除 IF 对不可执行 MMIO 的冗余参与 | 125 | −16.716 | 改善 0.909 ns，仍未收敛 |
| 100/125 平台：SoC/wrapper/CDC/bridge | D 响应、IF 请求、FENCE.I 寄存；独立 PLL/CDC/PREPARE | 100 | −11.147 | 周期预算增加 2 ns；仍未达标，已恢复 |

原 125 MHz 长链为 TCM→WB 前递→分支→IF/Cache/fabric→外设或 DDR 控制，约 24–26 ns，
多数延迟来自布线。100 MHz 实验的新链为 DSP 输出/符号修正→D 地址译码→MEM stall/redirect→
I-Cache/fabric→DMA CE，25 级、20.375 ns（逻辑 5.407、布线 14.968 ns，73.463%）。
IF 请求寄存仍未隔离 IF 响应 ready 经 cache_port 同拍交接回到 fabric 的反馈。
完整门级链可达性未证明，未用 broad false-path 隐藏。

100 MHz 实验另发现 bridge 合法性控制宽寄存器的 8.905 ns 路径；DDR 同域 WNS −1.362 ns；
3 个跨域失败端点实际为 req/rsp/ack 第一级 meta，预期窄例外未在最终映射 STA 生效；
27 MHz 监督器→DDR IP reset 的 recovery/removal −2.875/−0.818 ns（slow，各 23 个失败）。
这些问题均未因“综合通过”被忽略。复位 whole-cell false-path 阻碍 TCM 读寄存器合并的原因已由同源
对照证实（0→16 DRM）；Pango 的有效同步器属性是 `PAP_ASYNC_REG`，通用 `ASYNC_REG` 被 ADS 忽略。

## 资源、功耗与验收状态

| 构建 | LUT | FF | BRAM36K | DSP/APM | 状态 |
|---|---:|---:|---:|---:|---|
| 已验证基线综合 | 16,331 | 12,377 | 34 | 4 | 双 TCM 各 16 BRAM、64 KiB 初值全量通过 |
| 基线 post-route | 20,272 | 12,427 | 34 | 4 | 零未布通网络，setup −17.625 ns；data hold +0.019 ns |
| 已恢复 100 MHz 实验综合 | 16,402 | 12,731 | 34 | 4 | 严格 INIT 通过，未采用 |
| 已恢复 100 MHz post-route | 20,331 | 12,752 | 34 | 4 | setup −11.147 ns；SoC data hold +0.016 ns，reset 时序失败 |

旧基线 PDS 片上功耗估算 2.276–2.332 W，条件为 Typical/Production、25 °C、默认 5 pF 负载及
10%/20% 假设活动率，置信度 Low。它不含外部 DDR/整板，不是实测或 CPU 独立功耗，不能复用为
100 MHz 实验功耗。当前没有板上 DDR 校准、物理 UART 日志、正式 CoreMark 或 ILA 捕获。

## 干净检出后的直接综合

需要 Windows PDS **2025.2-ads build 211867** 和许可证、本地 **HMIC_S 1.10 `.iar`**；
WSL2 Ubuntu-22.04 内安装 Git、Python 3、Bash 和 RISC-V GCC/binutils（Ubuntu `gcc-riscv64-linux-gnu`）。
不需要 Windows Python、先前生成 IP、旧 C/F 盘工程或已编译 HEX。HMIC 安装包由使用者提供，本仓库保存板级配置并自动隔离生成。

在 Windows PowerShell 中进入检出目录（Windows 本地路径或该 WSL 发行版的 UNC 路径），执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\pango\build.ps1 `
  -PdsHome 'F:\pango\PDS_2025.2-ads' `
  -DdrIpArchive 'F:\reference\ips2l_hmic_s_v1_10.iar' `
  -WorkRoot 'F:\pango-project\work\fresh-rv32' `
  -Distribution 'Ubuntu-22.04'
# 非默认 WSL 用户可加 -WslUser yukino；工具链可用 -CrossCompile 显式覆盖。
```

`WorkRoot` 必须是不存在的原生 Windows ASCII 路径，每次重建用新目录，参考资料和 PDS 安装不被覆盖。
入口完成生产 115200 loader、IP 生成、164 HDL 暂存、ADS compile/synthesis、双 TCM 全量 INIT、
manifest 字节哈希和 34 BRAM/4 DSP/0 latch 检查后才打印 PASS。
`build-receipt.json` 记录 Git HEAD/工作树、配置及安装包哈希；`soc-rv32/synthesis-summary.json` 和 `logs/` 保存原始证据。
此命令只验收综合，不执行布局布线、bitstream、JTAG 或烧写。

生产应用另在 WSL 构建和打包（默认 115200、驻留重测、自动校准有效时长）：

```bash
make rt-thread-fetch
RT_APP=coremark RT_COREMARK_LAYOUT=ddr RT_COREMARK_RESIDENT=1 RT_COREMARK_ITERATIONS=0 \
  MUL_IMPL=0 DIV_IMPL=1 CROSS_COMPILE=/usr/bin/riscv64-linux-gnu- bash scripts/rt-thread/build.sh 32
python3 scripts/loader/host.py build/rt-thread/coremark-ddr-performance-rv32-resident/program.elf \
  --output build/loader/resident-rv32.hgb
```

validation 使用 `RT_COREMARK_MODE=validation` 并选择对应 ELF；RV64 使用独立位宽目录。
上板阶段串口发送需要 Python/pyserial 和真实串口（Windows `COMx` 或已映射的 WSL 设备）；JTAG 不承担 UART 应用下载。

## 本次提交验证

提交验证仍在进行；发布前会用干净克隆的最终提交重新运行上述命令，并填写确切结果。

日常双位宽回归仍遵循根 AGENTS：显式 `MUL_IMPL=0 DIV_IMPL=1`，运行 test、riscv-tests、
benchmark-smoke、coremark 的 RV32/RV64；ISA 克隆、裸机工具链及 RT-Thread v5.2.2 的安装/版本要求见
[仿真工作流](SIMULATION_AND_FPGA.md) 和 [RT-Thread 移植](RT_THREAD_PORT.md)。

## 后续计划

下一轮先独立 LSU 载荷、补 D 请求/I 响应寄存边界，并修正 bridge 控制扇出、映射 CDC 例外和 DDR reset 释放。
该 20 文件方案尚未实施，依根 AGENTS 另行审阅；不把失败的实验恢复进本 PR。
100 MHz/DDR/PHY 的完整 setup、hold、recovery/removal 和外部 IO 达标后，才准备 bitstream 与上板。
实板依次验收 DDR 校准及 cache 外读写、CP2102 UART 下载/重试、RT-Thread tick/DMA 热执行、
performance/validation 至少十秒和正确 CRC，再提供同一构建的资源/时序/有依据功耗与需要的 ILA 波形。

## 本 PR 文件清单

相对最新 main（`c2818ca`）共 61 个文件，以下为实际提交清单。

```text
Makefile
README.md
docs/COMMIT.md
docs/FPGA_DEMO_REPORT.md
docs/HARDWARE_ROADMAP.md
docs/PROJECT_STRUCTURE.md
docs/README.md
docs/RT_THREAD_PORT.md
docs/SIMULATION_AND_FPGA.md
docs/SOC_EXTERNAL_MEMORY.md
docs/SOFTWARE_ROADMAP.md
docs/understand/AXI_DDR_BOUNDARY.md
ip/README.md
ip/pango/mes2l676_200hp_ddr3.idf
scripts/loader/build.sh
scripts/loader/host.py
scripts/loader/test_host.sh
scripts/loader/test_protocol.py
scripts/loader/test_rt_thread.sh
scripts/loader/test_soc.sh
scripts/pango/build.ps1
scripts/pango/check_ip_dq.py
scripts/pango/check_tcm_init.py
scripts/pango/generate_ddr_ip.ps1
scripts/pango/implement.tcl
scripts/pango/import_ddr_pins.tcl
scripts/pango/mes2l676_200hp.fdc
scripts/pango/prepare_project.py
scripts/pango/test_bridge.sh
scripts/pango/verify_synthesis.py
scripts/pango/wsl_helpers.ps1
scripts/pango_files.f
scripts/rt-thread/build.sh
scripts/rt-thread/build_sim.sh
scripts/rt-thread/check_image.py
scripts/rt-thread/run_coremark.sh
scripts/verilator/build_benchmark_image.sh
scripts/verilator/build_benchmark_sim.sh
scripts/verilator/run_directed.sh
scripts/verilator/run_riscv_tests.sh
scripts/verilator/run_unit.sh
software/loader/link.ld
software/loader/platform.c
software/loader/protocol.c
software/loader/protocol.h
software/loader/startup.S
software/rt-thread/bootstrap_ddr.S
software/rt-thread/core_portme.h
software/rt-thread/coremark_app.c
software/rt-thread/coremark_port.c
software/rt-thread/link_coremark.ld
software/rt-thread/link_coremark_ddr.ld
tb/loader/host_backend.c
tb/loader/tb_uart_loader.sv
tb/soc/tb_rt_thread_coremark.sv
tb/unit/tb_pango_ddr3_bridge.sv
vsrc/cpu/pango_200hp_top.sv
vsrc/cpu/pango_ddr3_bridge.sv
vsrc/pkg/core_types_pkg.sv
vsrc/soc/memory/tcm_controller.sv
vsrc/soc/soc_top.sv
```
