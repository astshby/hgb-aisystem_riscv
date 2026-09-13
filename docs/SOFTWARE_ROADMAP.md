# RISC-V Edge-AI SoC 软件开发目标（参考稿）

> 面向 2026 紫光同创赛题一。  
> 当前比赛硬件目标：盘古 676 200K 级 FPGA 平台 + 自研 RV64 RISC-V CPU；Zynq-7020/Vivado 可继续作为熟悉的早期验证平台，但不作为最终比赛平台。  
> 当前定位：先建立可运行、可调试、可测试的软件栈，再逐步加入 AI Runtime 与 Agent Runtime。  
> 本文是“软件栈参考方案”，不是最终冻结设计。

---

# 0. 总目标

最终作品不只是一颗 CPU，而是一套：

```text
RISC-V CPU
    ↓
SoC / Bus / Memory / Peripheral
    ↓
BSP / Driver / Runtime
    ↓
AI Runtime / Accelerator Driver
    ↓
Agent Runtime
    ↓
Edge-AI Application
```

建议最终作品定位为：

> **基于自研 RV64 RISC-V CPU、AI 指令扩展与 FPGA AI 加速器的边缘视觉 Agent SoC**

目标同时覆盖：

- CPU 性能；
- RV64 / Zicsr / M / C；
- Cache / DDR / 总线；
- UART / GPIO / Timer / Interrupt；
- AI 指令；
- AI accelerator；
- Camera / HDMI / Ethernet 等外设；
- Agent 应用；
- CoreMark；
- FPGA 上板演示。

---

# 1. 软件栈总览

推荐软件层次：

```text
┌──────────────────────────────────────────────┐
│                  Application                 │
│   Vision Agent / Inspection / Smart Tool     │
├──────────────────────────────────────────────┤
│                Agent Runtime                 │
│ Observe / State / Policy / Tool / Action     │
├──────────────────────────────────────────────┤
│                  AI Runtime                  │
│ Tensor / Model / Quant / Operator / Driver   │
├──────────────────────────────────────────────┤
│                Middleware                    │
│ CLI / Protocol / Buffer / Event / Logger     │
├──────────────────────────────────────────────┤
│                  BSP / HAL                   │
│ UART / GPIO / Timer / DMA / Camera / AI IP   │
├──────────────────────────────────────────────┤
│              Low-level Runtime               │
│ crt0 / trap / interrupt / libc subset        │
├──────────────────────────────────────────────┤
│                 ISA / ABI                    │
│ RV64I → RV64IM → RV64IMC + Zicsr + AI ext   │
├──────────────────────────────────────────────┤
│                  Hardware                    │
│ CPU / Cache / Bus / DDR / Accelerator / IO   │
└──────────────────────────────────────────────┘
```

原则：

> 软件层只能依赖下层公开接口，不能直接知道内部 RTL 细节。

例如 Agent 不应该知道：

```text
BTB
Pipeline
CSR bypass
```

它只应该知道：

```text
camera_capture()
ai_detect()
gpio_set()
uart_log()
```

---

# 2. ISA / ABI 层

## 2.1 第一阶段

目标：

```text
RV64I_Zicsr
ABI: lp64
```

工具链示例：

```text
riscv64-unknown-elf-gcc
-march=rv64i_zicsr
-mabi=lp64
```

用途：

- riscv-tests；
- 自己的汇编测试；
- C 程序；
- CoreMark；
- BSP bring-up。

## 2.2 第二阶段：M

目标：

```text
RV64IM_Zicsr
```

编译：

```text
-march=rv64im_zicsr
-mabi=lp64
```

M 扩展完成以后：

- 整数乘法不再全部依赖软件 helper；
- CoreMark 性能应改善；
- AI Runtime 中的标量整数计算更自然。

## 2.3 第三阶段：C

目标：

```text
RV64IMC_Zicsr
```

编译：

```text
-march=rv64imc_zicsr
-mabi=lp64
```

主要收益：

- code size；
- instruction fetch bandwidth；
- I-Cache utilization。

## 2.4 自定义 AI ISA

后期增加，例如：

```text
DOT8
MAC8
QCLIP
```

软件侧需要配套：

```text
compiler intrinsic
或
inline asm
```

例如：

```c
int32_t ai_dot8(uint32_t a, uint32_t b);
```

第一阶段不必修改 GCC backend。

---

# 3. Boot / Startup Runtime

CPU reset 后首先执行：

```text
reset_vector
    ↓
_start
    ↓
crt0.S
```

建议建立：

```text
software/
└── runtime/
    ├── crt0.S
    ├── trap_entry.S
    ├── runtime.c
    └── link.ld
```

`crt0.S` 负责：

- 设置 stack pointer；
- 初始化 `.data`；
- 清零 `.bss`；
- 可选初始化 global pointer；
- 设置 `mtvec`；
- 调用 `main()`；
- main 返回后的退出行为。

流程：

```text
Reset
 ↓
Set SP
 ↓
Init .data
 ↓
Clear .bss
 ↓
Set mtvec
 ↓
main()
```

---

# 4. Trap / Interrupt Runtime

当硬件实现：

```text
ECALL
EBREAK
MRET
Zicsr
mtvec
mepc
mcause
mtval
```

软件侧建立统一 trap runtime：

```text
runtime/
├── trap_entry.S
├── trap.c
└── csr.h
```

硬件跳到 `mtvec` 后：

```text
save registers
 ↓
read mcause
 ↓
dispatch handler
 ↓
restore registers
 ↓
mret
```

CSR helper：

```c
uint64_t csr_read_mcycle(void);
uint64_t csr_read_minstret(void);
void csr_write_mtvec(uint64_t addr);
```

用途：

- CoreMark timing；
- exception debugging；
- performance statistics。

---

# 5. BSP / HAL

BSP = Board Support Package。  
HAL = Hardware Abstraction Layer。

建议：

```text
software/
└── bsp/
    ├── platform.h
    ├── memory_map.h
    ├── uart.c
    ├── uart.h
    ├── gpio.c
    ├── gpio.h
    ├── timer.c
    ├── timer.h
    ├── interrupt.c
    ├── interrupt.h
    ├── dma.c
    ├── dma.h
    ├── cache.c
    └── cache.h
```

---

# 6. MMIO：软件认识硬件的第一步

软件无需知道 UART RTL 如何实现，只需要知道地址。

例如：

```text
UART_BASE = 0x1000_0000
```

软件：

```c
#define UART_TXDATA (*(volatile uint32_t *)(UART_BASE + 0x00))
```

之后：

```c
uart_putc('A');
```

硬件 bus/interconnect 根据地址把请求送到 UART。

参考 memory map（暂不冻结）：

```text
0x0000_0000   Boot/BRAM
0x1000_0000   UART
0x1000_1000   GPIO
0x1000_2000   Timer
0x1000_3000   Interrupt Controller
0x1000_4000   DMA
0x2000_0000   AI Accelerator MMIO
0x3000_0000   Camera / Video Control
0x8000_0000   DDR
```

---

# 7. UART

第一阶段只需要 TX：

```c
void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
```

之后增加：

```c
void uart_print_hex(uint64_t x);
void uart_print_dec(uint64_t x);
```

用途：

- riscv-tests debug；
- CoreMark output；
- trap error；
- Agent log；
- AI detection result。

不必一开始移植完整 `printf`。

---

# 8. GPIO

GPIO 是 Agent 最简单的 Action Tool。

接口：

```c
void gpio_write(unsigned pin, int value);
int  gpio_read(unsigned pin);
```

例如：

```text
发现异常
 ↓
gpio_write(ALARM_LED, 1)
```

---

# 9. Timer

`mcycle`：

```text
CPU cycle counter
```

适合：

- CoreMark；
- microbenchmark。

Timer peripheral：

```text
time compare
 ↓
interrupt
```

适合：

- periodic task；
- timeout；
- Agent scheduling；
- RTOS tick。

第一阶段 `mcycle` 足以支持 CoreMark。之后再增加 64-bit timer + compare + timer interrupt。

---

# 10. Interrupt Controller

初期可以支持：

```text
UART
Timer
GPIO
AI done
DMA done
```

统一：

```text
Interrupt Sources
      ↓
Interrupt Controller
      ↓
CPU interrupt
```

软件：

```c
irq_dispatch();
```

第一版不要求完整 PLIC，但接口应允许未来替换。

---

# 11. Cache 软件支持

I-Cache / D-Cache 主体是硬件，但软件最终要关心：

- DMA coherence；
- cache flush；
- cache invalidate。

典型问题：

```text
CPU writes tensor
 ↓
D-Cache
 ↓
DMA reads DDR
```

如果 cache 里数据还没写回，DMA 可能读到旧数据。

因此最终 HAL 需要：

```c
cache_flush(addr, size);
cache_invalidate(addr, size);
```

---

# 12. DDR 软件层

DDR 对软件主要表现为大容量普通内存。

用途：

- program/data；
- CoreMark；
- framebuffer；
- AI tensor；
- model weights；
- camera frame。

第一阶段可：

```text
BRAM boot
 ↓
DDR application/data
```

后续也可以：

```text
Flash/SD
 ↓
load program/model
 ↓
DDR
```

---

# 13. DMA

没有 DMA：

```text
CPU:
load
store
load
store
...
```

有 DMA：

```text
CPU:
配置 src/dst/len
 ↓
DMA 自动搬运
 ↓
interrupt done
```

软件接口：

```c
dma_memcpy(dst, src, len);
dma_wait();
```

最终：

```text
Camera
 ↓ DMA
DDR
 ↓ DMA
AI Accelerator
 ↓
result
```

CPU 主要负责控制。

---

# 14. AI Accelerator Driver

应用不要直接写 accelerator register。

目录：

```text
software/
└── drivers/
    └── ai_accel/
        ├── ai_accel.c
        └── ai_accel.h
```

例如：

```c
typedef struct {
    void *input;
    void *weights;
    void *output;

    uint32_t width;
    uint32_t height;
    uint32_t channels;
} ai_job_t;
```

接口：

```c
int ai_submit(ai_job_t *job);
int ai_wait(void);
int ai_run(ai_job_t *job);
```

底层负责：

```text
MMIO
cache flush
DMA
start accelerator
interrupt/poll
cache invalidate
```

---

# 15. AI Runtime

Driver 之上增加简单 AI Runtime：

```text
software/
└── ai/
    ├── tensor.h
    ├── quant.c
    ├── ops/
    │   ├── conv.c
    │   ├── relu.c
    │   ├── pool.c
    │   └── softmax.c
    ├── model.c
    └── runtime.c
```

优先：

```text
INT8
```

而不是 FP32。

原因：

- FPGA 资源效率；
- DSP 利用率；
- AI instruction 易设计；
- bandwidth 小。

Runtime 决定：

```text
哪些 op 用 CPU
哪些 op 用 AI instruction
哪些 op 调 accelerator
```

---

# 16. AI 指令软件接口

不要让应用直接写 inline asm。

建立：

```text
software/
└── ai/
    └── intrinsics/
        └── ai_intrin.h
```

例如：

```c
int32_t rv_ai_dot8(uint32_t a, uint32_t b);
int32_t rv_ai_mac8(uint32_t a, uint32_t b, int32_t acc);
int8_t  rv_ai_qclip(int32_t value);
```

内部再使用 custom instruction。

这样以后修改 opcode，只需修改 intrinsics 层。

---

# 17. Agent Runtime

目录：

```text
software/
└── agent/
    ├── agent.c
    ├── agent.h
    ├── state.c
    ├── policy.c
    ├── event.c
    └── tools/
        ├── camera_tool.c
        ├── vision_tool.c
        ├── gpio_tool.c
        ├── uart_tool.c
        └── network_tool.c
```

最小 Agent 模型：

```text
Observe
 ↓
Update State
 ↓
Decide
 ↓
Call Tool
 ↓
Observe Result
```

例如：

```c
for (;;) {
    event = agent_observe();
    agent_update_state(event);

    action = agent_decide();
    agent_execute(action);
}
```

---

# 18. Tool abstraction

例如：

```c
tool_camera_capture();
tool_ai_detect();
tool_gpio_alarm();
tool_uart_log();
tool_display_overlay();
```

Agent 看到的是 Tool API，而不是硬件寄存器。

---

# 19. 推荐 Agent 应用

优先：

> **智能视觉巡检 Agent**

流程：

```text
Camera
 ↓
Capture
 ↓
AI Detection
 ↓
Agent State
 ↓
Policy
 ├─ normal → continue
 ├─ uncertain → detect again
 └─ danger → alarm + log + overlay
```

例如：

```text
检测人
检测安全帽
连续两帧确认
报警
记录时间
HDMI 标框
UART 输出
```

优势：

- AI 加速有实际任务；
- Agent 有连续决策；
- GPIO/UART/Display 都有用途；
- FPGA 视觉链可展示；
- 软件栈完整。

---

# 20. PC / LLM Agent 扩展

后期可增加：

```text
PC LLM
  │
Ethernet/UART
  │
  ▼
RISC-V Edge Agent
```

自然语言：

```text
“监控是否有人未戴安全帽，如果连续看到两次就报警。”
```

上位机 LLM 转换为 policy/configuration。

真正执行：

```text
camera
AI inference
state tracking
alarm
```

仍在自研 RISC-V SoC。

这种方案比直接在 softcore 上跑完整大模型风险低很多。

---

# 21. Middleware

随着系统复杂，可以增加：

```text
software/
└── middleware/
    ├── event_queue.c
    ├── ring_buffer.c
    ├── logger.c
    ├── protocol.c
    └── cli.c
```

UART CLI 示例：

```text
> perf
cycles: ...
instret: ...

> gpio 0 1

> ai run

> agent start
```

---

# 22. Bare-metal → RTOS 演进

第一阶段建议 Bare-metal，直到：

```text
CPU
UART
GPIO
Timer
Interrupt
DDR
DMA
AI accelerator
CoreMark
Agent prototype
```

全部跑通。

之后可选：

```text
FreeRTOS
```

任务：

```text
camera_task
ai_task
agent_task
uart_task
display_task
```

暂时不建议 Linux，因为会引入：

```text
S-mode
MMU
page table
virtual memory
更完整的中断/时钟模型
drivers
filesystem
boot flow
```

---

# 23. Host Tools

PC 端也属于软件栈：

```text
host/
├── serial_monitor.py
├── model_convert.py
├── image_convert.py
├── perf_analyze.py
├── agent_console.py
└── visualization.py
```

用途：

- UART 日志；
- 模型量化/转换；
- 图片预处理；
- 性能统计；
- Agent 配置；
- 可视化。

---

# 24. 推荐软件目录

```text
software/
├── runtime/
│   ├── crt0.S
│   ├── trap_entry.S
│   ├── trap.c
│   └── link.ld
│
├── include/
│   ├── csr.h
│   └── platform.h
│
├── bsp/
│   ├── uart/
│   ├── gpio/
│   ├── timer/
│   ├── interrupt/
│   ├── dma/
│   ├── cache/
│   └── video/
│
├── drivers/
│   └── ai_accel/
│
├── libc/
│   └── minimal/
│
├── ai/
│   ├── intrinsics/
│   ├── tensor/
│   ├── ops/
│   ├── model/
│   └── runtime/
│
├── agent/
│   ├── runtime/
│   ├── policy/
│   └── tools/
│
├── apps/
│   ├── hello/
│   ├── uart_test/
│   ├── gpio_test/
│   ├── coremark/
│   ├── ai_demo/
│   └── vision_agent/
│
└── tests/
    ├── runtime/
    ├── bsp/
    ├── ai/
    └── agent/
```

PC：

```text
host/
├── scripts/
├── model_tools/
├── uart/
├── perf/
└── agent_console/
```

---

# 25. 软件与硬件接口原则

每新增一个 hardware IP，同时定义：

```text
1. Register map
2. Driver API
3. Interrupt behavior
4. DMA/cache behavior
5. Unit test
6. Example application
```

例如 AI Accelerator：

```text
hardware:
ai_accel.sv

document:
ai_accel_registers.md

software:
ai_accel.c
ai_accel.h

test:
ai_accel_test.c
```

禁止出现：

> FPGA 模块已经做好，但没有软件方法使用它。

---

# 26. CoreMark 软件路径

当前 A5 已在 `benchmark/` 落地第一阶段的独立裸机 BSP 与 CoreMark port：仿真字符
Store 代替尚未实现的 UART，`mcycle` 代替外设 Timer，ECALL 后通过 `tohost` 结束。
RV32/RV64 的 performance 与 validation CRC 均已通过；执行方法、当前分数及 FPGA
指标边界见 [CoreMark 与性能指标解读](understand/COREMARK_AND_PERFORMANCE.md)。

```text
crt0
 ↓
BSP
 ↓
CoreMark
 ↓
mcycle / minstret
 ↓
UART
```

阶段一：

```text
RV64I_Zicsr
```

阶段二：

```text
RV64IM_Zicsr
```

重新测试：

```text
CoreMark
CoreMark/MHz
CoreMark/LUT
```

阶段三：

```text
RV64IMC_Zicsr
```

比较：

```text
code size
I-cache behavior
CoreMark
```

---

# 27. 软件验证层级

```text
Level 0：runtime/BSP 编译
Level 1：UART/GPIO/Timer
Level 2：ECALL/EBREAK/illegal/interrupt
Level 3：BRAM/DDR/Cache/DMA
Level 4：riscv-tests/CoreMark
Level 5：AI instruction / accelerator / model
Level 6：Agent Observe→Decision→Tool→Action
```

---

# 28. 推荐开发顺序

## S0：Minimal Runtime

```text
crt0
link.ld
UART
hello world
```

## S1：RV64I + Zicsr

```text
CSR helper
trap runtime
riscv-tests harness
CoreMark port
```

## S2：Basic SoC

```text
GPIO
Timer
Interrupt
CLI
```

## S3：Memory System

```text
Cache support
DDR
DMA
```

## S4：M Extension

```text
重新编译 RV64IM
benchmark regression
```

## S5：AI Instruction

```text
intrinsics
microbenchmark
operator optimization
```

## S6：AI Accelerator

```text
driver
tensor runtime
model loading
DMA path
```

## S7：C Extension

```text
重新使用 RV64IMC 编译
```

## S8：Vision Agent

```text
camera tool
vision tool
gpio tool
display tool
state
policy
event loop
```

## S9：Optional PC LLM

```text
network/UART protocol
agent configuration
natural-language → policy
```

---

# 29. 最终比赛软件栈目标

```text
Application:
    Vision Inspection Agent

Agent:
    Event + State + Policy + Tool Runtime

AI:
    INT8 model runtime
    AI custom instruction
    FPGA accelerator

Middleware:
    CLI
    logger
    event queue

BSP:
    UART
    GPIO
    Timer
    Interrupt
    DMA
    Cache
    Video
    Ethernet（可选）

Runtime:
    crt0
    trap
    linker
    minimal libc

ISA:
    RV64IMC_Zicsr
    + custom AI extension

Hardware:
    6-stage RV64 CPU
    BTB/GShare
    I/D Cache
    DDR
    Bus
    AI Accelerator
```

---

# 30. 当前最应该优先学习的五个软件概念

按顺序：

```text
1. Linker Script + crt0
2. MMIO + BSP Driver
3. Trap / Interrupt Handler
4. Cache / DDR / DMA 的软件关系
5. AI Accelerator Driver
```

暂时不要优先钻：

```text
Linux kernel
Python on RISC-V
完整 LLM runtime
复杂网络协议栈
```

---

# 31. 与赛题方向的对应

赛题一基础任务要求 RV32I、至少三级流水以及 UART/GPIO 等外设；高阶方向明确包含 2 路组相联 I/D Cache、总线突发效率、BTB、完整异常/中断和边缘 AI 加速。赛题还要求 AI 模型与传感器/显示设备结合完成图形加速、语义识别或机械控制等应用。

当前已向主办方确认可采用 RV64，因此比赛实现可以以 RV64 为主，同时保留 RV32 构建能力。

比赛目标硬件平台确定为盘古 676 200K 级 FPGA，因此软件/SoC 规划从一开始就应考虑 DDR3、UART、HDMI/Camera、可选 Ethernet，以及后期的 Cache、DMA 与 AI Accelerator。

Zynq-7020/Vivado 仍可作为已有经验较多的早期 smoke-test 平台，但新设计不得依赖 Xilinx 专有接口。Core、Bus contract、Driver API 应保持平台无关，以便最终迁移到紫光同创 FPGA/PDS。

---

# 32. 当前暂不冻结的决策

以下先保留选择空间：

- 是否使用 FreeRTOS；
- AI 模型最终是 YOLO、MobileNet 还是自定义轻量网络；
- AI accelerator 是 CNN 专用还是 GEMM 型；
- 自定义 AI ISA 的最终 opcode；
- Ethernet 是否成为比赛必需链路；
- Agent 是否连接 PC LLM；
- Camera 与 HDMI 的最终数据路径；
- 是否加入 SD/Flash model loader；
- C 完成后优先深化流水还是实现 F。

这些都应在：

```text
RV64 + Zicsr + riscv-tests + CoreMark
```

稳定后再冻结。

---

# 33. 一句话架构

> **CPU 负责控制与通用计算，Cache/DDR/DMA 负责数据供给，AI 指令负责细粒度算子，FPGA AI Accelerator 负责大规模并行计算，Agent Runtime 负责把感知结果转换为连续决策和真实外设动作。**

---

# 34. 从高水平 RISC-V 应用方向得到的启发

现有路线已经包含：

```text
RV64 CPU
→ SoC
→ BSP/Driver
→ AI Runtime
→ Agent Runtime
→ Edge-AI Application
```

高水平 RISC-V 应用类项目进一步说明：真正有竞争力的作品通常不是“单点算法 Demo”，而是形成完整链路：

```text
计算平台
→ 软件接口
→ Tool
→ AI/Agent
→ 实际应用
```

对本项目最值得借鉴的有四点：

1. **Agent 的核心不是一定要本地跑大模型，而是 Tool + State + Decision + Action。**
2. **端侧负责实时视觉和控制，Host/Cloud LLM 可以只负责自然语言理解和高级任务规划。**
3. **自定义 ISA 不应停留在 RTL 波形，应贯通 Intrinsic → Operator → Model → Application。**
4. **RISC-V 软核本身应成为应用亮点，而不是被 AI Accelerator 掩盖。**

因此建议把作品重新定义为：

> **RISC-V Native Edge-Agent SoC**

这里的 Native 表示：感知、工具调用、状态维护、实时决策和物理动作都建立在自研 RISC-V SoC 的原生能力上；Host/Cloud LLM 只是可选增强。

---

# 35. 更新后的作品总架构

```text
            Natural Language / Goal
               Host LLM（可选）
                      │
                structured policy
                      │
                      ▼
┌────────────────────────────────────────┐
│          RISC-V Edge Agent             │
│                                        │
│ Observe → State → Policy → Tool → Act │
│                                        │
│ Camera Tool   Vision Tool   Perf Tool  │
│ GPIO Tool     Display Tool  Timer Tool │
└──────────────────┬─────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────┐
│ AI Runtime / Middleware / BSP          │
│ Tensor / Intrinsic / DMA / Video       │
└──────────────────┬─────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────┐
│ SoC                                    │
│ RV64 CPU / Cache / DDR / DMA / AI IP  │
│ AI ISA / UART / GPIO / Timer / Video   │
└────────────────────────────────────────┘
```

关键原则：

> Level-1 Edge Agent 必须在没有网络、没有云端 LLM 的情况下独立工作。

这样比赛现场不会把核心功能绑定到网络质量。

---

# 36. Agent Runtime 进一步拆分

前面的最小循环：

```c
for (;;) {
    event = agent_observe();
    agent_update_state(event);
    action = agent_decide();
    agent_execute(action);
}
```

可以作为第一版，但工程上建议进一步拆为以下模块。

## 36.1 Tool Registry

Agent 不应该直接操作 MMIO。

它看到的是：

```text
camera.capture
vision.detect
gpio.set
display.overlay
timer.now
perf.read
```

而背后映射为：

```text
Tool
 ↓
C Driver
 ↓
MMIO / DMA
 ↓
RTL IP
```

例如：

```text
vision.detect
 ↓
ai_runtime_detect()
 ↓
ai_accel.c
 ↓
DMA + MMIO
 ↓
AI Accelerator
```

这会把“Agent”和“软硬件协同”真正连接起来。

## 36.2 State Store

Agent 需要跨帧保存状态，例如：

```text
Frame 1：检测到 person
Frame 2：检测到 person
→ 连续两帧确认
→ 报警
```

可维护：

```c
typedef struct {
    unsigned confirm_count;
    unsigned alarm_active;
    uint64_t last_detection_time;
} agent_state_t;
```

后期可继续加入：

- tracking ID；
- 最近 N 帧结果；
- timeout；
- 当前 Goal；
- 最近一次 Action；
- performance profile。

## 36.3 Policy Engine

第一版建议：

```text
规则 + 有限状态机 + 阈值
```

而不是本地 LLM。

Host LLM 后期只修改：

```text
target
threshold
confirm_frames
action
```

RISC-V 执行结构化 policy。

## 36.4 Event Bus / Scheduler

后期事件来源包括：

```text
Frame Ready
AI Done
Timer
GPIO
Host Command
Error
```

可以统一成：

```c
typedef enum {
    EVENT_FRAME_READY,
    EVENT_AI_DONE,
    EVENT_TIMER,
    EVENT_GPIO,
    EVENT_HOST_COMMAND,
    EVENT_ERROR
} event_type_t;
```

Bare-metal 第一版可以 cooperative scheduling；复杂度明显上升以后再考虑 FreeRTOS。

---

# 37. Hardware Tool：最重要的软硬件接口模式

建议每个硬件能力都形成完整五层映射：

```text
RTL IP
  ↓
MMIO / Bus Interface
  ↓
Driver
  ↓
Tool API
  ↓
Agent
```

例如：

| Tool | 软件 API | 硬件 | 用途 |
|---|---|---|---|
| Camera Tool | `camera_capture()` | Camera/DMA | Observation |
| Vision Tool | `ai_detect()` | AI Accelerator/AI ISA | 推理 |
| GPIO Tool | `gpio_write()` | GPIO | 报警/动作 |
| Display Tool | `overlay_draw()` | HDMI/Framebuffer | 可视化 |
| Timer Tool | `timer_now()` | Timer | timeout |
| Perf Tool | `perf_read()` | CSR/Perf Monitor | 自监控 |
| Host Tool | `host_send()` | UART/Ethernet | 上位机交互 |

这张表应最终进入答辩架构图。

---

# 38. Agent 分为三个能力等级

## Level 1：Embedded Offline Agent（必须完成）

```text
Camera
 ↓
Vision
 ↓
State
 ↓
Policy
 ↓
GPIO / Display / UART
```

特点：

- 不依赖网络；
- 可独立演示；
- 完整体现 Observe → Decision → Action。

## Level 2：LLM-assisted Agent（推荐）

```text
Laptop / Cloud LLM
        │
    Ethernet/UART
        │
 structured policy
        │
RISC-V Embedded Agent
```

例如自然语言：

```text
“看到人进入区域后，连续检测两次再报警。”
```

Host 转换成：

```json
{
  "target": "person",
  "threshold": 0.75,
  "confirm_frames": 2,
  "action": "alarm"
}
```

RISC-V 不需要本地解析复杂自然语言。

## Level 3：MCP / External Tool Agent（可选）

Host 可以进一步把设备能力暴露成：

```text
riscv.capture
riscv.detect
riscv.gpio_set
riscv.get_perf
```

但 MCP/JSON-RPC/HTTP 等复杂协议应放在 Host；裸机设备侧只保留简单 binary RPC。

---

# 39. Hardware-aware Agent

这是一个能突出“自研软核”的高级方向。

Agent 可以读取：

```text
mcycle
minstret
branch/mispredict
I-Cache miss
D-Cache miss
DMA busy
AI accelerator cycles
```

并通过：

```text
perf.cpu
perf.cache
perf.ai
```

提供给 Agent 或 Host。

后期可以尝试：

```text
小 workload
→ CPU + AI ISA

大 workload
→ DMA + AI Accelerator
```

即：

```text
           Runtime / Agent
             workload
             /     \
            /       \
      CPU AI ISA   AI Accelerator
```

第一阶段它只用于监控和展示；自适应调度属于后期增强。

---

# 40. AI 指令必须形成完整链条

自定义 AI 指令不应该只实现：

```systemverilog
case (custom_opcode)
```

而应该形成：

```text
Workload Profile
 ↓
Instruction Definition
 ↓
RTL Execution Unit
 ↓
Intrinsic
 ↓
Operator
 ↓
Model
 ↓
Agent Application
```

例如：

```text
INT8 Conv
 ↓
dot product hotspot
 ↓
DOT8 / MAC8
```

然后软件：

```c
rv_ai_dot8();
```

最终比较：

```text
Baseline RV64
RV64 + M
RV64 + AI ISA
RV64 + AI Accelerator
```

建议记录：

```text
cycles
speedup
LUT/DSP overhead
speedup/resource
```

这样 AI ISA 的价值是可量化的。

---

# 41. AI 指令由真实 workload 反推

不要先规定“做十条 AI 指令”。

正确流程：

```text
选模型
 ↓
Profile
 ↓
找热点 Operator
 ↓
分析数据类型
 ↓
定义最少指令
```

对于 INT8 CNN 可以优先研究：

```text
DOT8
MAC8
QCLIP / SAT
PACK / UNPACK
```

第一版只做 1~3 条有明确收益的指令，往往比堆很多 custom opcode 更可靠。

---

# 42. 推荐应用：可配置 Edge Vision Agent Camera

相比固定的“安全帽识别器”，建议把应用设计成：

> **可配置视觉智能 Agent Camera**

底层始终是：

```text
Camera
 ↓
Preprocess
 ↓
AI Accelerator
 ↓
Agent
 ↓
HDMI / GPIO / UART / Ethernet
```

但 Goal 可以改变。

## Demo A：区域入侵

```text
person
→ ROI
→ 连续 N 帧确认
→ alarm
```

## Demo B：目标计数

```text
detect
→ count
→ HDMI overlay
```

## Demo C：物体巡检

```text
指定 object
→ 缺失/错误类别
→ log + alarm
```

## Demo D：目标跟踪（后期）

```text
target center
→ policy/control
→ PWM servo
→ camera follows target
```

这使同一套硬件从“模型 Demo”变成“可编程边缘智能系统”。

---

# 43. Physical AI 不需要复杂机器人起步

推荐按难度逐步增加：

```text
Level 0：LED
Level 1：蜂鸣器
Level 2：GPIO Relay
Level 3：PWM Servo
Level 4：双轴云台
```

只要实现：

```text
Vision
→ Agent Policy
→ Servo / GPIO
```

已经形成 Physical AI 闭环。

不要让机械结构吞噬 CPU/SoC 主线时间。

---

# 44. 软件目录建议继续细化

```text
software/
├── agent/
│   ├── runtime/
│   │   ├── agent.c
│   │   ├── scheduler.c
│   │   └── event_bus.c
│   ├── state/
│   │   └── state_store.c
│   ├── policy/
│   │   ├── rule_policy.c
│   │   └── policy_config.c
│   ├── tools/
│   │   ├── tool_registry.c
│   │   ├── camera_tool.c
│   │   ├── vision_tool.c
│   │   ├── gpio_tool.c
│   │   ├── display_tool.c
│   │   ├── perf_tool.c
│   │   └── host_tool.c
│   └── protocol/
│       └── agent_rpc.c
│
host/
├── agent_console/
├── llm_bridge/
└── mcp_gateway/       # optional
```

第一阶段必须完成：

```text
runtime
state
policy
tools
```

`llm_bridge` 和 `mcp_gateway` 都属于增强项。

---

# 45. Agent 方向对硬件提出的新要求

## 必须有

```text
UART
GPIO
Timer
Interrupt
DDR
I/D Cache
```

## AI 数据路径强烈建议

```text
DMA
AI Accelerator
Performance Counters
```

## 视觉应用建议

```text
Camera / Host image input
Framebuffer
HDMI output
```

## LLM-assisted Agent 可选

```text
Ethernet
```

注意：Ethernet 不得成为 Level-1 Agent 能否工作的前提。

---

# 46. Performance Counter 建议

标准：

```text
mcycle
minstret
```

后期建议增加：

```text
branch_count
mispredict_count
icache_miss
dcache_miss
load_stall_cycles
dma_busy_cycles
ai_busy_cycles
```

用途：

- 答辩性能分析；
- Host dashboard；
- Hardware-aware Agent；
- AI ISA/Accelerator 对比。

它们可以通过 custom CSR 或 MMIO 暴露，不必伪装成标准 CSR。

---

# 47. 比赛 Demo 建议分三层

## Demo 1：CPU / SoC

```text
UART boot
CoreMark
CSR/perf
Cache statistics
```

回答：

> CPU 是不是自研？性能如何？

## Demo 2：AI 加速

同一 kernel：

```text
CPU baseline
→ AI ISA
→ AI Accelerator
```

显示：

```text
cycles
latency
speedup
resource
```

回答：

> AI 指令和 Accelerator 为什么存在？

## Demo 3：Agent

```text
Camera
 ↓
Detection
 ↓
State
 ↓
Policy
 ↓
Action
```

可选：

```text
Natural Language
→ Host LLM
→ Policy
→ RISC-V Agent
```

回答：

> 整套 CPU/SoC 最后解决了什么实际问题？

---

# 48. 建议增加的性能指标

## CPU

```text
CoreMark
CoreMark/MHz
CoreMark/LUT
Fmax
IPC
branch misprediction rate
cache miss rate
```

## AI ISA

```text
operator cycles
speedup over baseline
extra LUT/DSP
speedup/resource
```

## Accelerator

```text
inference latency
FPS
DMA transfer time
accelerator utilization
LUT/FF/BRAM/DSP
```

## Agent

```text
capture → inference latency
inference → action latency
end-to-end latency
false alarm rate
offline availability
```

其中最值得强调：

```text
Camera Frame
→ Physical/Visible Action
```

的端到端延迟。

---

# 49. 更新后的开发路线

```text
Phase A：CPU 可用
RV64I + Zicsr
riscv-tests
CoreMark

Phase B：CPU 完善
M
C
BTB
Trap/Interrupt
Cache

Phase C：SoC 可用
UART
GPIO
Timer
DDR
DMA

Phase D：AI ISA
Intrinsic
Operator benchmark

Phase E：AI Accelerator
INT8 runtime
DMA data path
Model inference

Phase F：Offline Edge Agent
Tool
State
Policy
Action

Phase G：Vision Application
Camera
HDMI
Physical Action

Phase H：Optional LLM
Ethernet
Host LLM bridge
Natural-language policy

Phase I：Optional MCP
Host MCP gateway
Expose RISC-V hardware tools
```

必须保证：

> Phase F 在没有 Phase H/I 的情况下已经是一件完整作品。

---

# 50. 当前可以冻结与暂缓的内容

## 现在可以冻结

```text
RV64 为比赛主配置
盘古 676 200K 为比赛目标平台

Agent 主循环：
Observe
→ State
→ Policy
→ Tool
→ Action

硬件能力统一 Tool 化

AI 计算优先 INT8

AI ISA 必须服务真实 Operator

Host LLM 只是增强，不是必需
```

## 暂时不冻结

```text
YOLOv5 / YOLOv8 / MobileNet / 自定义模型
AI Accelerator 阵列规模
AI custom opcode
是否 FreeRTOS
是否加入舵机
是否 MCP
Ethernet 高层协议
最终 Vision Agent 场景
```

这些应等：

```text
RV64 + Zicsr + riscv-tests + CoreMark
```

稳定后再冻结。

---

# 51. 更新后的一句话架构

> **以自研 RV64 CPU 为控制核心，以 Cache/DDR/DMA 构成数据底座，以 AI 指令承担细粒度 INT8 算子，以 FPGA AI Accelerator 承担高吞吐推理，再由本地 Agent Runtime 将 Camera、AI、GPIO、Display、Performance 等硬件能力抽象为 Tool，完成 Observe → State → Policy → Action 的边缘智能闭环；Host/Cloud LLM 仅作为可选的自然语言与高级任务规划层。**
