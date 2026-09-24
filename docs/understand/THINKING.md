# Cache、TCM、DMA 与系统总线：设计草案

> 2026-09-25；仅供架构评审。当前 RTL 尚无 Cache、TCM、DMA 或系统互连，两块板均未上板。

## 设计边界

现有 Core 的 IMem/DMem 是两条独立的 ready/valid 请求—响应接口：取指响应为 32 位，数据宽度随 XLEN 变化。当前单发射、顺序执行实现适合先保留“每端口最多一条在途请求”，由 SoC 层做地址路由和等待；不要把 AXI 五通道或厂商 BRAM 端口直接塞进流水级。尤其要先复核 Store：当前 MEM 侧以请求被接受作为完成条件，而 AXI 写入还有 B 响应；若要报告写错误、保证 MMIO 副作用顺序或精确异常，必须重新定义完成/提交边界，不能把 B 响应忽略。访存错误、DMA 中断等入口是未来接口变更，不是现有能力。

建议的物理地址路径（地址及容量均待板卡资料和链接布局确定）：

```text
Core IF ── I 路由 ── I-TCM ───────────────┐
                    └─ I$ ── miss/refill ─┤
Core LSU ─ D 路由 ── D-TCM ───────────────┤── system interconnect ─ DDR/ROM/MMIO
                    ├─ D$ ── miss/evict ──┤
                    └─ uncached MMIO ─────┤
CPU MMIO ── DMA 控制寄存器（从设备）          │
DMA 数据引擎（主设备）──────────────────────┘── TCM 仲裁入口
```

I-TCM/D-TCM 是软件显式放置的片上存储区，按地址绕过 Cache；Cache 只处理标为可缓存的外部 RAM，MMIO 永远走非缓存路径。先做物理地址译码；未来若加入 MMU，应在翻译后依物理地址属性选择路径。保留独立 I/D 路口，并通过统一地址映射使 CPU、DMA 与链接脚本看到同一存储区。

## 为什么先 TCM、后 Cache

Cache hit 可以很快；使执行时间起伏的主要是 miss、替换及共享互连争用。TCM 可使重复运行的关键代码/数据避开随机 miss。把启动代码、热点、栈或 benchmark 工作集通过链接段分别放入 I-TCM/D-TCM，并固定镜像、时钟、迭代数与 DMA 活动，才能比较可重复的周期数。TCM 并非“天然固定延迟”：同一 BRAM 端口若与 DMA 争用，CPU 仍会等待。优先考虑 CPU 与 DMA 分端口的双端口 RAM，或显式优先级/时隙仲裁；同地址读写的结果须以实际 IP 文档和仿真确认。DDR 控制器刷新与总线仲裁也使外存路径不具同等确定性。

建议实现顺序：先无 Cache 的 I/D-TCM、ROM、MMIO 地址路由与可等待外存模型；再接 DMA 到 TCM/外存并验证仲裁；然后加入阻塞式 I$/D$（一次 miss、line refill、D$ 写回/写分配策略由评审固定），最后量化 miss、替换、容量和带宽。Cache miss 只通过现有 ready/valid 反压，不应改变 ISA 提交语义。首版不引入 XiangShan 式多 MSHR、乱序、预取或多级一致性协议；参考其模块边界、uncached 路径与验证方法即可。

## 总线与通信协议

参考 Chipyard 将缓存/内存、控制外设和 DMA 区分为不同连接与地址区域的思路；但 Chipyard 内部主要是 TileLink/Diplomacy，不能把它说成现成 AXI4 RTL。香山也区分 Cache、Uncache 与外部接口，不宜直接复制其复杂实现。建议 Core/TCM/首版 Cache 继续用本项目 typed request/response；系统互连做译码、仲裁、保持、响应路由及错误返回，在外存和需要兼容厂商 IP 的边界设置 AXI4 bridge。小型 UART、Timer、GPIO、DMA 控制寄存器可先用单拍 MMIO 从设备，必要时桥接 AXI4-Lite；DDR 与 DMA 大块传输采用 AXI4 burst。

建议的挂载关系（均为规划，地址表、数据宽度与时钟域待定）：

| 发起方或目标 | 连接与作用 | 首版协议边界 |
|---|---|---|
| CPU IF、LSU | 两个独立主端口；请求和响应各自保持至握手 | 现有 typed ready/valid |
| I-TCM、D-TCM | CPU 本地访问；DMA 走受仲裁的全局窗口 | BRAM adapter + 本地请求/响应 |
| I$、D$ | 只覆盖可缓存外存；miss/refill/evict 进互连 | CPU 侧 ready/valid，外侧桥接 AXI4 |
| Boot ROM | 复位程序、不可写 | 本地只读从端口 |
| UART、Timer、GPIO、DMA 寄存器 | 软件可见 MMIO；Timer/设备可产生 IRQ | 单拍非缓存从端口，可桥接 AXI4-Lite |
| DMA 数据引擎 | 读源/写目的，访问 TCM 或外存 | 独立主端口；外存桥接 AXI4 burst |
| DDR 控制器 | 大容量程序/数据区 | 首选 AXI4 bridge，按实际 IP 验证 |
| IRQ 控制器 | 汇集 Timer/DMA/外设中断到 CPU | MMIO 配置 + 中断线，后续实现 |

AXI4 有 AW/W/B、AR/R 五个独立 ready/valid 通道。必须规定主设备 ID、未完成事务上限、burst 边界、窄写 strobe、读写响应与复位排空；首版可各主设备限一条在途以降低验证规模。AXI4 本身不是 CPU Cache 与 DMA 的一致性协议，不因连接了 AXI 就自动 coherent。

## DMA 与一致性

DMA 对软件暴露 MMIO 描述符/寄存器（源、目的、长度、启动、状态、错误），对系统互连暴露读写主端口，对 I/D-TCM 暴露受仲裁的存储访问端口。首版可轮询完成；以后 Timer/IRQ 控制器和 M-mode 异步中断就绪后再加 DMA IRQ。软件须先完成生产者写入，再启动 DMA；DMA 完成后先确认状态，再消费结果。具体内存屏障、缓存维护和设备顺序应与后续实现的内存属性/总线完成语义一起验证。

首版避免硬件一致性：DMA 缓冲放 uncached D-TCM 或 uncached 外存区；若以后放入 D$ 可缓存 DDR，必须有写回/失效等软件维护机制（例如计划中的 Zicbom），或另行设计一致性互连。DMA 装载 I-TCM/可执行内存后，CPU 不可直接假定新指令可见：须定义加载完成、取指刷新和 `FENCE.I` 路径；当前 `fence_i` 测试尚跳过。这是引入可写指令存储后需要补齐的正确性条件。

+## 计划中的代码边界（目录尚未创建）

- `vsrc/pkg/`：定义本地请求/响应、地址属性、错误和将来的 AXI bridge 参数类型。
- `vsrc/core/`：维持现有流水和接口，不直接实例化 BRAM、DDR、UART 或总线 IP。
- `vsrc/cpu/soc/`：放可移植地址路由、阻塞式 Cache 控制、TCM 仲裁、
  DMA、MMIO 外设和系统互连；同一 RTL 用于 Verilator 与两种 FPGA。
- `vsrc/cpu/platform/pango676/`、`zynq7020/`：各自实现 RAM/IP、时钟复位和
  对外协议桥接；`ip/`、`constr/`、`scripts/` 按平台保存配置与可重建工程。
- `tb/unit/` 与未来 `tb/soc/`：分别验证协议部件和 CPU–DMA–TCM/Cache 的端到端时序。
  实现时同步 `scripts/rtl_files.f` 与测试入口。


## 双平台与验证门槛

优先盘古 676-200K Pro：先取得该板卡准确器件/封装、原理图、PDS 版本、BRAM/双端口行为、DDR IP 的用户侧协议、时钟复位和 UART 引脚资料；不得仅凭产品系列就断言板上 DDR IP 是 AXI4。共享 RTL 不实例化厂商原语，厂商桥接、IP、约束置于平台层。随后适配 Zynq-7020，保留既有 Vivado Tcl；若使用 Zynq 的 PS DDR，PL 访问需经 PS–PL HP/GP/ACP 等接口并满足 PS 时钟/复位/初始化条件，不能同时宣称“完全不使用 PS”且直接访问其 DDR。纯 PL 首版可先只用 PL BRAM/TCM，DDR 方案另审。

验证按路径推进：路由/TCM 读写与 DMA 冲突 → MMIO 不重复副作用 → Cache hit/miss、替换、脏块回写和反压 → DMA 与缓存维护 → RV32/RV64 riscv-tests/CoreMark → 两板综合、时序和上板。每一步都加入随机延迟、重置、错误响应、跨边界/非对齐和指令重定向测试。CoreMark 报告需注明代码/数据位于 TCM 还是 Cache/DDR；两种布局分开计分，不与旧仿真直连内存成绩混称。

## 资料依据

- [Chipyard TileLink/Diplomacy](https://chipyard.readthedocs.io/en/stable/TileLink-Diplomacy-Reference/index.html)、[Memory Hierarchy](https://chipyard.readthedocs.io/en/1.10.0/Customization/Memory-Hierarchy.html)
- [香山 Memory Subsystem](https://docs.xiangshan.cc/projects/user-guide/en/kunminghu-v3/memory-subsystem/)、[Uncache](https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/memblock/LSU/Uncache/)
- [Arm AMBA AXI/ACE 规范](https://developer.arm.com/documentation/ihi0022/latest)
- [RISC-V Zifencei 规范](https://docs.riscv.org/reference/isa/unpriv/zifencei.html)
- [紫光同创 Logos-2 产品资料](https://www.pangomicro.com/product/logos_family/195.html)、[AMD Zynq-7000 PS–PL 接口](https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM/PS-PL-AXI-Interfaces)
