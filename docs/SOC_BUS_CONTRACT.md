# SoC 访存接口契约

本文以 s5/cache-up 的源码为参照；切换到较早分支时请先读 [分支文档说明](README.md)，判断该分支实际实例化的模块。

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
从顺序 PC 恢复取指。普通 FENCE 只保证顺序，不要求写回脏行。
SoC 在 FENCE.I 退休同拍阻止新取指，完成全 D$ clean 后恢复；失败则停取指直到复位。
Core 输出退休事件 `fence_i_commit`：FENCE.I 清除 I$ valid、BTB/PHT 和待训练项，避免旧跳转被改成普通指令后仍沿旧预测取指。
已接受的错误路径取指响应必须排空并丢弃，其访问错误不能变成有效 Trap。

全系统复位清除 Core/本地响应状态，但不回滚 RAM 已发生的写入。
外存桥必须协调复位和外部在途事务，不能只复位 CPU 后遗忘已接受请求。
复位会清 D$ valid/dirty；若需保存已退休 Store，必须在复位前成功 flush。

## DDR 指令缓存

`soc_top` 默认启用两路阻塞式 I$，参数 `ICACHE_ENABLE=1`、
`ICACHE_BYTES=4096`、`ICACHE_LINE_BYTES=32`。只有原始 XLEN 地址合法且整行
位于已实现 DDR 的取指请求可缓存；其余请求旁路原译码，权限和地址错误不变。
D 口已接两路 D$，DMA 仍直连互连；没有硬件自动一致性。

同步数据 RAM 接受请求后读出，LOOKUP 再寄存响应：命中跨两个上升沿，
响应可保持，首版不在缓存响应消费同拍接受下一请求。旁路仍支持同拍交接。
原 I 响应缓冲移入 `cache_port`，下层 rsp_ready 恒为 1，避免组合反馈环。

RV32/RV64 都按 4 B 逐笔填充 32 B 行；全部成功才安装 tag/valid。
任意填行错误只触发一次原始请求回退，以它的响应决定精确异常。
FENCE.I 同拍清 valid，并粘滞禁止旧填行安装；旧事务仍排空、向 IF 回应一次，
由 IF kill 丢弃。普通 FENCE/分支重定向不触发整缓存失效。

## DDR 数据缓存与软件维护

D$ 默认参数为 `DCACHE_ENABLE=1`、`DCACHE_BYTES=4096`、
`DCACHE_LINE_BYTES=32`。只缓存合法 DDR 数据访问，TCM/MMIO/区域尾部不足整行
仍按原请求旁路。RAM 按 XLEN 组织：32 B 行为 RV32 的 8 笔或 RV64 的 4 笔。
读 miss 填行；读 hit 返回完整对齐总线字，由原 Load 单元完成 lane/符号扩展。
读填行失败，按原始地址与 size 回退一次，避免把扩宽读取错误误归给窄读。

Store hit 按 byte strobe 修改缓存并置 dirty，不访问 DDR；Store miss 先读完整行再合并。
零 strobe 为无副作用操作。所有 Store 都保留一次 CPU 响应；写回模式的完成不代表 DDR 已更新。
脏 victim 逐 XLEN 字写回，整行成功才清 dirty/替换；任何 beat 错误均保留原 valid/dirty/data。
写分配读失败则不安装部分行，只回退一次原 Store，按其真实写响应决定成功或 access fault。

替换时写回失败使**当前触发替换的访问**收到错误；架构 mtval 仍是当前请求地址，
不是事后给较早退休 Store 精确报错。SoC 状态另存真实写回故障地址；数据仍可重试发布。
无机器检查/异步总线异常协议。FENCE.I 自动 clean 失败采用 fail-stop，不伪装成功或继续执行旧代码。

系统寄存器 `0x10040020` 写 1/2/3 为全局 invalidate/clean/flush，见
[寄存器说明](SOC_PERIPHERALS.md)。MMIO 响应仅确认入队；必须查看状态，不能把入队当完成。
维护等待旧 CPU 响应排空，然后借 D 主端口工作，不取消任何已接受事务。
维护占用期间新 D 请求会被反压，包括状态读；当前是阻塞式实现，不保证软件超时可打断坏从端。

invalidate 拒绝脏行并报错；clean 保留有效行；flush 成功发布脏数据再失效。
失败允许已处理的行生效，未完成部分保持可重试，不承诺全缓存原子回滚。

DMA 绕过缓存：CPU→DMA 先 clean/flush 并确认成功；交出 DMA 目的区前先 flush，
DMA DONE/ERROR 后 invalidate 并确认成功再读取。DMA 期间不能访问交接行，
也不要新建其他 DDR 脏行干扰全局 invalidate；TCM 代码/栈适合本阶段维护流程。
错误 DMA 可能部分完成，维护步骤不能省略。DMA 写代码后还须 FENCE.I。
没有硬件 snoop、固定 uncached pool 或 cached/uncached 别名；TCM/MMIO 始终旁路。

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


## 接口从 Core 到外存的层次

Core 有两组独立的本地请求/响应线：I 口发送 PC，只读 32 位指令；D 口发送地址、访问大小、写数据和字节使能。两组线不附带事务 ID，因此各自最多有一笔已接受而尚未消费响应的事务。soc_top 把它们分别包装成 bus_req_t，前往 I$ 和 D$。只有通过完整地址与权限检查、整行位于已启用 DDR 的访问才进入 Cache；ROM、TCM、MMIO 以及 DDR 尾部不足整行的访问保持旁路。

| 位置 | 请求方 | 接收方 | 接口里要跟踪的内容 |
|---|---|---|---|
| Core I 口 | if_stage | icache/cache_port | PC、取指有效位、请求接受沿；返回 32 位指令与错误 |
| Core D 口 | mem_stage | dcache/cache_port | XLEN 地址、1/2/4/8 字节大小、wdata、wstrb、读写；WB 接收响应 |
| 互连主端口 0/1/2 | I$、D$、DMA | bus_interconnect | 完整 bus_req_t；主端口各一笔在途 |
| 互连从端口 0..14 | bus_interconnect | ROM、TCM、外设、DDR | 请求选路、接受时的 owner、响应反压 |
| SoC 外存端口 | 从端口 14 | 外部桥或平台适配 | ddr_req/rsp ready-valid，仍是本地协议 |

bus_req_t 的 write、execute、size、addr、wdata、wstrb 是同一次请求的载荷；bus_rsp_t 只有对齐 XLEN 宽 rdata 与 BUS_OK/DECERR/SLVERR。valid/ready 在结构体之外。这里的地址始终保持 XLEN 宽，地址译码再检查 32 位物理空间；RV64 高位非零的访问不能仅截低 32 位后命中设备。DDR_BYTES=0 时从端口 14 不对外发请求，相关访问走错误从端口。DDR_BYTES>0 仅打开窗口；外部控制器、PHY 和实际 DDR 仍需平台提供。

读源码可沿 [soc_top](../vsrc/soc/soc_top.sv) → [cache_port](../vsrc/soc/cache/cache_port.sv) → [bus_interconnect](../vsrc/soc/bus/bus_interconnect.sv) → [address_decode](../vsrc/soc/bus/address_decode.sv) 走一遍。设备实例和中断线在 [外设连接说明](SOC_PERIPHERALS.md)。

## 一笔请求在时钟上的位置

以下 E0、E1 是上升沿，不是“等待一拍”的固定性能承诺。以同步 TCM 且响应端已经准备好为例：

| 时刻 | I 口 | D 口 |
|---|---|---|
| E0 前 | IF 给出 req_valid/PC；接受方给出 req_ready | MEM 给出 req_valid、地址、size 和写掩码 |
| E0 | 两边均为 1 才接受；IF 保存这次请求的 PC 与预测快照 | MEM 请求被接受，访问元数据可进入 MEM/WB |
| E0 后 | 从端完成同步读取并寄存响应；RV64 取指 lane 用 E0 锁存的地址 | Load/Store 的 rsp_valid 才表示返回或写完成 |
| E1 | IF 与响应握手；D1 能接收就直通，否则进入 IF buffer | WB 与响应握手；Load 选择字节/符号扩展，Store 确认完成 |
| 更长延迟 | I$ 缺失或外存等待时，IF 保留请求归属 | D$ 缺失或外存等待时，WB 保留旧指令，年轻流水停住 |

req_ready 只表示本级接受请求。Store 的写响应可以晚很多拍；写回 D$ 的 Store 响应又只表示新值已保存在脏行。rsp_valid=1 而 rsp_ready=0 时，响应的值与错误必须保持。已接受的请求不能因为 IF 改变 PC 或 D 口进入等待而重新发射。允许旧响应被消费与新请求同沿交接的地方会同时更新 owner；阻塞 Cache 命中路径没有承诺这种连续吞吐。

例子：RV64 向基址加 4 执行 SW。MEM 的 wdata 放在 XLEN 数据总线高 32 位，wstrb 选中高四个字节；一次 LW 返回包含该八字节对齐字的 XLEN rdata，WB 再按地址低位选出高半字并按指令做符号扩展。RV64 取指同样可能在八字节字的高 32 位，因此 soc_top 的 fetch_lane_q 必须在请求接受沿记录 lane；用响应返回时正在变化的 PC 选 lane 会拿错指令。

## 反压、撤回和响应归属

IF 能撤回尚未被互连接受的错误路径请求。若请求已接受，重定向只标记该响应为旧路径；响应仍要被接收并排空，不能进入 D1，也不能产生旧路径的取指异常。if_stage 的 request_q、request_killed_q、buffer_q 分别保存已接受请求、杀死标记和已返回而未交给 D1 的包。I 口旁路处还有一个响应缓冲，用于切断共享 bank 到 IF 的组合反压。

互连按目标分别保存 busy 和 owner。响应回到请求接受沿记录的 owner，不能用响应当拍的地址再译码。两个不同 TCM bank 可以并行；多个主端访问同一 bank 时仲裁。SoC 实例使能 DATA_PRIORITY：CPU D 相对 CPU I 优先，同时通过轮转让 DMA 获得同目标机会；CPU I 与别的 owner 交接隔一拍，以免 IF 可撤回的 valid 与 D-ready 形成组合环。通用互连的默认配置和 SoC 实例配置需要分开看。从端反压时互连锁住已选主端，直到请求被接受或允许的 IF 撤回发生。

## 从总线错误到架构异常

address_decode 用 65 位扩展地址和访问末端检查整个访问范围。未映射、32 位物理空间外或未实例化的目标返回 DECERR；已命中目标但大小、对齐、执行/写权限不合法返回 SLVERR。错误从端也要给出一次响应，不能永远保持 req_ready=0。外设再检查寄存器偏移及写权限；不合法的寄存器访问返回 SLVERR。外部 AXI 桥把 R/B 通道错误带回本地响应。

IF 将取指错误与请求 PC 一起带入流水。D 口错误在 WB 根据当前有效 Load/Store 转换为 access fault，mtval 为该指令的原始有效地址；出现早期异常时不会再发出这笔 D 请求。WB 未等到要求的响应就保持等待，不能让年轻 MEM 访问越过老指令。写响应报错不撤销已由外设或前几个 DMA beat 产生的副作用。写回缓存逐出失败属于当前触发替换的访问错误，真实故障 victim beat 地址另记在 SoC 状态寄存器。

## Cache、DMA 与指令可见性

普通 FENCE 排空较老访存，不要求写回 D$ 脏行。FENCE.I 在 WB 正常退休时清 I$ 与预测状态；SoC 在同一事件阻止新取指，等待 D$ 全 clean 成功后再放行。旧 I 响应依然要排空。自动 clean 失败时取指持续停止，直到系统复位；当前没有异步机器检查恢复通道。

DMA 是互连的第三主端，不经过 CPU 的 D$。CPU 向 DMA 提供 DDR 源数据之前应 clean/flush 并确认成功；DMA 将写 DDR 目的区之前，应先 flush 该区已有脏数据；DMA DONE/ERROR 后 invalidate 并确认成功再由 CPU 读取。当前维护扫描整个 D$，不是按地址的 CMO。DMA 改写可执行代码后还要 FENCE.I。维护命令的 MMIO 写响应只确认入队，完成与错误在 SoC 状态寄存器检查；维护与该 MMIO 请求共用 D 主端口，因此不可能扣住原写响应等待 clean 完成。

## 复位与验证边界

复位清 Core、互连及 Cache 的在途控制状态，TCM 数据 RAM 不清零。D$ 的 valid/dirty 会清除；若需保存已退休 Store 的脏数据，复位前须成功 flush。已发送到外部 AXI 的事务需要桥、互连和从端协调复位，仅复位 Core 不具备回滚能力。当前没有实板 DDR3/PHY 时序数据，仿真 RAM 的延迟不代表板级性能。

建议按故障范围选择入口：接口和反压用 make test XLEN=32/64 中的 tb_soc_bus_contract、tb_core_bus_contract；仲裁、MMIO、副作用用 make soc-test XLEN=32/64；缓存状态、DMA 交接、FENCE.I 用 make cache-test XLEN=32/64；完整软件中断与 ISA 行为分别用 make soc-software、make soc-riscv-tests。修改接口字段时同时检查两种 XLEN、高位地址、错误返回、保持响应及复位中的旧事务。

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
