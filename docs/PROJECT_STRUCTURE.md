# 项目目录说明

## 当前边界

本项目按“可移植 Core、仿真平台、FPGA 平台”分层。当前 A5 基线加 B 阶段基础 M，
已完成六级 RV32IM/RV64IM、Zicsr、机器模式同步异常/中断、裸机 C 与 CoreMark 仿真闭环；
可移植 SoC 已含 TCM、UART/Timer/GPIO。已接入 DDR 两路 I$/D$；板级 IP、C 扩展和操作系统支持仍待实现。平台目标为
Zynq-7020 和紫光同创盘古 676-200K Pro，详见 [平台适配](PLATFORM_ADAPTATION.md)。

```text
rhbyv-cpu-forlinux/
├── vsrc/          # SystemVerilog RTL 与仿真模型
├── tb/            # 单元、整核和上游 ISA 测试适配
├── scripts/       # 源码清单、Verilator、工具链和 Vivado 脚本
├── riscv-tests/   # 可选的只读上游参考 clone，由父仓库忽略
├── benchmark/     # 裸机 BSP、C smoke、CoreMark vendor 与 port
├── ip/            # 厂商 IP 配置预留，后续按平台隔离
├── constr/        # 引脚与时序约束预留，后续按平台隔离
├── docs/          # 项目文档
├── build/         # 自动生成的编译结果，不提交
└── logs/          # 自动生成的日志，不提交
```

## `vsrc/`

### 共享 Package

| 文件 | 作用 |
|---|---|
| `pkg/core_config_pkg.sv` | XLEN、总线宽度、BTB/PHT、MUL_IMPL/DIV_IMPL 等构建参数 |
| `pkg/riscv_unpriv_pkg.sv` | RV32I/RV64I/M、Zicsr 非特权编码 |
| `pkg/riscv_priv_pkg.sv` | MRET、机器 CSR、异常与中断编号 |
| `pkg/core_types_pkg.sv` | uOp、执行操作和寄存器地址类型 |
| `pkg/pipeline_pkg.sv` | 流水包、异常、重定向、预测更新、前递和流水动作 |
| `pkg/soc_config_pkg.sv`、`soc_addr_pkg.sv` | SoC 容量参数和统一物理地址表 |
| `pkg/bus_types_pkg.sv` | 本地请求/响应、目标和错误枚举，无函数 |

### 可移植 Core

`vsrc/core/core.sv` 只负责模块连接、五组级间寄存器和少量全核信号汇总。
功能按稳定职责划分：

| 目录 | 主要模块与职责 |
|---|---|
| `frontend/` | IF 请求/响应、BTB、GShare、预测器和更新仲裁 |
| `decode/` | Decoder、立即数、D1/D2 和 D1 异常检测 |
| `execute/` | ALU、分支、GPR 旁路、EX/异常检测；M 模块位于下级 `M_extension/` |
| `execute/M_extension/` | EX 请求适配、Core 中独立 MDU 握手层、MEM 内部结果适配和乘除后端 |
| `lsu/` | Load/Store 字节通道、MEM 请求发射；mem_stage 内部实例化 mem_mdu 拼包运算结果 |
| `csr/` | CSR 运算、访问检查、WARL、旁路和状态寄存器 |
| `control/` | load-use、MDU 等待、流水事件仲裁、异常序列化和排空后的中断入口 |
| `writeback/` | Load/Store 响应、访问错误、GPR/CSR 提交、Trap/MRET/FENCE 重定向 |
| `common/` | RegFile 等跨功能域基础模块 |

### 可移植 SoC

`vsrc/soc/soc_top.sv` 连接 Core、ROM、I/D-TCM、三主端口互连、I$/D$、DMA 和外设集群。
`cache/` 分离端口路由、同步数据阵列、tag/valid/dirty/LRU、填行、写回和维护控制；
仅缓存 DDR，D$ 采用 WB/WA，`dcache_wt` 保留旧 WT/NWA 单测参考，不接入 SoC。
`common/soc_info.sv` 另提供 D$ 能力查询与全失效命令，便于 DMA 软件交接。
`bus/` 负责地址、仲裁、错误响应及本地到 AXI4 单拍桥；`memory/` 提供同步 TCM 与启动 ROM；
`dma/` 包含引擎、MMIO 寄存器和控制封装；`common/` 提供 MMIO 端点与输入同步器；
`peripheral/` 实现 UART、Timer、GPIO，`interrupt/` 汇聚外部中断。
外存经可综合本地端口暴露，仿真桥接 AXI RAM；真实 DDR3 IP 尚未接入。
协议见 [SoC 访存契约](SOC_BUS_CONTRACT.md)，寄存器见 [外设接口](SOC_PERIPHERALS.md)。

### 仿真和 FPGA Wrapper

- `vsrc/sim_cpu/` 不可综合，包含一周期 IMem/DMem 和不解释测试协议的仿真顶层。
- `vsrc/cpu/` 可综合，当前只有复位同步和未连接 BRAM 的 `cpu_top` 框架。
- Core 只认指令/数据 ready-valid 协议；存储器实现差异留在 wrapper。

## `tb/`

- `unit/`：当前 42 项，包含 MEM 结果拼包、六种 MDU 配置、8 位算法穷举与 SRT 组件验证。
- `core/`：18 项短程序流程，每种 XLEN 为 17 PASS、1 非适用位宽 SKIP；覆盖基础/M 指令、访存等待、MDU 前递与寄存边界、预测、CSR、Trap 和序列化取消。
- `soc/`：互连、ROM/TCM、外设、DMA、AXI4 单拍桥与外存模型 TB；SoC 镜像 harness、C 中断/DMA 程序及启动汇编。
- `cache/`：I$/旧 WT D$/WB D$ 各四配置单测、维护控制器两配置，以及 DDR 改码、DMA 交接与写回失败测试。
- `benchmark/`：运行 ELF 镜像的长程序 harness，被动镜像字符 Store 并监视 `tohost`。
- `common/rv_asm_pkg.sv`：为整核定向测试生成具名 32 位指令编码。
- `common/muldiv_checker.sv`：乘法、除法和统一 MDU 共用的独立算术/协议参考检查器。
  三种语义用例均通过唯一 MDU 握手壳，MODE 只筛选指令；原始算法另有穷举测试。
- `common/store_result_monitor.sv`：被动观察已握手 Store，仅由 TB 解释 PASS/FAIL。
- `riscv_tests/`：本地环境、链接脚本、仿真 harness，以及固定上游源码快照。

`tb/riscv_tests/vendor/riscv-tests/` 保存正式回归所需的 MI/UI/UM `.S`、宏、编码和
许可证；`env/` 保存本 CPU 的覆盖环境。根目录 `riscv-tests/` 仅供阅读对照。

## `scripts/`

- `rtl_files.f`：可综合 Core 的有序源码清单。
- `soc_files.f`：Core 清单加可移植 SoC、Cache、DMA、存储器及外设；`make soc-test XLEN=32/64` 验证基础设施。
- `verilator/run_cache.sh`：`make cache-test XLEN=32/64` 的 I$/D$ 专项入口。
- `sim_files.f`：在 Core 上加入 `sim_cpu`。
- `cpu_files.f`：在 Core 上加入 FPGA wrapper。
- `verilator/run_unit.sh`：遍历 `tb/unit/tb_*.sv`。
- `verilator/run_directed.sh`：遍历 `tb/core/tb_*.sv`。
- `verilator/run_riscv_tests.sh`：编译 vendored 汇编、生成镜像并运行 MI/UI/UM 回归。
- `verilator/run_mdu_backends.sh`：对六种 MDU 配置运行五个 M 整核测试与全部 UM 镜像。
- `verilator/build_benchmark_image.sh`：链接裸机 C/汇编并分离 IMem/DMem 镜像。
- `verilator/run_benchmark_smoke.sh`：验证启动、栈、数据段、硬件 M/宽整数辅助算术和计时。
- `verilator/run_coremark.sh`：校准迭代数并执行 CoreMark performance/validation。
- `verilator/verilog_hex_to_mem.py`：把 objcopy 字节镜像转换成 `$readmemh` 字宽。
- `vivado/*.tcl`：工程创建、综合、实现和烧录框架。

## `riscv-tests/`

若本地存在，该目录是独立 Git checkout，remote 指向
`riscv-software-src/riscv-tests`。它只用于阅读和比较，由父仓库整体忽略，不登记为
Git submodule，也不作为普通文件提交。父仓库的新 clone 不会自动得到该目录，但会
得到 `tb/riscv_tests/vendor/` 中正式运行所需的固定快照。

正式快照固定 riscv-tests `933a897` 和 env `6de71ed`，并保留两份许可证。所有 CPU
适配只允许进入 `tb/riscv_tests/env/` 或 runner；vendor 文件只在明确升级上游版本时
整体刷新。`RISCV_TESTS_DIR` 仍可用于临时比较另一份干净 checkout。

## `benchmark/`

- `bsp/`：`crt0.S`、链接布局、ECALL/`tohost` 退出、`mcycle` 读取、内存函数和
  不依赖 M 扩展的软件乘除 helper。
  当前默认用 IM 编译；RV32 的超 XLEN 算术仍可能需要这些 helper，不删除历史基础实现。
- `smoke/`：在跑分前验证 `.data/.bss`、栈、函数调用、宽整数算术和计数器。
- `coremark/vendor/coremark/`：固定且不修改的官方 `v1.01`（报告版本 1.0）源码。
- `coremark/port/`：本 Core 的 seeds、静态内存、计时和字符输出适配。

CoreMark 的 ELF、map、dump、镜像和日志均为生成物。vendor 的来源与许可证记录在
`benchmark/coremark/vendor/VENDORING.md`；平台修改不得进入上游源码目录。

## 生成目录

`build/verilator/` 保存 Verilator 生成的 C++、目标文件和 `Vtb_*` 可执行文件；
`build/riscv-tests/` 保存 ELF、map、反汇编和存储器镜像；`build/ccache/` 保存
C++ 编译缓存。`logs/` 保存每个测试的编译和运行输出。它们都不是工程真值，允许
由脚本重建，也可能保留已经改名模块的陈旧输出。

## 根目录文件

- `README.md`：项目状态、功能和文档入口。
- `Makefile`：统一的仿真和 Vivado 命令入口。
- `AGENTS.md`：注释、审阅、测试、分支和文档同步规则。
- `docs/PLATFORM_ADAPTATION.md`：Zynq-7020 与盘古 676-200K Pro 的共享契约和平台隔离。
- `.gitignore`：根级白名单，未列出的顶层内容默认忽略。
- `.gitattributes`：保留官方 CoreMark 快照原有的行尾格式，不影响其他项目文件检查。
- `LICENSE`：项目许可证。

阶段修改记录和协议/实现解读仅在协作仓库 `hgb-aisystem_riscv` 的
`docs/COMMIT.md` 与 `docs/understand/` 中维护，不复制回本硬件仓库。
