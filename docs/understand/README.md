# 理解与学习文档

本目录保存面向项目学习和设计复核的专题解读。内容应解释当前实现的真实行为、接口时序
和软硬件交互，并明确区分已实现能力、验证环境与未来规划。

- [IRQ 撤销与 MINSTRET 修复](CPU_IRQ_COUNTER_FIX.md)：三个缺陷的原因、最小修复、六分支双位宽回归和保留的非对齐访问策略。

- [无 Cache SoC 与中断闭环](SOC_AND_INTERRUPTS.md)：从 ROM/TCM、MMIO 到中断排空与软件 handler。
- [BRAM、Cache 与存储器握手](MEMORY_HANDSHAKE.md)：解释 IF/MEM ready-valid、等待、
  buffer 与未来阻塞式 Cache 的边界。
- [软件测试栈与硬件交互解读](SOFTWARE_TEST_STACK_GUIDE.md)：跟踪 riscv-tests 从汇编、
  链接、ECALL/Trap 到 `tohost` PASS/FAIL 的完整路径。
- [CoreMark 与性能指标解读](COREMARK_AND_PERFORMANCE.md)：解释裸机 C/BSP/port、周期
  计时、CoreMark/MHz、CoreMark/LUT，以及仿真成绩与 FPGA 成绩的边界。
- [Cache、TCM、DMA 与系统总线设计草案](THINKING.md)：物理地址路由、协议边界、
  DMA 一致性与双平台验证门槛。

新增理解文档时使用具体主题命名，优先链接源码和正式工作流，不在此重复阶段计划或
提交日志；目标与阶段归入 roadmap，修改记录归入 `docs/COMMIT.md`。
