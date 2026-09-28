# SoC 访存接口契约

## 实现边界

Core 保持 IF/D1/D2/EX/MEM/WB 六级。`vsrc/soc/bus/` 提供物理地址检查和错误响应；
ROM、I/D-TCM、UART/Timer/GPIO、DMA 和机器中断已由 `soc_top` 集成。
DDR 窗口默认关闭并返回错误；配置 `DDR_BYTES` 后由可综合本地端口向外连接。
仿真通过独立 AXI4 单笔桥与可变延迟 RAM 接入，详见 [外存接入边界](SOC_EXTERNAL_MEMORY.md)。外设语义见 [SoC 外设接口](SOC_PERIPHERALS.md)。
Package 只保存常量、枚举和结构体；访问判断在模块内完成。

## 请求、完成与错误

- I/D 独立，各最多一笔已接受且未响应事务；消费旧响应的同拍可接收新请求。
- 请求在 `req_valid && req_ready` 上升沿接受后不得撤回或重复执行。
  IF 的未接受请求可因重定向撤回，因此需要 adapter 才能连接 AXI。
- 响应最早在请求接受后的周期有效。响应有效位、数据和错误保持到握手；
  Load 和 Store 都恰有一次响应，不允许零拍组合完成。
- MEM 发请求、WB 等完成；命中 Load 后无关指令仍连续推进，load-use 位置不变。
  WB 等待响应或响应产生 Trap 时，年轻 MEM 不得发出请求。
- `dmem_req_size` 指定 1/2/4/8 字节。返回数据按 XLEN 对齐字的字节通道排列，
  WB 根据原地址选择与扩展；写数据与 `wstrb` 按地址低位移位。
- `imem_rsp_error` 进入 IF 包，携带取指 PC，优先于返回数据的非法译码；
  `dmem_rsp_error` 在 WB 转为 Load/Store access fault，携带原访问地址到 Trap。
  WB 输出补充异常后的 `commit_packet`，异常指令不写 GPR/CSR。
- 未映射访问用 DECERR，权限/大小错误用 SLVERR。错误从设备也必须返回响应，
  不得用永久 ready=0 代替报错。AXI 桥接收 B/R 错误。
- 写错误不承诺回滚已产生的外部副作用；保证故障 PC/地址准确，并阻止年轻指令越过错误。

## 排序与复位

FENCE/FENCE.I 在 D1 序列化，清除年轻指令，等旧访存完成后在 WB 退休，
从顺序 PC 恢复取指。当前无写缓冲或 Cache，保守地执行完整排序。
FENCE.I 另清除 BTB/PHT 和待训练项，避免旧跳转被改成普通指令后仍沿旧预测取指。
已接受的错误路径取指响应必须排空并丢弃，其访问错误不能变成有效 Trap。

全系统复位清除 Core/本地响应状态，但不回滚 RAM 已发生的写入。
外存桥必须协调复位和外部在途事务，不能只复位 CPU 后遗忘已接受请求。

## 地址与访问属性

两种 XLEN 共用 32 位物理地址；RV64 高位不得静默截断。
以下容量为首版参数或地址预留，不代表已核实的板卡资源。

| 目标 | 起始地址 | 容量/窗口 |
|---|---:|---:|
| ROM | `0x0000_0000` | 16 KiB |
| I-TCM | `0x0100_0000` | 64 KiB |
| D-TCM | `0x0110_0000` | 64 KiB |
| Timer0 / mtime | `0x0200_0000` | 64 KiB |
| IRQ controller | `0x0C00_0000` | 4 MiB |
| UART0 / UART1 | `0x1000_0000` / `0x1000_1000` | 各 4 KiB |
| Timer1 | `0x1001_0000` | 4 KiB |
| GPIO0 / GPIO1 / GPIO2 | `0x1002_0000` / `0x1002_1000` / `0x1002_2000` | 各 4 KiB |
| DMA regs | `0x1003_0000` | 4 KiB |
| SoC regs | `0x1004_0000` | 4 KiB |
| DDR | `0x8000_0000` | `DDR_BYTES` 配置容量，默认 0；仿真用 64 KiB |

`address_decode.DDR_BYTES` 默认 0（关闭），启用时按实际容量配置。
I/D-TCM 各自所在 1 MiB 区域留作扩展，超出已实现容量的访问报错，不回绕。
各目标自行检查已实现的寄存器偏移。

ROM 为只读可执行，I-TCM 可读写可执行，D-TCM 可读写不可执行。
普通 MMIO 只接受对齐 32 位访问且不可执行，不把 RV64 LD 拆成两次有副作用的读取。
机器 Timer 单独保留 RV64 原子 64 位访问；RV32 使用两个 32 位半字。

## ROM、TCM 与互连模块

`bus_interconnect` 可配置主端口数量；SoC 实例为 CPU I、CPU D、DMA 三路，各自最多一笔在途事务。不同目标可并行；
同目标轮询仲裁，响应根据接受请求时记录的 owner 返回。
从端反压期间保持选择；IF 撤回尚未接受的请求后释放选择。
`PRESENT` 默认只启用错误端、ROM、I-TCM 和 D-TCM；SoC 实例显式启用已实现外设。
CPU D 相对 I 优先，同时与 DMA 公平轮询；跨 owner 一拍交接，SoC 保存被 IF 反压的响应，
使取指撤回、数据 ready 和重定向之间不形成组合反馈；默认通用互连仍采用轮询。

`tcm_controller` 是单端口同步读、逐字节写的 XLEN 宽 RAM bank。
I/D-TCM 是两个独立 bank，而非两份不相干的指令/数据镜像：两主端口可访问同一 bank。
响应可保持，消费旧响应的同拍能接受新请求；复位只清协议状态，不清 RAM。
实例容量须与地址译码一致。当前模块结构面向 BRAM 推断，尚无厂商综合结果。

`boot_rom` 提供从复位地址 0 跳转到 `0x0100_0000` 的两条指令，剩余内容为 NOP。
它不是镜像下载器；TCM 初始化由仿真加载或平台初始化提供。
`soc_top` 已连接 Core；benchmark 使用 I-TCM 代码、D-TCM 数据的专用链接布局。

## 验证

`make soc-test XLEN=32/64` 运行互连两种仲裁配置、外设和 DMA/AXI 集成 TB，覆盖共享 TCM、
字节写、ROM 子字访问、目标缺失、响应归属/反压、跨 bank 并行、同 bank 公平仲裁、
一拍 RAM 连续吞吐、未接受请求撤回，以及复位后 RAM 内容保留。
另覆盖 UART 环回、计时器、GPIO、IRQ claim/complete 与 MMIO 副作用。
该命令不运行 CoreMark，也不代替 Core 回归、`make soc-software` 的 C 中断测试或
`make soc-dma-software` 的 CPU→DMA→TCM/外存端到端测试。

`make test XLEN=32/64` 包含以下测试：

- `tb_soc_bus_contract`：地址边界、权限、RV64 高位、MMIO 大小、错误响应反压。
- `tb_core_bus_contract`：延迟 Store、三类 access fault、阻止年轻副作用、
  FENCE 排序，以及真正训练旧 BTB 后修改代码并执行 FENCE.I。
- IF/D1/WB/模拟 RAM 单元：错误继承、取消迟到错误、写响应与字节写。
- 原有连续 Load、load-use、MDU 前递/取消和 EX/MEM 边界回归。

旧 `sim_cpu_top` 仍是分离的 I/D 测试存储器，因此标准 riscv-tests 的 `fence_i`
在该 runner 中仍 SKIP。新整核定向测试使用同一字节存储器检查 FENCE.I；
`make soc-riscv-tests` 已启用上游 `fence_i`，并只跳过 `ma_data`。

CoreMark 用相同编译选项、后端及固定迭代数比较，必须校验 performance/validation CRC；
跑分不能代替错误响应和 MMIO 副作用测试。
