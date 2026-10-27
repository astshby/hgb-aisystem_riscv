# 联合优化与测量方法

优化同时比较每次工作需要的 Core 周期、同配置综合频率和 LUT/FF/DRM/APM。
允许少量 FF 增加以换取 LUT 降低与两项性能提升。新增流水级最长正常路径不超过 12。
Core 的目标与完整 DDR 系统的目标分别验收，不能把 Core+TCM 的 Fmax 套给全系统。

已采用的方向包括：RAS 关闭、发射选择并行化、IQ/内存队列分离、恢复载荷与有效位分离、
完成预选/取指容量局部化、LSU 共享年龄及提前请求、TCM 系统端口地址逐 beat 更新。
ROB32→16 降低组合选择和资源，同时减少在途容量；按实际工作负载记录收益和成本。
重复全地址译码、响应仲裁扇入、块间空拍继续作为后续候选，不直接删除请求/CDC 寄存级。

软件编译默认 O3，O2/O3/Ofast 使用相同算法与固定配置分别测量。M0 使用理想一周期存储，
生产 TCM、片上系统、Cache/DDR、加速器并发分别归类。CoreMark/MHz 取计时区 Core 周期；
RT-Thread 独立测功能，YOLO/MiniMind 分别测实际输出和 DMA 并发。

Cache 容量先用仿真扫描，再对候选与基线做同输入标准综合。保持 Core、时钟、两路关联、
32 B 行和填充策略不变，分别改变 I$/D$ 容量。命中率取唯一 lookup 的 hit/(hit+miss)，
同时比较计时区周期和填充等待；累计命中次数本身不能用于比较命中率。
D$ 双 bank 的选择位为 `clog2(总容量/4)`，改变容量也改变数据在 bank 间的分布。

RV32 扫描入口如下，输出和固件目录每轮使用新名称；首次冻结两套种子，后续可复用同一 bundle：

```bash
SOFTWARE_OPT=O3 python3 scripts/verilator/run_cache_sweep.py \
    --output build/cache-sweep/run01 --bundle build/cache-sweep/firmware02 \
    --pairs 4:4 8:4 16:4 32:4 4:8 4:16 4:32 \
    --modes performance validation --iterations 2 --workers 2
```

`--pairs` 为 I:D KiB。长迭代使用新的 bundle，并用 `--models` 指向前一轮输出目录复用
相同 RTL/参数的模型。单点重放使用 `make coremark-platforms COREMARK_PLATFORM_ARGS='--icache-bytes 16384 --dcache-bytes 4096'`。
RT 使用 `scripts/rt-thread/run_system.py` 的相同容量参数；其定时等待周期与 CoreMark 分开统计。

本轮推荐显式 I$16/D$4 KiB：64 次六项几何均值提高 4.8455%，Core 综合估计 85.1064→86.8282 MHz，
代价为总 LUT +337、FF +576、DRM +2。SYS 83.8504→83.6960 MHz，仍达到 80 MHz，不能写成四域全部不降。
默认 4/4 KiB 和正式 baseline 保留。扩容后的 warm I$/D$ miss 各 7 次，进一步扩容的收益很小。

新的综合前 100 条 Core 路径全部由 SQ 有效位经前递资格/选择、广播有效位到 IQ。
固定槽前递数据和 ID 已经存在，后续需要缩短其有效位对端口选择的依赖；该项需要单独审阅 Core。
SoC 优先看 fabric 的并行独热授权、局部复位/CE 扇出和 D$ 行级 bank 分布。
现有 CPU 适配器已经使用专用 TCM 资格译码，FIFO 载荷也未复位，后续不重复提出这些已完成的改动。
请求队列保留容量 ready 切断；warm D0 满队列阻塞仅 4329 周期，约占 0.017%，不优先引入组合穿透。
所有后续方向先测相同固件周期，再核对时序与资源，不以删除握手数量作为验收指标。

当前所有分支共用硬件配置 `scripts/hardware_profile.json`。每项结果保存命令、源提交、
软件参数、镜像哈希和日志；删除旧日志后只保留历史摘要，不能承诺原测试完全可重放。
标准综合报告域内 Fmax、WNS、资源和最差路径。原始 CDC/DDR/PHY 约束问题单列，
布局布线后的布通率、setup/hold 另验；本轮不运行布局布线。

Claude 的历史建议包括多域时钟、削减 RAS 恢复链和减少扇入；Codex 的后续路径实验和
软件/分支整理在工作区优化建议、交接与汇总报告中分别记录。逐分支改动通过 git 查询，
不在本文件重复展开阶段日记。
