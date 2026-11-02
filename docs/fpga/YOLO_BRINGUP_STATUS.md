# YOLO 上板进度与问题

本报告更新于 2026-11-02T11:27:06.985958+08:00。本轮原生构建于 2026-11-02 00:15 完成（UTC+8）。这是一份覆盖更新的当前状态报告；历史细节以 Git 和原始日志为准。

**完整 YOLO 尚未跑通。** 新增 LED 观察逻辑已完成正式回归、原生布局布线、内部时序及管脚验收，新位流已下载并回读通过。现场灯态为0/4/7亮、1/2/3闪、5/6灭，UART仍为0字节；本轮监测无过温，结束已停止配置确认DONE0。模型上传与整网推理均为 0 次。

维护者已暂停 yolo 发布名称，当前调试基线为 yolo-debug。用户最新约定是只在本地修改、测试和记录；没有新的明确要求，不再推送分支或创建、更新 PR。此前报告 PR22 已由维护者合并，代码草稿 PR24 创建于该约定之前；本地记录继续更新。本次用户已明确要求将当前进度发布到新分支PR；本次发布之后，其他工作仍默认只在本地进行。

## 代码与固件身份

| 项目 | 身份或状态 |
|---|---|
| 本轮已测硬件源码 | `diag/yolo-boot-led-20261101` / `3e5fc19b087dfede845e26ccffff886bd9b3a2e1` |
| 审阅代码头 | `fc3d831ab447029d58277d62eb6da6c2d202c152`；保留最新调试基线文档，相关 RTL/软件/脚本/TB 与已测头逐字节等价 |
| 前序软件修复 | `c3905ae`：首次帧缓冲访问前等待 DDR；`b504824`：S:0/S:1/S:2 与原异常入口 T: |
| 完整模型交付基线 | `dc5dfe5`：320/416 完整模型、固定图片和可重建依赖，已保留 |
| RV32 固件 ID | `9ffe18ef0f222245` |
| RV64 固件 ID | `23a94713abe3d154`，仅构建及仿真，无 RV64 上板成绩 |
| RV32 ELF SHA256 | `ef1701903f9a434ebe55558d9589656f2a5c846f599acb3e907fa1faf8bd7c21` |
| 本轮位流 SHA256 | `96660a95aa2b2ce6449226a54aa563047ce8f1e05e3f64c689feff66166ab82c` |
| 位流大小 | 9188552 字节 |

27 份固件输入和 ELF/HEX 与 b504824 的已测固件逐字节一致；本轮重封存了源身份，没有重新编译固件。USERCODE 仍为 9ffe18ef，不能单凭它区分新旧 RTL；下载证据必须绑定本轮位流哈希。旧位流 7600958d… 的板测不计作新 LED 位流的成绩。

## 本轮已完成的验证

| 验证 | PASS | SKIP | 边界 |
|---|---:|---:|---|
| LED 观察器 RV32/RV64 | 2 | 0 | 独立时钟、停钟、复位、有效提交、ITCM 范围和 UART 低电平锁存 |
| C10/legacy 封装展开 | 12 | 0 | C10 4 项、legacy 8 项；不是物理 PLL/DDR 证明 |
| make test XLEN=32 | 82 | 2 | RAS 关闭项和另一位宽 TB 按 SKIP 计 |
| make test XLEN=64 | 82 | 2 | 同上 |
| make riscv-tests XLEN=32 | 58 | 2 | 排除 fence_i、ma_data |
| make riscv-tests XLEN=64 | 78 | 2 | 排除 fence_i、ma_data |
| benchmark-smoke 双宽 | 2 | 0 | 各一次 |
| coremark 双宽 | 0 | 2 | 当前分支无目标；命令退出 2，未声称运行成功 |
| 合计 | 316 | 10 | 无功能失败；跳过项没有计入 PASS |

精确命令、日志与分类见 `logs/yolo-boot-led-20261101/regression/receipt.json`。使用本地输出隔离层与原有测试源，所有 Verilator 编译实际为 -j1。旧启动固件的双宽正常/DDR 延迟/DDR 超时共 6 项仿真保存在前序证据中，不重复加入本轮 316 项。

SYN 中的 ITCM/DTCM 各 65536 字节、各 16 个 DRM，初值已逐字节核对 staged HEX；证据是 `tcm-init-summary.json`，不只是加载日志。该检查仍不能代替板上真实取指。启动仿真使用行为 DDR，没有模拟物理 PHY/PLL，且启动测试未连接视频取帧 DMA。

补充验证仍有覆盖边界：旧SYN ROM组件测试只核对5个独立保留位（掩码0xD5）、6个地址和本地握手，不覆盖完整32位指令经跨层别名/AXI/缓存进入CPU。新的原生启动探针先遇厂商加密块解析限制；外部PLL/DDR包装体抽象后保留实际CPU/ROM/缓存/总线及39个通用异步FIFO和1个像素FIFO。6GiB子进程限额下编译因std::bad_alloc未完成，属于工具/资源失败，不是DUT功能失败。8GiB受限重试在编译600秒后超时退出124，未进入功能仿真，尚无可采信的新启动功能结论，也未加入316 PASS/10 SKIP。真实物理PLL、DDR PHY及PNR时序不在该补充探针范围。

## RV32 原生实现与成本

PDS 2025.2 build 211867、PG2L200H-6IFBB676、C10、I16/D8、hash2、timing-v2、fanout64、route slack weight 80。实际 max_threads=8，布局/布线最多 8 工作进程、时序分析最多 4、位流生成最多 2；12/16 线程未测。

本轮状态为 INTERNAL_STA_PASS_WITH_RECORDED_DIAGNOSTICS。最终未布线网络 0，慢/快角 setup、hold、recovery、removal、最小脉宽及 skew 共 12 类表均非空、失败 0。七个 LED 的最终 IO 与 pinout 表均通过，含球位、方向、bank、电压、标准、驱动、slew、无 keeper 及约束标志。

| 时钟 | 请求频率 MHz | STA Fmax MHz | setup 余量 ns |
|---|---:|---:|---:|
| ref_clk | 125.0000 | 200.7226 | 3.018 |
| rst_clk | 125.0000 | 226.6032 | 3.587 |
| ddrphy_sysclk | 125.0000 | 133.2623 | 0.496 |
| clk_core | 83.8068 | 86.3096 | 0.346 |
| clk_sys | 102.4306 | 108.4402 | 0.541 |
| clk_periph | 65.8482 | 71.7648 | 1.252 |
| clk_npu | 92.1875 | 97.7476 | 0.617 |
| clk_video | 148.5000 | 162.6279 | 0.585 |

最差已导出慢角路径位于厂商 DDR PHY：ddrphy_sysclk 到 phy_dq_sysclk_1，写数据使能寄存器到 DQS TS_CTRL[6]，setup 余量 0.108 ns，数据延时 5.877 ns（逻辑 0.636、布线 5.241），沿用厂商 MultiCycle Path Setup -end 2。完整端点和路径分解见 physical-receipt.json；没有通过更改频率数字或新增同步 false path 来获得结果。

综合估计：LUT 69276、FF 72098、DRM 168、APM 86、IO 116；观察器局部为 85 LUT / 82 FF。布线后实体账本：LUT 69371.5、FF 72080、DRM 168、APM 86、IO 116。器件 grid 的 DRM=169、APM=43 另存，不能与实体数混用；整体 FF 差异不能解释为观察器带来的节省。

| 阶段 | 原生耗时 s | 工具内存池峰值 MB |
|---|---:|---:|
| compile | 184 | 1189 |
| synthesize | 2391 | 3970 |
| dev_map | 2446 | 2136 |
| place | 2102 | 10574 |
| route | 16198 | 5442 |
| route_optimize | 109 | 5770 |
| report_timing | 99 | 6575 |
| gen_bit_stream | 73 | 3563 |

流水线墙钟 23754.993 秒，约 6 小时 35 分 55 秒；route 占 4 小时 29 分 58 秒。旧约 4 小时 20 分来自另一份映射/布局，本轮没有做同输入线程对照。15 秒局部路由 CPU 样本约 0.925 核，仅描述该窗口，不能代表整阶段或据此承诺 12 线程收益。

正式阶段入口及 dev_map/place/route/route_optimize 边界均通过 Windows 可用物理内存与可用提交至少 6 GiB 的门禁，约 10 分钟采样。此前未过门禁的预检记录保留，没有降低门槛。工具池峰值不等于 Windows 提交峰值；没有改分页或终止无关进程。

仍保留 DeviceMap-2011（ref_clk 部分负载未经过时钟缓冲）与 ConstraintEditor-2022（部分 IO 默认属性）两类原生诊断。engineering_signoff=false、external_io_signoff=false；这些 STA 频率不是板上实测频率、推理 FPS 或外部 DDR/HDMI 签核。

## 已知板上现象与未决问题

独立 100 MHz UART/NPU 自检已有 3 个合成卷积案例通过：192 原始值和 192 量化值匹配；完整重接后也曾收到原厂 10 行文字、190 字节。这只证明当时的独立链路与计算模块可用。原厂 HDMI 彩条曾由用户确认出图，不计作 YOLO 视频链路成功。

旧完整 9ffe 固件在有效 KEY0 确认窗口内捕获 RX0，无 S/B/T、READY 或模型服务响应；监测无过温，结束官方软复位确认 DONE0。早期到达时窗口已经结束的按键确认不计为有效复位失败。

此前两次状态 081ffca0 的 bit27 over_temp=1，实际摄氏温度未测。用户确认无散热片、无风扇。最近一次只读 JTAG 核验在 2026-11-01 21:29：ID00603899、状态00180c80、过温0、DONE0；它不是新位流板测。连续整网运行前仍需改善散热。

尚未确认 CPU/总线启动卡点。S:0 本身访问 UART MMIO，事务可能停滞；没有 S:0 不能证明 CPU 从未执行。视频控制口 0x10070000 与 DDR 主口3已静态连接，实际视频 DMA、完整模型推理和检测框发布仍未验证。旧完整固件实际 UART_TX/RX 为 C24/B24，本轮原有109个IO属性保持一致；绑定正确也不等于板上信号已工作。

本轮新LED位流于2026-11-02上午完成短时实板观察：捕获总长349.141秒（含下载阶段），用户完整灯态在监测有效期间到达；44次过温采样均为0，最终状态00180c80、DONE0。轮询等待设置为5秒，含JTAG读取开销实际间隔6.517～6.550秒。按键由用户对按键/读灯请求的回复推断，未单独明确已按，也未电测KEY0边沿。新位流已观察到标量提交和提交异常，没有观察到ITCM范围提交或内部UART TX低电平；异常PC/mcause尚未知，不能直接认定ROM、ITCM或串口接线为根因。证据见本轮board-boot-led/assessment.json及原始捕获。

## LED 观察与下一步

| 灯 | 含义 |
|---|---|
| LED0 | ddr_init_done && !soc_rst；同一固件下稳定亮支持 DDR 就绪及全局复位释放 |
| LED1 / LED2 / LED3 | Core / SYS / 外设心跳，只由板级按键清零 |
| LED4 | 当前复位周期内观察到标量提交口活动 |
| LED5 | 当前复位周期内观察到 ITCM 区间 0x01000000～0x0100FFFF 的提交 |
| LED6 | 当前复位周期内观察到内部 UART TX 低电平 |
| LED7 | 当前复位周期内观察到有效提交异常，可能包括正常 ECALL |

观察逻辑不反馈总线、复位或时钟。LED4 不代表双发射全部退休事件，LED6 不代表有效字节；事件标志会被 SoC 复位清除。LED4/5亮而6灭时优先查内部 UART/MMIO、外设域及发送流程；6也亮但电脑RX0时再重点查引脚、波特率和串口链路，不能反推 ITCM 损坏。仿真通过只能覆盖被建模的条件，不能把物理时钟/复位/CDC 全部排除。

本轮现场观察已经完成，下一步先核对实际综合网表的完整ROM返回、跨层别名及取指/跳转路径。后续若需再次上板，重新执行新鲜UART/JTAG/过温预检，并在有人现场观察时下载已授权易失配置。串口捕获在下载前开启，每5秒查过温；确认 KEY0 后收集 LED0～LED7，等待完整灯态最多10分钟，收到后再捕获10秒并官方软复位确认DONE0。超时、意外掉配置和过温单独分类，不能当成有效复位后无输出的证据。

根据真实灯态和日志再决定整改。涉及已完成阶段的新行为改动，先形成具体方案并按 AGENTS 审阅范围确认。只有有效 READY/模型服务及充分散热后，才上传320/416模型、比对固定数据和金标、重复整网检测及检查HDMI发布。当前模型上传0、整网推理0，实际FPS未测。

## 证据与复现边界

| 证据 | 位置 |
|---|---|
| 七文件批准范围、正式回归和输入封存 | `logs/yolo-boot-led-20261101/` |
| ELF/HEX 与原构建身份 | `build/yolo-boot-led-20261101/firmware-rv{32,64}/` |
| 本轮原生工程 | `$PDS_WORK_ROOT/work/yolo-boot-led-20261101/` |
| 初始化、CDC、时序、管脚、位流与独立文件核验 | 同工程 `tcm-init-summary.json`、`cdc-scope-receipt.json`、`physical-receipt.json`、`boot-observer-pinout.json`、`bitstream-validation.json`、`board-readiness-review.json` |
| 成本、实体/grid资源与工具版本 | 同工程 `phase-costs.json`、`routed-resource-views.json`、`runtime-helper-sha256.json`、`runtime-helper-current-sha256.json` |
| 原始日志/报告/检查点及Windows内存 | 同工程 `phase-logs-*`、`prj_tasks/`、`memory/`、`*-memory-*.json`；原件未清理 |
| 旧完整固件有效按键捕获 | `$PDS_WORK_ROOT/work/yolo-early-start-20261101/board-early-start-key-watch/` |
| 当前执行计划与现场控制器 | 工作区 `log/yolo-current-execution.json`、`log/yolo-boot-led-execution-plan.json`、`log/yolo-boot-led-board-tools.json` |

工程生成器的通用IO来自生成DDR工程，未自动拾取新LED属性。本轮从已审阅FDC提取49条属性，生成board_boot_led.fdc并只加载一次；原DDR/时钟/视频约束与RCF字节不变，最终实际7个球位已验收。重建时必须保留该适配及相应核验，不能只取代码就声称精确复现。

精确命令、输入及日志SHA见各收据；外部工具使用PDS_HOME、PDS_WORK_ROOT、RISCV_TOOL_ROOT。原始工具报告、位流、ELF及运行工具未随本次进度文档PR上传，其他机器仍需取得原件或按固定输入重跑；诊断代码另见PR24，本次PR只更新进度文档。
