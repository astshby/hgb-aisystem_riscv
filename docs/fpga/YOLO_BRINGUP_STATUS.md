# YOLO 上板进度与问题

发布状态：维护者已暂停`yolo`名称，改以`yolo-debug`保存现有代码和继续调试。
本报告下方的历史yolo基线、固件/位流身份和失败记录保留原值；分支改名不构成新的验证。


截至 2026-11-01（北京时间）。这是一份当前状态报告，后续覆盖更新；历史过程以 Git 和原始日志为准。

完整 YOLO 尚未跑通。小型独立 UART/NPU 板测已通过，但完整 SoC 在有效 KEY0 复位后仍无启动日志，模型上传和整网推理均为 0 次。当前定位重点是完整 SoC 的时钟、复位、CPU 启动和首次 MMIO 访问，尚未确认根因。

## 代码与测量身份

| 项目 | 身份或状态 |
|---|---|
| 本报告的远程代码基线 | `yolo` / `dc5dfe51883c3e70edbe3d1efb166c731b662476` |
| 已完成测量的本地源码 | `diag/yolo-early-start-20261101` / `b5048241efc8f2474c770ec3a570cbb8113ab431` |
| 测量源码的前序修复 | `c3905ae0c089b91297f0f562cc19506d9f082aff`，首次帧缓冲访问前等待 DDR 就绪 |
| 本轮新增启动诊断 | 仅 `software/common/baremetal/crt0.S`，栈前输出 S:0、栈建立后 S:1、BSS 后 S:2、原异常入口 T: |
| RV32 固件 ID | `9ffe18ef0f222245` |
| RV64 固件 ID | `23a94713abe3d154`，仅构建与仿真，无 RV64 上板成绩 |
| RV32 ELF SHA256 | `ef1701903f9a434ebe55558d9589656f2a5c846f599acb3e907fa1faf8bd7c21` |
| RV32 位流 SHA256 | `7600958d855e65ab2c5176a9b57e87ad361eccce24fff700a8459b7617ba00f3` |

远程最新提交补入了 320/416 完整模型、固定图片和可重建的软件依赖。本报告的既有测量来自上述本地旧基线加已批准诊断，不自动成为最新远程代码或后续 LED 改动的成绩。本次文档 PR 不包含这两项本地固件改动。

## 已完成的验证

| 层次 | 结果 | 边界 |
|---|---|---|
| 软件回归 | 70 PASS / 0 SKIP | 既有诊断测量基线 |
| RV32/RV64 固件构建与 ISA 审计 | 均通过 | 不包含板上整网 |
| 真实 Core/UART 启动仿真 | 6 PASS | 双宽各正常、DDR 延迟、DDR 超时；验证 S/B 标记、READY CRC、超时 E2 和退出行为 |
| benchmark-smoke | 2 PASS | 双宽各一次 |
| CoreMark | 2 SKIP | 测量时分支缺少目标和源码；不能填入成绩 |
| 厂商原语 TCM 组件检查 | 1 PASS | 前序 f279 实际 RV32 SYN 的 32 个 DRM，32768 字双端口、字节写和 CE 保持；非完整 CPU/板测 |
| SYN 启动 ROM 组件检查 | 1 PASS | 5 个保留数据位、6 地址及本地握手；不覆盖跨层次别名、AXI 消费者或完整 CPU |
| 独立 UART/NPU 实际板测 | 3 个卷积案例通过 | 12 输出向量，192 原始值和 192 量化值匹配；不是完整 YOLO |
| 原厂 HDMI 彩条 | 用户确认出图 | 仅证明当时显示链路可用，不代表 YOLO 视频链路成功 |

启动仿真使用行为 DDR：SoC 译码 512 MiB、测试 backing 128 MiB，未模拟物理 DDR PHY/PLL，且启动测试未连接视频取帧 DMA。此前未运行 `make test` / `riscv-tests` 全矩阵，因为该轮仅修改软件启动代码；LED RTL 应用后须执行对应双宽与适用回归。串口解析重放不计作额外固件启动次数。

## RV32 原生实现

PDS 2025.2、PG2L200H-6IFBB676、C10、I-cache 16 KiB / D-cache 8 KiB、hash2、timing-v2、fanout64、route slack weight 80，八线程。RTL 和约束 183 份与前序 f279 工程逐字节一致；本轮仅变更启动固件及其初始化输入。

最终未布线网为 0，慢/快角的 setup、hold、recovery、removal、最小脉宽和 skew 共 12 项内部检查通过，无负余量或空检查表。状态为 `INTERNAL_STA_PASS_WITH_RECORDED_DIAGNOSTICS`，`engineering_signoff=false`、`external_io_signoff=false`。

| 时钟域 | 配置频率 MHz | STA Fmax MHz | setup 余量 ns |
|---|---:|---:|---:|
| Core | 83.8068 | 85.7177 | 0.266 |
| SYS | 102.4306 | 107.7624 | 0.483 |
| DDR 用户 | 125.0000 | 133.0495 | 0.484 |
| 外设 | 65.8482 | 72.9161 | 1.472 |
| NPU | 92.1875 | 97.3858 | 0.579 |
| 视频 | 148.5000 | 160.7715 | 0.514 |

这些是配置频率和 STA 结果，不是板上频率、推理 FPS 或外部 DDR/HDMI 签核。最差慢角路径为 issue packet 寄存器到乘法 APM，setup 余量 0.266 ns，数据延时 9.844 ns（逻辑 4.052、布线 5.792），4 级逻辑、扇出 97。

综合估计为 LUT 69247、FF 73127、DRM 168、APM 86；布线后实体账本为 LUT 69283.5、FF 73108、DRM 168、APM 86。实体账本与器件 grid 占用分别保存，不混用。

| 阶段 | 原生耗时 s | 工具内存池峰值 MB |
|---|---:|---:|
| compile | 161 | 1188 |
| synthesize | 3078 | 4365 |
| dev_map | 2584 | 1761 |
| place | 2019 | 8999 |
| route | 6964 | 5478 |
| route_optimize | 242 | 5770 |
| report_timing | 231 | 6542 |
| gen_bit_stream | 77 | 3523 |

工具内存池峰值不等于 Windows 提交峰值。阶段入口及 dev_map/place/route/route_optimize 边界均按 Windows 可用物理内存与可用提交至少 6 GiB 执行门禁，并约 10 分钟采样。未改分页、未终止无关进程，未改变时钟约束数字或新增同步路径 false path。

仍保留两类原生严重诊断：DDR `ref_clk` 的部分时钟负载未经过缓冲，以及部分 IO 使用默认属性。CDC 已绑定实际对象（40 FIFO、752 同步寄存器、202 max-delay、82 max-skew），但这些检查不代替外部 IO 和板级工程签核。

## 板上现象与判断

1. USB-UART 曾出现 Windows 设备错误，早期无回传结果不能直接归因于 CPU。完整重接后收到原厂程序 10 行文字、190 字节，回传恢复；随后在 COM11、115200 下独立 100 MHz UART/NPU 自检通过，测后过温标志为 0。
2. 完整重接过程中，两次配置和回读均返回成功，但状态 `081ffca0` 的 bit27 `over_temp` 为 1，因此验收拒绝继续。官方配置手册将其定义为过温标志，实际摄氏温度未测。用户确认芯片无散热片、无风扇。
3. 冷却后状态为 `00180c80`，过温 0、DONE 0，断电已丢失易失配置。后续新版完整固件配置/回读和 USERCODE `9ffe18ef` 检查通过。
4. 有效 KEY0 确认发生于 15:56:42，监测器在有效窗口接收确认后继续捕获 10 秒：整个窗口 RX0，无 S/B/T、READY 或模型服务响应，期间过温 0。前两组按键确认到达时窗口已结束，不计为有效复位失败。
5. 观察结束调用官方 `cfg_reset_fpga`，确认 DONE0，停止配置。这里的“无画面”不能单独证明视频没有挂总线：视频控制口 `0x10070000` 和 DDR 主口 3 已静态确认连接，实际视频 DMA、完整推理及显示发布仍未验证。

S:0 自身包含 UART MMIO 访问，事务可能停滞；“没有 S:0”不能证明 CPU 从未执行。独立 NPU 成功也不能证明完整 SoC 的 CPU、DDR、总线或视频成功。无过温条件下仍无启动日志，因此过温并非已证明的唯一启动根因。

## 下一步整改

继续在目的分支实施板级 LED 观察，保留现有 LED0 的 DDR/复位指示。新增 LED1/2/3 观察 Core/SYS/外设时钟心跳，LED4/5/6/7 分别锁存标量提交口活动、ITCM 地址范围提交、UART 发送低电平和提交异常。标量口不等于双发射所有退休事件，UART 低电平也不等于有效串口帧。

范围为板级顶层、新增观察模块、7 个 LED 管脚约束、FPGA 源清单，以及聚焦测试和入口，共 7 文件。草案 RV32/RV64 聚焦测试 2 PASS，`git apply --check` 通过；报告截点尚未应用。用户已授权继续整改。逻辑不反馈控制总线、复位或时钟，固件/PLL/原时序约束不变，但增加寄存器、PC 扇出和 IO 负载，必须重新测资源和时序，不能沿用上表。

先跑双宽聚焦与适用回归，再以新目录单独运行 Windows PDS，记录全部阶段成本和时序，内部验收后才短时上板。连续整网运行前需改善散热；新测量只在实际取得后填写。

只有完整固件出现有效 READY 或模型服务响应后，才上传模型、比对 320/416 固定输入、重复整网检测和检查 HDMI 发布。当前板上模型上传 0 次、整网推理 0 次，CPU/DDR 启动卡点、板上视频 DMA、检测框显示、实际 FPS 均未完成。

## 证据位置与复现限制

| 证据 | 位置 |
|---|---|
| 固件构建、6 项启动仿真及基准收据 | `logs/yolo-early-start-20261101/` |
| 固件 ELF/HEX 及 manifest | `build/yolo-early-start-20261101/firmware-rv{32,64}/` |
| 独立 NPU 配置、功能与测后状态 | `$PDS_WORK_ROOT/work/yolo-early-start-20261101/uart-link-after-cooling/` |
| 有效 KEY0 原始捕获、过温采样、软复位 | `$PDS_WORK_ROOT/work/yolo-early-start-20261101/board-early-start-key-watch/` |
| 原生输入、时序、位流与阶段成本 | `$PDS_WORK_ROOT/work/yolo-early-start-20261101/{manifest,physical-receipt,bitstream-validation,phase-costs,routed-resource-views}.json` |
| PDS 原始日志/报告 | 同工程的 `phase-logs-*`、`prj_tasks/`、`bitgen-yolo-early-start.log` |
| 草案测试结果 | `logs/yolo-boot-led-proposal-20261101/final/receipt.json` |

精确命令、输入及日志 SHA 保存在各收据和 manifest；工程变量使用 `PDS_HOME`、`PDS_WORK_ROOT` 和 `RISCV_TOOL_ROOT`。原始日志、位流、ELF 和本地诊断分支未随这个文档 PR 上传；其他机器仍需取得对应原件或按固定输入重跑，文档本身不构成完整可复现交付包。
