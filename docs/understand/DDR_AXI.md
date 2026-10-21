# DDR 与 AXI 学习

> 写作约束：[skills/regulation.md](../../../skills/regulation.md)。本文区分仿真模型、标准 AXI 和 Pango 原生口，不把三者当成同一层。

## 1. 层次

```text
CPU 窄 DDR / I$ / D$ / DMA 窄口
        ↓
   ddr_block_fabric / ddr_port_arbiter
        ↓
block_to_axi（标准） 或 pango_block_bridge（原生）
        ↓
标准 AXI 存储模型 或 厂商 DDR3 IP
```

- `bus/ddr_block_fabric.sv`：聚合窄口、I$/D$ 行口、DMA 块口。
- `bus/block_arbiter.sv`：读/写各一个 owner，同方向单笔，两方向可并行。
- `bus/block_to_axi.sv`：整块命令、W 收集、4 KiB 拆分、错误帧、B 响应。
- `cpu/pango_block_bridge.sv`：Pango 原生 256 位口，整块缓冲，无标准 B/RREADY。
- `cpu/pango_ddr3_bridge.sv`：旧的单拍原生桥。

## 2. 标准 AXI 合同

- 读：AR 地址/长度，R 数据/ID/LAST；必须收齐 RLAST 才释放 owner。
- 写：AW 和 W 可独立握手，W 全部接受后等 B；B 成功才算写完成。
- 跨 4 KiB 必须拆段；错误 ID、早 LAST、晚 LAST 都要排空。
- `block_to_axi` 先在内部缓冲整块读写，再对外逐拍；客户端反压和 DDR 等待分开记录。
- 当前每方向一个 owner，不是多 outstanding AXI。

## 3. Pango 原生口

- 256 位用户数据，写完成依据 WREADY，没有标准 B/BRESP。
- 读没有 RREADY，桥必须预备有界读存储。
- 写末拍被接受只表示 IP 接受，不表示 DDR 颗粒持久化。
- 跨域/校准/时序仍由厂商 IP 和板级负责人验证。
- 原生桥支持命令接受同沿捕获返回/写数据，和标准桥的资格不同。

## 4. Cache 行传输

`CACHE_BLOCK_ENABLE=1` 时：

- `cache_refill` 用块命令收 1–4 个 256 位 beat；32/64/128 B 行对应 1/2/4 拍。
- 收齐整行后进入 BLOCK_WRITE，每拍写一个原 RAM word；I$ 32 B 行 8 拍，
  D$ RV32 8 拍、RV64 4 拍。
- 任一 beat 错误或帧长不对，整行不安装，按原访存语义做一次标量 fallback。
- `cache_writeback` 先逐 word READ/CAPTURE 收集整行，再发块写；B 成功才 clean。
- 写回失败保留 victim valid/dirty/data；失败地址记行基址。

当前没有 critical-word-first、early restart、hit-under-miss 或 MSHR。命中仍是
阻塞式状态机。

## 5. DMA

- legacy engine：单描述符、逐字/逐 XLEN 搬运，读写串行。
- block engine：两块 128 B 缓冲，读下一块时写上一块；源/目的页界共同限制块长。
- 只有两端 32 B 对齐的 DDR 段走 256 位块口；TCM、非对齐头尾回退窄口。
- 成功写前缀按 B 响应累计；错误阻止新 offer，已展示/已接受事务继续排空。
- 一个软件命令，没有描述符 FIFO 或 scatter/gather。
- CPU 必须先 clean/flush 源和目标哨兵，DMA 完成后再 invalidate 旧副本。

## 6. 仲裁与顺序

- 窄聚合端和宽 DMA 共用 DDR owner；单 outstanding，读写互斥。
- 块仲裁读/写各一个 owner；同方向后继等前一笔 last/B。
- 跨 owner 交接通常隔拍；不能用“两个方向并行”推断颗粒内部带宽。
- 响应消费沿不一定能接下一笔；这是当前状态机的周转边界。

## 7. 验证与边界

- 标准/native 后端、4 KiB 拆分、错误 ID/LAST、AW/W 独立、反压、协调 reset。
- Cache 块协议 30 配置；真实共享 AXI 8 配置；DMA 双宽 348 场景。
- 整核 DMA C 实测多拍和物理 AXI 读写重叠，但没有与旧 DMA 做等配置带宽归因。
- 没有真实 DDR 颗粒、PHY 校准、板上 ILA 或十秒 CoreMark。
- 没有 RS 纠错、ECC、硬件一致性或异步 CDC。

## 8. 下一步

1. 64 位/宽口 Cache 安装与 early restart。
2. D$ store buffer、1 个 MSHR、hit-under-miss。
3. DDR 请求 FIFO/多 outstanding，保留 owner 和错误归属。
4. DMA 描述符链，用于模型权重搬运。
5. 真实 DDR 时序、跨域和板上验证仍由物理负责人完成。
