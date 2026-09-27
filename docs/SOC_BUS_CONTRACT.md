# SoC 访存接口契约

## 实现边界

Core 保持 IF/D1/D2/EX/MEM/WB 六级。`vsrc/soc/bus/` 提供物理地址检查和错误响应；
TCM、SoC 顶层、外设、中断和 DDR 桥尚未接入。地址已分配不代表目标已经实现。
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
  不得用永久 ready=0 代替报错。未来 AXI 桥必须接收 B/R 错误。
- 写错误不承诺回滚已产生的外部副作用；保证故障 PC/地址准确，并阻止年轻指令越过错误。

## 排序与复位

FENCE/FENCE.I 在 D1 序列化，清除年轻指令，等旧访存完成后在 WB 退休，
从顺序 PC 恢复取指。当前无写缓冲或 Cache，保守地执行完整排序。
FENCE.I 另清除 BTB/PHT 和待训练项，避免旧跳转被改成普通指令后仍沿旧预测取指。
已接受的错误路径取指响应必须排空并丢弃，其访问错误不能变成有效 Trap。

全系统复位清除 Core/本地响应状态，但不回滚 RAM 已发生的写入。
后续外存桥必须协调复位和外部在途事务，不能只复位 CPU 后遗忘已接受请求。

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
| DDR | `0x8000_0000` | 预留 512 MiB |

`address_decode.DDR_BYTES` 默认 0（关闭），启用时按实际容量配置。
I/D-TCM 各自所在 1 MiB 区域留作扩展，超出已实现容量的访问报错，不回绕。
各目标自行检查已实现的寄存器偏移。

ROM 为只读可执行，I-TCM 可读写可执行，D-TCM 可读写不可执行。
普通 MMIO 只接受对齐 32 位访问且不可执行，不把 RV64 LD 拆成两次有副作用的读取。
机器 Timer 单独保留 RV64 原子 64 位访问；RV32 使用两个 32 位半字。

## 验证

`make test XLEN=32/64` 包含以下测试：

- `tb_soc_bus_contract`：地址边界、权限、RV64 高位、MMIO 大小、错误响应反压。
- `tb_core_bus_contract`：延迟 Store、三类 access fault、阻止年轻副作用、
  FENCE 排序，以及真正训练旧 BTB 后修改代码并执行 FENCE.I。
- IF/D1/WB/模拟 RAM 单元：错误继承、取消迟到错误、写响应与字节写。
- 原有连续 Load、load-use、MDU 前递/取消和 EX/MEM 边界回归。

旧 `sim_cpu_top` 仍是分离的 I/D 测试存储器，因此标准 riscv-tests 的 `fence_i`
在该 runner 中仍 SKIP。新整核定向测试使用同一字节存储器检查 FENCE.I；
统一 TCM/SoC harness 接入后再启用上游自修改代码用例。

CoreMark 用相同编译选项、后端及固定迭代数比较，必须校验 performance/validation CRC；
跑分不能代替错误响应和 MMIO 副作用测试。
