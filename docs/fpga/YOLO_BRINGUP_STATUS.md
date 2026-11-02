# YOLO 上板进度与当前启动问题

报告截点：2026-11-02 22:54（UTC+8）。本文件汇总当前状态，后续结果以对应源码、原始收据和测量记录为准。

**完整 YOLO 尚未跑通；目前已从“没有启动日志”推进到捕获真实的首次取指访问错误。** 实板首次异常为 PC=0x00004000、cause=1、TVAL=0x00004000。该地址恰好位于 16 KiB 启动 ROM 之后；为什么启动流程没有正常跳入 ITCM，仍未确定。READY、模型服务响应、模型上传、整网推理和实际 FPS 均无成功结果。

当前发布基线为 `yolo-debug`。本次用户明确要求发布进度总结，仅以新文档分支提交 PR；首次异常及启动前序诊断的本地代码和原始生成件不随本 PR 上传。

## 当前阶段与源码身份

| 阶段 | 源码身份 | 截点状态 |
|---|---|---|
| LED 启动观察基线 | `diag/yolo-boot-led-20261101` / `3e5fc19b087dfede845e26ccffff886bd9b3a2e1` | 已完成回归、PDS 和短时上板 |
| 首次异常诊断 | `diag/yolo-first-exception-20261102` / `682e6a0d6854fa0c75150e25d0cf659eb5b7c052` | 已完成回归、内部时序验收、位流生成和短时上板，成功捕获异常 |
| 启动前序诊断 | `diag/yolo-boot-prefix-20261102` / `7344a8305320cb27dc42685544fe34f43ac59798` | 22:50 完成正式回归；截点尚无新 PDS、位流或板测验收结果 |

上一轮代码 PR24 面向 `yolo-debug`，包含 LED 观察和此前已批准的软件启动诊断。进度 PR25 已由维护者合并为 `4485f536764d428897e42cdaba4fe82cbc90ef6f`。本报告引用的 `682e6a0`、`7344a83` 目前为本地源码身份，不能假设其他机器已能从远端取得；需要另行授权发布代码或取得源码归档后才能复现对应实现。

首异常诊断用独立 Core 时钟发送器输出已冻结的 PC、cause、TVAL 和指令字段，发生第一次有效标量同步异常后接管板级 UART TX，绕开应用固件的 UART MMIO 发送流程。它只观察事件，不改变 ROM、ITCM、CPU 执行控制、PLL 或设计时钟约束。观察口是标量提交口，不代表双发射的全部退休事件。

## 已取得的实板证据

### LED 观察基线

用户报告 LED0/4/7 亮、LED1/2/3 闪、LED5/6 灭；完整固件串口捕获为 0 字节。

- LED0 表示 `ddr_init_done && !soc_rst`，支持 DDR 初始化完成和全局复位释放，不证明 DDR 实际读写正确。
- LED1/2/3 只说明 Core/SYS/外设时钟有活动，不是板上频率测量。
- 当时 LED4/7 表示观察到标量提交和提交异常，LED5/6 未观察到 ITCM 范围提交或内部 UART TX 低电平。
- 44 次监温样本均无过温；结束后停止配置并核验 DONE=0。按键由读灯回复上下文推断，未电测 KEY0 边沿。

### 首次异常诊断

本轮下载、回读、USERCODE 和 DONE 检查通过。被动 UART 收到 2958 字节、51 帧，所有完整帧中的异常快照一致：

```text
X PC=00004000 CAUSE=00000001 TVAL=00004000 INST=00000000
```

cause=1 是同步取指访问错误。`INST=0` 属于取指失败事件，不能当作已经成功读取、随后被执行的指令，更不能据此直接判为非法指令或 ITCM 内容全零。

这是配置启动后的有效捕获，本轮没有手动 KEY0 确认或物理 LED 灯态记录，不列为手动复位测试。主机发送字节数为 0；3 次监温样本均无过温，实际间隔为 6.542/6.533 秒。采集结束后官方复位停止配置，最终状态 `00180c80`、DONE=0 已核验。

这说明独立诊断发送路径可以回传异常，不证明应用 UART 外设、完整总线或 YOLO 服务已经正常。完整固件仍无 READY、无模型服务；模型上传和整网推理仍为 0 次。

## 主要问题与判断边界

启动 ROM 映射为 `[0x00000000, 0x00003fff]`。按源码，正常前两条指令应为：

```text
PC=00000000  INST=010002b7  LUI  t0,0x01000
PC=00000004  INST=00028067  JALR x0,0(t0)
预期进入 ITCM：0x01000000
```

当前异常出现在 ROM 后第一个地址 `0x4000`，因此排查重点是实际启动取指、ROM 返回的指令字以及正常跳转为何没有产生预期结果。但现有快照没有给出此前真实提交的指令和跳转过程；顺序执行越界、错误跳转等仍只是待验证解释，根因未确认。

首次帧缓冲访问前的 DDR 就绪等待已在前序固件加入，最多等待两秒、超时报告 E2；加入后仍未恢复启动。当前观测到的是 ROM 边界处的取指错误，不能仅凭“没有等待 DDR”解释全部现象，也不能把 DDR 初始化完成当作完整 DDR 测试通过。

SYN 网表中 ITCM/DTCM 初值已逐字节对齐 HEX，位流实际设置 `Write DRM Data=true`。这些检查与小范围原生 ROM/AXI target 探针均不能代替完整指令字经过缓存、跨时钟桥和 CPU 后的板上取指验证。此前受限原生整机探针曾编译内存不足或超时，未得到功能结论，不计作 DUT 功能失败。

原厂 HDMI 彩条曾确认出图；独立 100 MHz UART/NPU 的 3 个合成卷积案例、192 个原始值和 192 个量化值已匹配。这些结果不等于完整 SoC、视频 DMA、整网推理或检测框显示成功。

## 首异常版本 PDS 验收与代价

环境为 Windows PDS 2025.2 build 211867、PG2L200H-6IFBB676、C10、I16/D8、hash2、timing-v2、fanout64、route slack weight 80。单工程，实际 `max_threads=8`；时序分析最多 4 个工作进程。12/16 线程未做同输入对照。

原完整实现未布线为 0，但 DDR PHY 慢角 setup 有 1 个失败端点、WNS=-0.016 ns，因此没有生成或下载该失败版本。优化前检查点的慢/快角 hold 有 455/551 个失败端点，不能直接回退；单网重布线虽修复 setup，却引入 -0.584/-0.669 ns hold 失败，也未采用。

最终在全新原生副本中，从合法 Route 检查点重做 hold 优化，仅比较优化器选路阈值 200/100 ps 与 0/0 ps；RTL、频率和设计时序约束保持不变。验收副本为 `$PDS_WORK_ROOT/work/yolo-first-exception-hold0-20261102`。

- 慢/快角 setup、hold、recovery、removal、最小脉宽和 skew 共 12 类内部检查表均非空、失败 0；未布线网络 0，7 个 LED 管脚验收通过。
- DDR 相关慢角 setup 余量 +0.133 ns，快角 hold 报告值 0.000 ns；后者只满足原非负门槛，没有可声称的额外余量。
- 布线后实体资源：LUT 70317.5、FF 76640、DRM 168、APM 86、IO 116。综合估计为 LUT 70255、FF 76654；估计和布线后实体数分开记录。
- 补充 hold 优化 324 秒、STA 330 秒、位流生成 76 秒，不能把这几个补充步骤称为整轮实现时间。原实现日志与失败副本均保留。
- Windows 双项 6 GiB 内存门禁持续保留；原运行 15:05～19:54 周期采样有缺口，不能声称取得完整 Windows 峰值。工具原生内存池与 Windows 物理/提交采样分列。

| 时钟 | 请求频率 MHz | STA Fmax MHz | setup 余量 ns |
|---|---:|---:|---:|
| Core | 83.8068 | 86.0867 | 0.316 |
| SYS | 102.4306 | 106.9098 | 0.409 |
| DDR PHY SYS | 125.0000 | 133.6720 | 0.519 |
| 外设 | 65.8482 | 79.9018 | 2.671 |
| NPU | 92.1875 | 98.0735 | 0.651 |
| 视频 | 148.5000 | 157.7285 | 0.394 |

仍记录 DeviceMap-2011 的部分 ref_clk 负载时钟缓冲诊断和 ConstraintEditor-2022 的默认 IO 属性诊断。`engineering_signoff=false`、`external_io_signoff=false`；内部 STA 通过不等于外部 DDR/HDMI 签核或实板推理性能。

已测位流大小 9188552 字节，SHA256 为 `b13067004f67596b270c157074836f72ca2add064bda5a65dc41274e13ea8ead`；最终 ADF SHA256 为 `49e1fbf2d77bd7e84d581dd4a7b442b3a47090fb087343601bfb7a35de39a501`。

共用 RV32 固件 ID 为 `9ffe18ef0f222245`，ELF SHA256 为 `ef1701903f9a434ebe55558d9589656f2a5c846f599acb3e907fa1faf8bd7c21`；RV64 ID 为 `23a94713abe3d154`，无 RV64 板测成绩。27 份固件源和 ELF/HEX 与前序已测固件不变，仅重封存身份，未重新编译固件。USERCODE `9ffe18ef` 不区分各诊断 RTL，必须同时绑定源码和位流哈希。

## 正式回归与下一版诊断

首异常版本的正式矩阵为 318 PASS / 10 SKIP，另有双宽真实 CPU 异常元数据到观察器接线测试 2 PASS，合计 320 PASS / 10 SKIP。候选测试、原生组件探针、解析器和板测工具模拟单独记录，不重复相加。

下一版启动前序诊断 `7344a83` 已获用户批准并完成本地提交，只修改观察器和对应 TB 两个文件：保留复位后最早四次有效标量提交的 PC、指令和有效位，以 B0～B3 行随 X 异常行输出；首次异常后冻结，首异常同沿可占用剩余槽位。这不是完整双发射执行轨迹，取指异常条目的指令仍需按 cause 判断可信度。

该版本正式回归于 22:50 完成，结果如下；截点尚无对应的新 PDS、位流或实板验收，不能借用 682e6a0 的时序和板测成绩。

| 启动前序版本验证 | PASS | SKIP |
|---|---:|---:|
| 双宽观察器及首异常/前序诊断 | 4 | 0 |
| C10/legacy 封装展开 | 12 | 0 |
| make test RV32 / RV64 | 82 / 82 | 2 / 2 |
| riscv-tests RV32 / RV64 | 58 / 78 | 2 / 2 |
| benchmark-smoke 双宽 | 2 | 0 |
| coremark 双宽 | 0 | 2 |
| 合计 | 318 | 10 |

SKIP 包括 RAS/位宽配置不适用项、ISA 的 fence_i/ma_data 排除及缺失的 CoreMark 目标；缺失目标的命令退出 2，没有当作成功运行。精确命令、日志哈希及计数分类见各版本收据；所有 Verilator 编译实际 -j1。候选阶段 4 PASS 不再叠加到上述正式结果。

下一步由主线程完成启动前序版本的新实现及严格验收，再进行受控短时上板，核对实际 PC=0/4 的指令及是否跳向 0x01000000。只有拿到有效 READY/模型服务，并具备适当散热后，才开展 320/416 固定模型、测试图片和金标对照、重复整网运行与 HDMI 发布验收。

此前真实出现过过温标志，用户确认无散热片、无风扇；当前短时捕获无过温不能替代连续负载散热验证。现阶段模型上传 0、整网推理 0，实际 FPS 和完整系统加速比未测。

## 证据位置与复现边界

| 证据 | 相对位置或环境路径 |
|---|---|
| 首异常源码批准、回归、接线与板测总评估 | `logs/yolo-first-exception-20261102/`，总评估为 `hold0-board-assessment.json` |
| 首异常原始 UART、解析、下载及监温 | 上述目录的 `hold0-board/`；原生副本的 `board-first-exception/` |
| 验收 STA、管脚、位流与运行策略 | `$PDS_WORK_ROOT/work/yolo-first-exception-hold0-20261102/` 中的 `physical-receipt.json`、`boot-observer-pinout.json`、`bitstream-validation.json`、`clone-provenance.json` 和原始日志 |
| 首异常原始实现及失败证据 | `$PDS_WORK_ROOT/work/yolo-first-exception-20261102-r2/` 与对应 preopt/eco 副本 |
| 启动前序批准与正式回归 | `logs/yolo-boot-prefix-20261102/authorization.json`、`regression/receipt.json` |
| 上一轮 LED 的 316 PASS / 10 SKIP 与实板 | `logs/yolo-boot-led-20261101/`、`$PDS_WORK_ROOT/work/yolo-boot-led-20261101/` |
| 测量总账与当前执行入口 | 工作区 `record.md`、`HANDOVER.md`、`OPTIMIZATION_PLAN.md` 和 `log/yolo-current-execution.json` |

工程生成器未自动加载新增 LED 属性，原生运行从已批准 FDC 提取 49 条属性生成 `board_boot_led.fdc` 并仅加载一次；原 DDR/时钟/视频/RCF 不变，最终七个球位已核验。复现需保留该适配、固定 DDR IP、对应固件和完整原生输入，不能仅凭进度文档或旧代码 PR 声称精确复现。

原始收据、日志、位流、ELF、尚未发布的本地诊断源码及运行适配未随本次文档 PR 上传。以下摘要哈希用于核对本机原件，不意味着远端已提供这些文件；精确命令和其余输入哈希保存在对应收据。外部路径使用 `PDS_HOME`、`PDS_WORK_ROOT` 和 `RISCV_TOOL_ROOT`，没有清理或删除原始证据。

| 本机证据文件 | SHA256 |
|---|---|
| `logs/yolo-first-exception-20261102/hold0-board-assessment.json` | `2c87dec90e3c39e3fe617532dd72eefead8c64faea04d0df6933c0b8343b19b7` |
| `logs/yolo-first-exception-20261102/validation/receipt.json` | `b96f8b744344b481dbba81788be296a46c653b69a43cd6bfa00dc5596e8bb479` |
| `logs/yolo-boot-prefix-20261102/regression/receipt.json` | `232b0c617ede1cce39eccef53fa8da3a838356724c217410bcd3513ae260005e` |
