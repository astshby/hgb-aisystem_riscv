# AXI 外存仿真与真实 DDR3 的边界

## 三层不是同一个模块

`soc_top` 暴露一组可综合的本地请求/响应端口；地址译码把启用容量内的
`0x8000_0000` 窗口路由到它。`DDR_BYTES=0` 时路由到错误从端，访问返回 DECERR，
不能让未接外存无限等待。`local_to_axi` 把这个本地事务转换成 AXI4 单拍五通道握手。
`axi_memory_model` 是**仿真专用**字节 RAM，用确定性的周期性通道等待与固定响应延迟模拟
反压，还可注入读写错误。三者分别是 SoC 边界、协议桥、测试替身；没有一个是 DDR3
PHY、训练逻辑或厂商 Memory Controller。

```
CPU I/D 或 DMA → 本地互连 → 外存端口 → local_to_axi → AXI RAM 模型
                                                └→ 未来平台 DDR3 控制器
```

桥在本地接受请求时锁存地址、尺寸、数据与掩码。写通道 AW/W 独立握手，不假设同拍
完成；只有收到 B 才向本地报告写完成。读需等 AR 后的 R。VALID 有效时载荷必须在
READY 到来前保持。桥只容许一笔在途，`AWLEN/ARLEN=0`，不做 burst、自动 4 KiB
拆分、超时或带宽优化。错误响应映射到本地 SLVERR/DECERR；多 beat 异常读要排空。
更细的边界见[外存接入契约](../SOC_EXTERNAL_MEMORY.md)。

## 仿真验证了什么

`make soc-test XLEN=32/64` 分别验证桥的 AW/W 先后次序、反压、错误和异常响应，
以及 DMA 经三主端口互连进入 AXI RAM 的数据与 IRQ；测试会故意制造读/写错误。
`make soc-dma-software XLEN=32/64` 在无外存和 64 KiB RAM 两种配置跑 C 程序。
启用外存时 CPU 还从 DMA 写入的地址取指。因此这证明协议路径与功能，不证明
实际 DDR3 的训练成功、时钟收敛、可靠读写或 CoreMark 性能。

## 上板需要补哪一层

盘古 676-200K Pro 的平台 wrapper 必须连接厂商 DDR3 控制器/PHY 的真实用户接口，
核实该接口是否为 AXI4、数据宽度、ID、时钟域、复位和校准完成信号；必要时再加
宽度/时钟转换，不能把 AXI RAM 直接综合成“DDR3”。`DDR_BYTES` 必须与可访问容量
一致，并在控制器 ready 前阻止合法请求悬挂。Zynq-7020 的 PL/PS DDR 路径则是
另一个平台选择，不能直接沿用盘古 IP/约束。实际板级集成与时序检查在 S4 Cache
之后继续推进，不在当前 S3 PASS 范围。
