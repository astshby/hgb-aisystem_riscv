# 从分支差异读 SoC 源码

本篇给出实践顺序：先确认分支已经有哪些模块，再跟一次总线请求，最后按修改类型找到测试。正式地址和握手定义在 [SoC 访存契约](../SOC_BUS_CONTRACT.md)，图和从端编号在 [外设接口](../SOC_PERIPHERALS.md)。以下分支说明来自实际 Git 树；hgb 与 rhbyv 的早期 S3 分支名称相似，内容不同。

## 先确认当前代码处在哪个阶段

| 仓库与分支 | 可以在 vsrc/soc 中找到 | 这时还没有什么 |
|---|---|---|
| 两仓 main | 主要是 Core 与 M 扩展 | soc_top 和完整 SoC |
| 两仓 SOC/tmc-mmio | soc_top、ROM、I/D-TCM、互连、MMIO、IRQ | DMA 主端、AXI 桥、Cache |
| hgb soc/s3-axi-dma | local_to_axi、可选 DDR 本地端口 | 完整 dma_controller；此分支只是 S3 早期检查点 |
| hgb soc/s3-dma-validation、rhbyv soc/s3-axi-dma | dma_controller/engine/regs、第三主端、AXI 仿真路径 | I$/D$ |
| 两仓 s4/cache | I$、WT/NWA D$、系统全失效命令 | D$ dirty、clean、flush |
| 两仓 s5/cache-up | WB/WA D$、写回引擎、维护控制器 | 真实 DDR3 控制器/PHY、MMU、硬件一致性 |

当前文档分支 docs/soc-learning-map 从 S5 继续，没有改变 RTL。切换历史分支时，先运行 git branch --show-current，然后查看 git ls-tree -r --name-only HEAD vsrc/soc 和对应 docs/README.md。若只想比较，不必切换工作树：git diff main..SOC/tmc-mmio -- vsrc/soc 能看到最初接入；git diff s4/cache..s5/cache-up -- vsrc/soc/cache 展示写回升级。历史文档可能描述下一步设计，判断“已经实现”时以该分支的实例和测试文件为准。

## 在 S2 找到物理地址与设备

从 soc_top.sv 的 u_core 开始。Core 给出 I 口和 D 口请求，soc_top 把字段打进 bus_req_t，然后 bus_interconnect 为每个主端调用 address_decode。后者先选 ROM、I/D-TCM、MTIME、IRQ、DDR 或一个 4 KiB MMIO 窗口，再检查完整地址、访问末端、对齐、大小、执行/写权限。错误改道 s0，由 bus_error_slave 仍返回一次响应。这里能解释为什么地址常量写对了而访问仍可能得到 SLVERR。

按 s 下标读 soc_top：s1 ROM，s2/s3 两个 TCM，s4..s13 交给 soc_peripherals。soc_peripherals 把 s4 给机器 Timer、s5 给 IRQ 汇聚、s6/s7 给 UART、s8 给通用 Timer、s9..s11 给 GPIO、s12 给 DMA 寄存器、s13 给 SoC 信息；S2 时的 s12 可能尚未实例化，须看当时源码。很多设备用 mmio_endpoint，它把 RV64 的高 32 位 lane 还原成 32 位寄存器访问，且仅在 access_fire 沿产生读清除或写副作用。

先跑 make soc-test XLEN=32/64：tb_soc_fabric 观察同 bank 仲裁、跨 bank 并行和响应 owner；tb_soc_peripherals 读写寄存器、反压、UART 引脚环回、GPIO 与 IRQ claim/complete。再跑 make soc-software XLEN=32/64，查看 C 程序怎样安装 mtvec、打开 mie/mstatus.MIE、响应真实设备中断。main 没有 soc_top 时这些 SoC 命令自然不适用。

## 在 S3 找到 DMA 的两张面孔

CPU 写 DMA_BASE 的 SRC/DST/LENGTH/CTRL，走 CPU D 主端到 s12 的 dma_regs；dma_regs 把 start_valid 和源、目的、长度交给 dma_engine。dma_engine 读一个源 beat，等响应后写目的 beat，写完成才增加 BYTES。它发出的事务从 m2 重新进入互连，可能再次争用 CPU 正在使用的 I/D-TCM 或 DDR。寄存器从端与搬运主端不能合并成一条普通 MMIO 连接。

去 dma_smoke.c 看启动、IRQ_EN、ID 7 的 handler 和部分错误读取；去 tb_dma_fabric.sv 看交错与 backpressure。hgb 的 soc/s3-axi-dma 只有 AXI 桥，此时应先读 local_to_axi.sv、tb_local_to_axi.sv；若要读完整 DMA，请切到 soc/s3-dma-validation。rhbyv 的 soc/s3-axi-dma 已包含完整 DMA。对应入口为 make soc-dma-software XLEN=32/64 和 make soc-test XLEN=32/64。

外存边界只有本地 ddr_req/rsp；仿真顶层在该端口外接 local_to_axi 与 axi_memory_model。打开 DDR_BYTES 决定物理窗口和 Cache 能否工作，不会自动生成 FPGA DDR 控制器。AXI 桥只发单 beat，并保留 B/R 错误；板级控制器/PHY、时钟、复位和约束另做。

## 在 S4、S5 找到 Cache 与一致性

S4 的 I$ 先检查完整原始取指请求，再按 32 B 行读 DDR；FENCE.I 使 tag 失效，在途旧响应排空，旧路径不能重新安装。S4 的 D$ 是写穿透、写缺失不分配。其系统寄存器 0x10040020 只有全失效，没有 dirty 或异步完成状态。单测文件 tb_dcache.sv 在 S5 仍保留对 S4 行为的检查，但实际 S5 SoC 使用新的 dcache.sv。

S5 的 D$ Store hit 在缓存内按字节修改并置 dirty；缺失先填整行；逐出脏行时 cache_writeback 从同步数据阵列逐字读出并等真实写响应。cache_maintenance_controller 接收软件命令和 FENCE.I，先阻止新请求，再等旧响应排空后借用 D 主端口。读 S5 时，把 dcache_meta_array 的 valid/dirty、cache_port 的 CPU/维护归属和 dcache 的状态机一起看；只读命中路径会漏掉数据交接风险。

DMA 绕过 D$。CPU 给 DMA 的 DDR 源数据先 clean/flush；DMA 目的区已有 CPU 脏行先 flush；DMA 完成或失败后 invalidate，再由 CPU 读。维护操作是全局扫描，命令写响应只确认入队，软件须检查状态。代码在 tb/cache/cache_maintenance.h、dcache_smoke.c、icache_smoke.c；单元 TB tb_dcache_wb.sv 对每个写回 beat 注入错误，tb_cache_maintenance.sv 检查 FENCE.I 失败后的停取指归属。S5 的错误策略详见 [写回解读](S5_CACHE_WRITEBACK.md)。

## 改动源码时按一次真实事务核对

新增 MMIO 寄存器：先核对 soc_addr_pkg、address_decode、bus_types_pkg 的窗口与目标编号；若是新设备，还要给互连分配从端 s 下标并接入 soc_top/soc_peripherals。普通寄存器通过 mmio_endpoint 处理对齐、RV64 lane 和一次副作用；只有特殊语义才单独处理。增加 IRQ 源要修改汇聚的 sources 位宽、ID、使能寄存器和软件 handler。tb_soc_peripherals 至少覆盖有效写、部分掩码、非法地址、响应保持和中断清除。

修改缓存或访存接口：列出谁能拉 req_valid/ready、谁保存请求 payload、旧响应被反压时归谁、错误映射到哪条指令。拿一个 RV64 高半字访问、一个 DDR 尾部不足整行访问、一个重定向后迟到的 I 响应，以及一个脏行写回失败做反例。前两个可以暴露 lane/范围错误，第三个检查旧路径 kill，第四个检查已经退休的 Store 是否被丢弃。针对 RTL 改动分别跑 make test、make soc-test、make cache-test 的 RV32/RV64，再跑受影响的软件入口。单改文档应检查链接、分支范围和术语，不把历史 TB 结果写成新源码的测试结论。

一次 WB D$ 数据读的查线顺序可记为：Core.mem_stage → soc_top.data_request → dcache.cache_port → bus_interconnect.m1 → address_decode → s14 DDR → AXI 桥/RAM → 回到原 owner → dcache → Core.wb_stage。一次外部中断则是设备 STATUS → irq_controller.pending/enable/priority → csr_file.mip/mie/mstatus → interrupt_entry 排空 → trap_controller/mtvec → handler 清设备源与 COMPLETE → MRET。沿着这两条线查，能找到大部分“请求已经发了却没退休”或“中断一直重进”的原因。
