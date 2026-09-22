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
    localparam int unsigned GPR_NUM = 32;
    localparam int unsigned GPR_ADDR_W = $clog2(GPR_NUM); //5,64位也只有32个寄存器
    localparam int unsigned CSR_ADDR_W = 32;
    localparam int unsigned DBUS_BYTES = XLEN / 8;
    localparam int unsigned BTB_ENTRIES = 64;
    localparam int unsigned BTB_IDX_W = $clog2(BTB_ENTRIES);  // clog2：计算2为底的对数并向上取整
    localparam int unsigned PHT_ENTRIES = 64;
    localparam int unsigned PHT_IDX_W = $clog2(PHT_ENTRIES);
    localparam int unsigned GHR_W = PHT_IDX_W;
    localparam logic [XLEN-1:0] RESET_VECTOR = '0;
    localparam int unsigned MUL_DSP = 0;
    localparam int unsigned MUL_BOOTH_WALLACE = 1;
    localparam int unsigned MUL_SHIFT = 2;
    localparam int unsigned DIV_SHIFT = 0;
    localparam int unsigned DIV_SRT4 = 1;
    localparam int unsigned MUL_IMPL = `CORE_MUL_IMPL;
    localparam int unsigned DIV_IMPL = `CORE_DIV_IMPL;
endpackage
