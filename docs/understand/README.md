# 理解与学习文档

本目录按“先掌握 Core 中发生什么，再接 SoC 的真实设备，最后沿源码验证”组织。理论文档描述当前 `SOC/all` 中的 S5 实现；历史阶段的语义见 [源码范围](../README.md)。hgb 旧阶段分支删除后仍可从提交读取，rhbyv 保留阶段分支供切换学习。

## 进入 SoC 前

| 顺序 | 读什么 | 读完应能回答 |
|---|---|---|
| M 扩展 | [六级流水中的 M 扩展](M_EXTENSION.md) | 请求何时被 EX 接受；EX/MEM 元数据如何与 MEM 结果会合；较老 Trap 怎样取消年轻运算 |
| CSR、异常和中断 | [CSR、同步异常与机器中断](CSR_TRAPS_AND_INTERRUPTS.md) | D1/EX/WB 分别发现什么；ECALL/EBREAK/MRET 如何走 WB；mip、mie、mstatus 如何共同决定中断 |
| I/D 存储器接口 | [Core、BRAM 与 Cache 握手](MEMORY_HANDSHAKE.md) | req_ready 与 rsp_valid 各表示什么；IF buffer、Load-use、wb_wait 和 Cache miss 怎么区分 |

M 模块位于 Core 的 execute/M_extension，算法后端内的寄存器不算新主流水级。先沿 ex_mdu → muldiv_unit → mem_mdu 查一次握手，再查看乘法/除法算法；这样不会把后端的内部延迟误画成第七级流水线。CSR 学习建议从一条 ECALL 和一次设备 IRQ 分别走到 WB，观察故障 PC、实际后继 PC、mepc 和 MINSTRET。I/D 握手建议同时查看 tb_if_stage 和 tb_core_bus_contract：一个解释旧取指的 kill，另一个解释 Store 在 WB 等真实响应。

已经修过的错误另有 [IRQ 撤销与 MINSTRET 修复](CPU_IRQ_COUNTER_FIX.md)。它记录：早期 irq_pending 清 IF 可能跳指令，固定 pc+4 会在已退休跳转后保存错中断恢复点，MINSTRET 隐式自增不能像普通 CSR 一样直接前递，RV32 写半字也不能先增整个计数器。读当前行为以新 CSR 文档和源码为准；历史记录用于理解为什么测试要覆盖这些边界。

## SoC 的理论：当前硬件有哪几层

先看 [正式访存契约](../SOC_BUS_CONTRACT.md) 的本地 bus_req_t、完整物理地址检查、请求接受沿、响应保持与错误分类。随后看 [外设连接图和寄存器](../SOC_PERIPHERALS.md)：三主端口、十五个从端下标、UART/Timer/GPIO/DMA/IRQ 与 Core 的连接在那里。它们是修改 RTL 时要维持的接口，不是性能宣传材料。

| 问题 | 对应读物 | 当前边界 |
|---|---|---|
| ROM、TCM、DMA 如何共享地址和仲裁 | [无 Cache SoC 与中断](SOC_AND_INTERRUPTS.md)、[仲裁与一致性](ARBITRATION_AND_COHERENCE.md) | I/D-TCM 为共享物理 bank；DMA 是第三主端，设备状态需由软件清除 |
| 物理 DDR 接在什么位置 | [外存与 DMA 接入](../SOC_EXTERNAL_MEMORY.md)、[AXI 模型与真实 DDR3](AXI_DDR_BOUNDARY.md) | 本地端口可综合；AXI 桥单 beat；仿真 RAM 不是厂商 DDR3 控制器/PHY |
| I$ 取指与 FENCE.I | [两路 I$ 握手](ICACHE_IMPLEMENTATION.md) | 只缓存合法 DDR 取指，旧请求排空，预测状态随 FENCE.I 清除 |
| D$ Store 与 DMA 数据交接 | [S5 写回/写分配](S5_CACHE_WRITEBACK.md) | WB/WA，脏逐出写回；软件执行 clean/flush/invalidate 并检查完成状态 |
| 测试程序如何结束 | [软件测试栈](SOFTWARE_TEST_STACK_GUIDE.md) | ECALL/Trap、链接脚本、PASS/FAIL 设备或 tohost 取决于具体 runner |
| 如何理解 CoreMark 数字 | [CoreMark 与性能](COREMARK_AND_PERFORMANCE.md) | 已有 TCM/Core-only 周期成绩；没有 DDR3 板级时序结论 |

S4 的 WT/NWA [D$ 写穿透实现](DCACHE_IMPLEMENTATION.md) 与 [S4 设计复核](S4_CACHE_DESIGN.md) 保留作为历史比较。S5 的 Store 可以先退休而 DDR 仍是旧值；判断 DMA 能否读到 CPU 最新数据，应读 S5 的维护契约。普通 FENCE、FENCE.I、DMA DONE 和 D$ 维护分别有不同职责，见上述正式契约与写回解读。

## SoC 的实践：阶段提交对应哪些源码

| 阶段 | rhbyv 学习分支 / hgb 历史提交 | 优先看哪些源码和测试 |
|---|---|---|
| Core + M | main / `9427fe5` | core.sv、ex_mdu、csr_file、if_stage、mem_stage；make test、make riscv-tests |
| S2 ROM、TCM、MMIO、IRQ | SOC/tmc-mmio / `de67bbb` | soc_top、address_decode、tcm_controller、soc_peripherals、irq_controller；tb_soc_fabric、tb_soc_peripherals、soc-software |
| S3 AXI 早期检查点 | hgb `a2f7726` | local_to_axi、tb_local_to_axi；当时没有完整 DMA |
| S3 完整 DMA | soc/s3-axi-dma / `f714fba` | dma_controller/engine/regs、tb_dma_fabric、dma_smoke.c；soc-dma-software |
| S4 缓存首版 | s4/cache / `4f0ddcb` | icache、旧 dcache、tb_icache、tb_dcache；WT/NWA 与全失效 |
| S5 写回升级 | s5/cache-up / `909ac2d` | dcache_meta_array、cache_writeback、cache_maintenance_controller、tb_dcache_wb；WB/WA 与 FENCE.I clean |

按文件走的一次实操见 [从分支差异读 SoC 源码](SOC_SOURCE_WALKTHROUGH.md)。其中分别跟 CPU 访问 MMIO、DMA 从配置寄存器成为第三主端、DDR Cache 缺失与中断清除。遇到“代码和文档说法不同”，先确认当前 Git 分支或历史提交，再看对应的 soc_top 实例和 source list；后期写成的文档可能包含该阶段尚未实现的功能。

## 按现象找入口

- 取指 PC 已被接受，迟迟不出 D1：读 if_stage 的 request_q/buffer_q，接着看 icache、cache_port 和互连的 m0 owner；若中途 redirect，核对旧响应排空。
- Load/Store 请求已接受却未退休：看 MEM/WB 包、wb_wait、D$ response、总线错误以及外设响应保持；Store 还要看 wstrb 与 XLEN lane。
- 某个外设地址报错：先看 soc_addr_pkg 与 address_decode 的完整范围和访问大小，然后查对应 s 下标和设备内部寄存器偏移。DECERR 与 SLVERR 分属不同边界。
- IRQ 不来或不断重进：从设备 STATUS 电平、IRQ controller 的 PRIORITY/ENABLE/THRESHOLD，到 mip/mie/mstatus，最后看 handler 是否先清设备原因再 COMPLETE。
- DMA 读到旧数据：核对 CPU 源数据是否先 clean、目的区是否在 DMA 前 flush、DONE/ERROR 后是否 invalidate；再看缓存维护状态，不以 MMIO 命令写响应代表完成。
- FENCE.I 后仍执行旧指令：看该事件是否正常退休、I$ 是否失效、D$ 自动 clean 是否完成，以及 IF 旧响应是否被 kill。写回故障会停取指，不能靠软件继续执行旧代码来“恢复”。

## 修改与验证

改一个设备时同时检查地址常量、目标编码、互连 PRESENT、soc_top 或 soc_peripherals 的从端连线、寄存器语义、IRQ 源与测试。改访存协议时分别列出 req_fire、rsp_fire、旧响应 owner、错误地址及复位处置；RV32 和 RV64 都要走。实践文档中列的命令只在其阶段已有模块时执行。参考设计草案在 [THINKING](THINKING.md)，Cache 接入前的 [Core 审核](CORE_ASTRA_REVIEW.md) 记录历史意见；当前功能和已验证范围以代码、正式契约和对应测试为准。

分支整理记录见 [COMMIT.md](../COMMIT.md)；新增讲解归入 understand，硬件目标归入 roadmap，软件栈计划仍在 [软件路线](../SOFTWARE_ROADMAP.md)。
