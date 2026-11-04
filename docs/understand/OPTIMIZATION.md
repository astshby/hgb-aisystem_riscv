# 联合优化与测量方法

本分支移植 main@897b6dc / PR #33 的公共启动回归和测试入口修复，保留应用、
NPU、软件与时钟差异。`boot-count-test` 每宽度九用例；独立启动输出目录支持
P2_BUILD_ROOT，便于分支分别测量。没有新增生产 RTL 或本轮综合、布线数据。
hgb 后续以偶尔的紫光适配为主，rhbyv 独立开发并适配 Zynq-7020。

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
D$ 双 bank 的原选择位为 `clog2(总容量/4)`，改变容量也改变数据在 bank 间的分布。
行级分布实验新增 `--bank-xor-masks 0 1 2 3`：mask1混合地址bit5，mask2混合bit6，mask3混合两位。
保持容量不变也可改变同时访问的bank归属，原地址仍完整进入tag和写回；默认mask0保留原分布。

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

行级 bank 扫描与单点候选使用不同入口，保持参数名称明确：

```bash
SOFTWARE_OPT=O3 python3 scripts/verilator/run_cache_sweep.py \
    --output build/path-replay/bank02 \
    --bundle build/four-branches/compiler-v2/build/results/O3/firmware \
    --pairs 16:4 16:8 16:16 --bank-xor-masks 0 1 2 3 \
    --modes performance validation --iterations 2 --workers 2

python3 scripts/rt-thread/run_system.py --xlen 32 \
    --icache-bytes 16384 --dcache-bytes 8192 --dcache-bank-xor-mask 2
```

`coremark-platforms` 的 `COREMARK_PLATFORM_ARGS` 与 PDS 的 `prepare_benchmark.py`
同样接收 `--dcache-bank-xor-mask 2`；RT独立执行，RV64替换 `--xlen`。
每次重放使用新输出目录，具体测量的镜像/命令/哈希见本地结果JSON。

上一轮容量实验推荐显式 I$16/D$4 KiB：64 次六项几何均值提高 4.8455%，Core 综合估计 85.1064→86.8282 MHz，
代价为总 LUT +337、FF +576、DRM +2。SYS 83.8504→83.6960 MHz，仍达到 80 MHz，不能写成四域全部不降。
默认 4/4 KiB 和正式 baseline 保留。扩容后的 warm I$/D$ miss 各 7 次，进一步扩容的收益很小。

容量实验综合前 100 条 Core 路径全部由 SQ 有效位经前递资格/选择、广播有效位到 IQ。
固定槽前递数据和 ID 已经存在。经用户审阅后，Claude A共享地址比较、B寄存提示已分别试验。
A六项短测周期相同；B六项增加27～496周期，AB真实TCM两项每MHz下降0.16%～0.20%；B在SYS底座综合也回退，本轮不采用。
Codex 的 fabric 独热授权已完成同输入标准综合：SYS83.6960→104.7449 MHz，LUT61775→52625，
六项短测周期完全一致；请求锁定、AW/W顺序、缓冲边界和每拍吞吐保持。
D$三容量、四映射72项短测通过：D4 mask1六项几何均值+0.7708%，D8 mask2 +0.7804%，D16 mask3 +0.7878%。
24项64次确认已完成：D4/mask1 +0.7972%，D8/mask2 +0.8207%，D16/mask3 +0.8152%。
D8/mask2六项几何均值最高，比D4/mask1仅高0.0233%，validation还略低；不以扩容大小判断收益。
D4 cold的D$ miss仍82，但同bank争用393900→306460，说明改善来自冲突减少。
各bank的等待原因可能重叠，不能相加作为CPU总停顿。
含A的8a0d8f7与无A的47aec08完成同配置三层综合；去掉A后三层Core均提高、LUT均减少、FF不变，收尾源码不含A/B。
无A的D4、D8联合各六项64次与bank-only对照同镜像、同周期，真实Core/SoC-TCM六项周期不变。
无A Core+TCM105.0641 MHz、SoC+TCM93.6067 MHz、DDR D8为89.3336 MHz；D4/mask1仅85.4920 MHz，拒绝该映射。
D8虽比起点86.8282更高，但低于SYS单项90.1307；SoC+TCM也低于旧95.0299，尚未通过所有层主频不退验收。
收尾分支integrate/soc-path-selected保留SYS和bank参数支持，D8显式候选，默认I4/D4/mask0保持，正式baseline不升级。
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
