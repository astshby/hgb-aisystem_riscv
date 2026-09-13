// Package: riscv_priv_pkg
// Description: RISC-V privileged instruction, CSR, trap, and interrupt encodings.
// 特权架构定义，包含特权指令、机器级 CSR、异常与中断编码
package riscv_priv_pkg;
    import core_config_pkg::*;

    localparam logic [31:0] INST_MRET = 32'h3020_0073; // 从机器模式 trap 处理程序返回

    // 中断异常相关csr
    // 地址类似：0x3xx → M-mode trap/setup ，0xBxx → M-mode counters，0xFxx → M-mode information / read-only 区域
    // trap必须：mstatus:原状态 -> mepc:trap指令地址,mcause:trap原因,mtval:trap相关值,mtvec:trap后访问地址,mscratch:trap处理程序临时寄存器
    localparam logic [11:0] CSR_MSTATUS  = 12'h300; // 机器模式状态与全局中断控制
    localparam logic [11:0] CSR_MISA     = 12'h301; // 处理器 XLEN 和已实现的 ISA 扩展
    localparam logic [11:0] CSR_MIE      = 12'h304; // 机器模式各类中断使能
    localparam logic [11:0] CSR_MTVEC    = 12'h305; // trap 入口基地址和向量模式
    localparam logic [11:0] CSR_MSCRATCH = 12'h340; // trap 处理程序使用的临时寄存器
    localparam logic [11:0] CSR_MEPC     = 12'h341; // 保存 trap 发生时的 PC
    localparam logic [11:0] CSR_MCAUSE   = 12'h342; // 保存 trap 类型和原因编号
    localparam logic [11:0] CSR_MTVAL    = 12'h343; // 保存 trap 相关的指令或地址信息
    localparam logic [11:0] CSR_MIP      = 12'h344; // 机器模式中断等待状态

    // 性能与计数相关的csr
    localparam logic [11:0] CSR_MCYCLE   = 12'hB00; // 机器模式周期计数器
    localparam logic [11:0] CSR_MINSTRET = 12'hB02; // 已完整运行指令计数器
    localparam logic [11:0] CSR_MCYCLEH  = 12'hB80; // RV32 周期计数器高 32 位
    localparam logic [11:0] CSR_MINSTRETH = 12'hB82; // RV32 退休计数器高 32 位
    localparam logic [11:0] CSR_MVENDORID = 12'hF11; // 实现厂商编号；当前实现固定返回 0
    localparam logic [11:0] CSR_MARCHID   = 12'hF12; // 微架构编号；当前实现固定返回 0
    localparam logic [11:0] CSR_MIMPID    = 12'hF13; // 实现版本编号；当前实现固定返回 0
    localparam logic [11:0] CSR_MHARTID  = 12'hF14; // 当前硬件线程标识

    // mstatus 寄存器位定义,仅仅这些地方写入mstatus，其他位写入0
    localparam int unsigned MSTATUS_MIE_BIT  = 3;  // 机器模式全局中断使能
    localparam int unsigned MSTATUS_MPIE_BIT = 7;  // trap 进入前的 MIE 备份
    localparam int unsigned MSTATUS_MPP_LSB  = 11; // trap 进入前的特权级低位
    localparam int unsigned MSTATUS_MPP_MSB  = 12; // trap 进入前的特权级高位
    // mie/mip 寄存器位定义
    localparam int unsigned MIE_MSIE_BIT = 3;  // 机器软件中断使能
    localparam int unsigned MIE_MTIE_BIT = 7;  // 机器定时器中断使能
    localparam int unsigned MIE_MEIE_BIT = 11; // 机器外部中断使能
    localparam int unsigned MIP_MSIP_BIT = 3;  // 机器软件中断等待
    localparam int unsigned MIP_MTIP_BIT = 7;  // 机器定时器中断等待
    localparam int unsigned MIP_MEIP_BIT = 11; // 机器外部中断等待

    // 以下位trap相关返回的原因(mcause)
    // mcause 寄存器位定义
    localparam int unsigned MCAUSE_INTERRUPT_BIT = XLEN - 1; // 1 表示中断，0 表示异常
    // 异常返回编码
    typedef enum logic [4:0] {
        EXC_INST_ADDR_MISALIGNED  = 5'd0, // 指令地址未对齐
        EXC_INST_ACCESS_FAULT     = 5'd1, // 指令访问错误
        EXC_ILLEGAL_INST          = 5'd2, // 非法指令
        EXC_BREAKPOINT            = 5'd3, // 断点
        EXC_LOAD_ADDR_MISALIGNED  = 5'd4, // 加载地址未对齐
        EXC_LOAD_ACCESS_FAULT     = 5'd5, // 加载访问错误
        EXC_STORE_ADDR_MISALIGNED = 5'd6, // 存储地址未对齐
        EXC_STORE_ACCESS_FAULT    = 5'd7, // 存储访问错误
        EXC_ECALL_U               = 5'd8, // 用户模式系统调用
        EXC_ECALL_S               = 5'd9, // 系统（内核）模式系统调用
        EXC_ECALL_M               = 5'd11, // 机器模式系统调用
        EXC_INST_PAGE_FAULT       = 5'd12, // 指令页错误
        EXC_LOAD_PAGE_FAULT       = 5'd13, // 加载页错误
        EXC_STORE_PAGE_FAULT      = 5'd15  // 存储页错误
    } exc_cause_e;

    // 中断返回编码
    typedef enum logic [3:0] {
        IRQ_M_SOFTWARE = 4'd3, //M级别软件中断
        IRQ_M_TIMER    = 4'd7, //M级别定时器中断
        IRQ_M_EXTERNAL = 4'd11 //M级别外部中断
    } irq_cause_e;
endpackage
