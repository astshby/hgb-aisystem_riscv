# 外存与 DMA 接入边界

## 当前实现

`soc_top` 已连接三主端口互连（CPU I/D、DMA），并将可选外存窗口暴露为可综合的本地总线端口。
`tb_soc_benchmark` 和 DMA 定向 TB 在该端口外实例化 `local_to_axi` 与可变延迟 AXI RAM。
`DDR_BYTES=0` 时外存窗口返回 DECERR；非零时须连接实际响应端，不能仅靠参数宣称 DDR 可用。
桥不是 DDR 控制器或 PHY，也不是 AXI4-Lite；首版 AXI4 只发单 beat。

端口：32 位物理地址、XLEN 位数据、固定 1 位 ID=0、单笔在途；
读写不并行，LEN=0、BURST=INCR、LOCK=0、CACHE/QOS/REGION=0。
PROT 标记特权访问，ARPROT 另区分取指。无 exclusive、burst 合并或超时功能。

协议依据 [Arm AMBA AXI 规范](https://documentation-service.arm.com/static/5f915971f86e16515cdc34a6)
的通道握手与 AXI4 写响应依赖：VALID 不等待 READY；AW/W 各自完成，B 在两者之后。
工程代码自主实现，不引入厂商 IP 或第三方 RTL。

## 请求、响应与错误

本地 request 接受沿锁存载荷，下一周期才出现 AXI VALID。接受前允许撤回；
接受后不可取消，尤其不能因 CPU 重定向撤销已接受的写入。桥不重复发射已握手通道。

AW 与 W 可以任意先后，必须等 B 才回本地写完成；读必须等 AR 后的 R。
本地响应寄存并保持到 ready，期间不接受新请求。为降低首版状态复杂度，
不做响应消费与新请求接受的同拍流水化。没有超时：从端无响应会一直等待。

窄访问保留原地址、SIZE 和 byte lane；WDATA/WSTRB 不右移，RDATA 不左移。
RV64 的高 32 位指令读取仍由 SoC 的已接受地址选择。自然对齐保证单 beat 不跨 4 KiB。
高于 32 位的地址本地 DECERR；不对齐、超宽、非法取指或越出 SIZE 的 WSTRB 为 SLVERR。
零 WSTRB 写合法且仍等待 B。

AXI OKAY/SLVERR/DECERR 分别映射本地对应结果；不发独占，因此 EXOKAY 按 SLVERR。
错误 ID 或缺失 RLAST 视为协议错误；异常多 beat 读排空到 RLAST 后返回 SLVERR。
从端永不提供 RLAST 仍会等待，不能伪称桥能从任意坏协议自动恢复。

复位要求桥、互连与外部从端协调。局部复位不能撤销已经产生的外存副作用，
当前接口不提供“取消已在途 AXI 写入”的保证。跨时钟桥留给平台层。

## 验证入口

`make soc-test XLEN=32/64` 运行 `tb_local_to_axi` 和 `tb_dma_fabric`：检查 AXI
AW/W/AR/R/B 反压、错误、请求归属，以及 DMA 的 TCM↔外存搬运、IRQ、对齐与字节尾数。
`make soc-dma-software XLEN=32/64` 分别使用 `SOC_DDR_BYTES=0/65536` 运行裸机 C：
CPU 配置 DMA，等待 ID 7 中断，校验数据，再从 DMA 写入的外存地址取指。
这些是功能模型和周期级反压测试，不是 DDR3 物理时序或板级带宽测试。

## 后续边界

- S3 已有单通道 memory-to-memory DMA：一笔读响应后发一笔写，成功的写响应后
  才增加完成字节数；不访问带副作用的 MMIO。任意错位或尾数按字节搬运，
  同时对齐时按 XLEN 字搬运。重叠、零长度和越界在启动前拒绝。
- AXI 仿真 RAM 可注入延迟和读写错误。实板仍需盘古 DDR3 控制器/PHY、时钟复位、
  跨时钟域与真实容量配置，并实测读写反压、错误和时序；Zynq 适配随后进行。
- 当前 DDR 已有 I$/D$，D$ 为 WT/NWA、无写缓冲。
  DMA 更新数据后须等 DONE/ERROR，再写 SoC 全失效命令；更新代码还需 FENCE.I。
  进一步的 burst、4 KiB 拆分与吞吐优化不是 S3 保证。

I$/D$ 已加入，MMU 尚未实现。一致性不由 AXI4 自动提供。
`make cache-test XLEN=32/64` 另验 I$/D$ 单元及真实 DDR 循环取指、
CPU/DMA 修改预热代码后的 FENCE.I、数据交接和部分写错后的 D$ 失效；不把 TCM CoreMark 当作 Cache 性能测试。
先核实盘古 DDR IP 的数据宽度、用户接口和时钟复位，再做厂商适配；
Zynq-7020/Vivado 工作流保留，未进行板级实现。
