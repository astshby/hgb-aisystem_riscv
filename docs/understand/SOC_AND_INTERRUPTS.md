# 无 Cache SoC 与中断闭环

## 从 Core-only 到 SoC

旧的 `sim_cpu_top` 将取指与数据镜像分开；`soc_top` 用统一物理地址解释两条请求口。
ROM 从 0 跳到 I-TCM 的 `0x01000000`。普通 C/ CoreMark 的数据、栈在
`0x01100000` D-TCM；ISA 测试的代码与数据都在可执行 I-TCM，因此能验证自修改代码。

MEM 接受请求，WB 等待唯一响应。Store 也需要完成响应，错误转为 access fault；
读写都不得因反压重复执行。TCM 是同步存储器，无 Cache miss，不能用它的成绩推断 DDR 延迟。

## 为什么互连增加边界

IF 允许撤回未被接受的错误路径请求；D 请求可能决定流水是否推进及重定向。
若 D-ready 又组合依赖 I-valid，就可能形成控制环。SoC 使用 D 优先仲裁，同 bank
跨 owner 交接隔一拍；I 响应以一项旁路缓冲接收，切断响应反压的组合回路。
独立互连 TB 同时验证默认轮询与 CPU 模式；后者没有无限竞争下的 IF 公平性保证。

## 中断不是带异常的指令

外设电平 → MIP → MIE 与 mstatus.MIE → 停止新取指 → 已入流水指令排空
→ 保存实际后继 PC → Trap CSR 更新 → Direct mtvec。

`interrupt_entry` 从成功退休的 `next_pc` 记录恢复位置，不能一律使用 pc+4：
已退休的条件跳转、JAL、JALR 都可能改变下一条 PC。同步异常、MRET 的 WB 重定向
覆盖这份记录。已经接受的访存和 MDU 先完成；中断本身不增加 MINSTRET。

`mie` 仅实现 MSIE、MTIE、MEIE；`mip` 来自设备，写 CSR 不清 pending。
机器中断优先级为外部 > 软件 > 定时器。关闭全局使能不妨碍设备保持 pending。

## 软件如何清除源

机器 Timer 提供 MSIP、MTIME、MTIMECMP。外部控制器聚合 UART、通用 Timer 与 GPIO，
提供优先级、使能、阈值、claim/complete；它不是完整 PLIC 实现。
软件先 claim，再处理并清除设备条件，最后 complete，否则持续电平会再次 pending。

`make soc-software XLEN=32/64` 运行真正的 C handler 和 MRET：
UART/GPIO 从引脚环回，全部六路外部源、软件/定时器中断以及访问错误均由软件检查。
不是 TB 直接修改 CSR，也不是用 tohost 模拟中断。tohost 仅由 TB 被动观察退出结果。

## 验证和未实现边界

SoC 的 riscv-tests 为 RV32 59 / RV64 79 PASS，只有 ma_data 明确 SKIP；
旧路径仍为 58/78 PASS、两项 SKIP。CoreMark 默认 m0d0 的计时区间与旧路径相同，
ROM 启动多出的 6 拍不计入分数。benchmark 字符输出仍为被动 RAM 镜像，不是 UART。

完整寄存器和约束见 [外设接口](../SOC_PERIPHERALS.md)，运行入口见
[仿真说明](../SIMULATION_AND_FPGA.md)。DMA、DDR、Cache、厂商 IP 和板级时序尚未完成；
现有仿真通过不等于 FPGA 已验证。
