# 外存与 DMA 接入边界

## 当前实现

`vsrc/soc/bus/local_to_axi.sv` 是独立验证的本地总线到 AXI4 主端口桥。
尚未实例化到 `soc_top`，DDR 与 DMA 地址窗口仍按原契约返回错误。
本模块不是 DDR 控制器或 PHY，也不是 AXI4-Lite；首版 AXI4 只发单 beat。

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

`make soc-test XLEN=32` / `XLEN=64` 除原三个 SoC 流程外运行 `tb_local_to_axi`。
TB 检查 AW-first/W-first/同拍、各通道反压与载荷稳定、最早响应、窄访问全部合法 lane、
页末取指、响应错误、非法请求无外部副作用、异常读排空、响应保持及协调复位。
`logs/tb_local_to_axi-rv<XLEN>.log` 保存构建与 PASS；这不是实际 DDR 性能测试。

## 后续接入顺序

- 外存模型与顶层：增加可配置 DDR 容量和 AXI 端口，建立可变延迟/错误注入 RAM TB。
  未就绪的 DDR 必须有明确访问错误策略，不把初始化状态伪装成可用 RAM。
- DMA 数据引擎：先单通道 memory-to-memory，一笔读完成后发一笔写；
  源/目的只允许 TCM 和已启用外存，禁止把普通内存拷贝引擎用于具有副作用的 MMIO。
  控制寄存器仍在 `0x10030000`，至少包含 src/dst/length/start/busy/done/error/IRQ。
  精确寄存器偏移、尾字节策略、重叠区间限制及故障进度在 DMA 实现前固定。
- 三主端口互连：CPU I/D 加 DMA；保留 CPU 重定向取消边界，明确争用和公平性。
  DMA 完成仅在最后一笔写响应后发布，CPU 通过状态/中断观察，失败不回滚已完成写入。
- 端到端：CPU 配置 DMA、TCM↔外存校验、并行取指、IRQ、访问错误及复位；
  分别运行 TCM 布局和外存布局的 ISA/C/CoreMark，禁止混用两者成绩。
- 吞吐优化：完成正确性基线后再加 burst、4 KiB 拆分和缓冲，不把单拍桥称为高带宽 DMA。

暂不加入 Cache/MMU。未来 DMA 若写可执行内存，软件须等完成后执行 FENCE.I；
未来 Cache 一致性需要独立维护协议，不由 AXI4 自动提供。
先核实盘古 DDR IP 的数据宽度、用户接口和时钟复位，再做厂商适配；
Zynq-7020/Vivado 工作流保留，未进行板级实现。
