// Package: core_config_pkg
// Description: Build-time widths and portable core constants.

// 宏定义，用于决定核心的位宽（XLEN），支持32/64
`ifndef CORE_XLEN
`define CORE_XLEN 32
`endif

// 本项目使用了多种乘法/除法器，为了与不同厂商ip核/dsp兼容，由宏定义选择,以此达到通用性与最好的效果
`ifndef CORE_MUL_IMPL
`define CORE_MUL_IMPL 0
`endif
`ifndef CORE_DIV_IMPL
`define CORE_DIV_IMPL 0
`endif

// 容量由同一构建配置派生，避免端口类型与容量不一致；P0 主配置使用 16 槽。
`ifndef CORE_RETIRE_ENTRIES
`define CORE_RETIRE_ENTRIES 4
`endif

`ifndef CORE_PREDICTOR_MODE
`define CORE_PREDICTOR_MODE 0
`endif
`ifndef CORE_RAS_ENABLE
`define CORE_RAS_ENABLE 0
`endif
`ifndef CORE_ISSUE_WIDTH
`define CORE_ISSUE_WIDTH 1
`endif
`ifndef CORE_ISSUE_QUEUE_ENTRIES
`define CORE_ISSUE_QUEUE_ENTRIES 8
`endif
`ifndef CORE_MEMORY_QUEUE_ENTRIES
`define CORE_MEMORY_QUEUE_ENTRIES 4
`endif
`ifndef CORE_SPLIT_ISSUE_QUEUE
`define CORE_SPLIT_ISSUE_QUEUE 0
`endif
`ifndef CORE_LIMITED_INTEGER_OOO
`define CORE_LIMITED_INTEGER_OOO 0
`endif
`ifndef CORE_SCHEDULER_FORWARD_MODE
`define CORE_SCHEDULER_FORWARD_MODE 0
`endif
`ifndef CORE_LOAD_QUEUE_ENTRIES
`define CORE_LOAD_QUEUE_ENTRIES 4
`endif
`ifndef CORE_STORE_QUEUE_ENTRIES
`define CORE_STORE_QUEUE_ENTRIES 4
`endif
`ifndef CORE_BRANCH_CHECKPOINTS
`define CORE_BRANCH_CHECKPOINTS 4
`endif

// package,类似cpp的namespace与.h文件，定义一组相关的常量、类型和函数
// .h与命名空间偏向于声明，编译为‘复制’，但是package用法类似，却单独编译链接，不会导致重复，并且支持可综合代码
package core_config_pkg;
    // localparam相比宏定义更方便与安全，int unsigned用于确保无符号整数类型
    // 1-4:位宽，GPR数量与地址宽度，CSR地址宽度
    // 5:数据总线字节数，访存相关
    // 6-7:BTB（分支目标缓存）有16项，需要4-bit索引，8-9:PHT（分支历史表）同样,10:GHR（全局分支历史寄存器）宽度与PHT相同
    // 11:复位向量，初始化为0，'0表示按照位数全部填0
    // 12-14：乘法器实现（DSP, Booth_Wallace, Shift）,15-16：除法器实现（Shift, SRT4）
    // 17-18：乘法器/除法器选择宏定义
    localparam int unsigned XLEN = `CORE_XLEN;
    // 发射宽度不随 XLEN 改变；双发射以两个固定32位指令为取指传输单位。
    localparam int unsigned ISSUE_WIDTH = `CORE_ISSUE_WIDTH;
    localparam int unsigned FETCH_DATA_W = 32 * ISSUE_WIDTH;
    localparam int unsigned FETCH_QUEUE_DEPTH = 8;
    localparam int unsigned ISSUE_QUEUE_ENTRIES = `CORE_ISSUE_QUEUE_ENTRIES;
    localparam int unsigned MEMORY_QUEUE_ENTRIES = `CORE_MEMORY_QUEUE_ENTRIES;
    localparam bit SPLIT_ISSUE_QUEUE = `CORE_SPLIT_ISSUE_QUEUE;
    localparam bit LIMITED_INTEGER_OOO = `CORE_LIMITED_INTEGER_OOO;
    typedef enum int unsigned {
        IQ_FORWARD_ALL, IQ_FORWARD_BRANCH_COMPLETION, IQ_FORWARD_LSU_CAPTURE, IQ_FORWARD_STORE_CAPTURE
    } iq_forward_mode_e;
    localparam iq_forward_mode_e SCHEDULER_FORWARD_MODE = iq_forward_mode_e'(`CORE_SCHEDULER_FORWARD_MODE);
    localparam int unsigned SCHEDULER_ENTRIES = ISSUE_QUEUE_ENTRIES +
        (SPLIT_ISSUE_QUEUE ? MEMORY_QUEUE_ENTRIES : 0);
    localparam int unsigned LOAD_QUEUE_ENTRIES = `CORE_LOAD_QUEUE_ENTRIES;
    localparam int unsigned STORE_QUEUE_ENTRIES = `CORE_STORE_QUEUE_ENTRIES;
    localparam int unsigned BRANCH_CHECKPOINTS = `CORE_BRANCH_CHECKPOINTS;
    localparam int unsigned GPR_NUM = 32;
    localparam int unsigned GPR_ADDR_W = $clog2(GPR_NUM); //5,64位也只有32个寄存器
    localparam int unsigned CSR_ADDR_W = 32;
    localparam int unsigned DBUS_BYTES = XLEN / 8;
    localparam int unsigned BTB_ENTRIES = 64;
    localparam int unsigned BTB_IDX_W = $clog2(BTB_ENTRIES);  // clog2：计算2为底的对数并向上取整
    localparam int unsigned PHT_ENTRIES = 64;
    localparam int unsigned PHT_IDX_W = $clog2(PHT_ENTRIES);
    localparam int unsigned GHR_W = PHT_IDX_W;
    localparam int unsigned PREDICTOR_MODE = `CORE_PREDICTOR_MODE; // 0:GShare，1:Tournament
    localparam bit RAS_ENABLE = `CORE_RAS_ENABLE;
    localparam int unsigned LOCAL_ENTRIES = 64;
    localparam int unsigned LOCAL_HISTORY_W = 8;
    localparam int unsigned CHOOSER_ENTRIES = 32;
    localparam int unsigned CHOOSER_IDX_W = $clog2(CHOOSER_ENTRIES);
    localparam int unsigned RAS_DEPTH = 4;
    localparam logic [XLEN-1:0] RESET_VECTOR = '0;
    localparam int unsigned MUL_DSP = 0;
    localparam int unsigned MUL_BOOTH_WALLACE = 1;
    localparam int unsigned MUL_SHIFT = 2;
    localparam int unsigned DIV_SHIFT = 0;
    localparam int unsigned DIV_SRT4 = 1;
    localparam int unsigned MUL_IMPL = `CORE_MUL_IMPL;
    localparam int unsigned DIV_IMPL = `CORE_DIV_IMPL;
    localparam int unsigned RETIRE_ENTRIES = `CORE_RETIRE_ENTRIES;
    localparam int unsigned RETIRE_IDX_W = $clog2(RETIRE_ENTRIES);
    localparam int unsigned RETIRE_COUNT_W = $clog2(RETIRE_ENTRIES + 1);
    // 代次辅助发现迟到响应；取消后的事务排空仍是复用 ID 的必要条件。
    localparam int unsigned RETIRE_GEN_W = 2;
endpackage
