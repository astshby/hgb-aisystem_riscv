// Package: core_types_pkg
// Description: Strongly typed execution controls shared by core modules.
// 命名规范：_t:普通类型(logic,结构体)，_e:枚举，_pkg:package
// 整体模块的语义，前递与冒险在别处
package core_types_pkg;
    // 引入配置包
    import core_config_pkg::*;

    // 以下为类型的定义与重命名，用于简化变量，logic：普通线路，enum：类似枚举，本质多选器，struct：结构体，用于组合操作

    // 数据宽度，grp，csr命名
    typedef logic [XLEN-1:0] xlen_t;
    typedef logic [GPR_ADDR_W-1:0] gpr_addr_t;
    typedef logic [CSR_ADDR_W-1:0] csr_addr_t;

    //类型选择与执行命名（id）
    typedef enum logic [2:0] {
        FU_NONE, FU_ALU, FU_BRANCH, FU_LSU, FU_CSR, FU_MULDIV
    } fu_sel_e; //U指令有一条包含PC，所以没必要加一条FU_U，复用FU_ALU即可

    // alu，分支（默认不跳转），也许可以优化，其中分支控制的提出很关键
    typedef enum logic [3:0] {
        ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
        ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND
    } alu_op_e;
    typedef enum logic [3:0] {
        BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE,
        BR_LTU, BR_GEU, BR_JAL, BR_JALR
    } branch_op_e;

    // JAL 已在 D1 处理；EX 只处理条件分支和 JALR。
    function automatic logic is_ex_control_flow(input branch_op_e operation);
        return (operation != BR_NONE) && (operation != BR_JAL);
    endfunction

    // M 运算与 ALU 分类分离；W 形式复用操作枚举，由 op_width 决定有效位宽。
    typedef enum logic [2:0] {
        MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU,
        MD_DIV, MD_DIVU, MD_REM, MD_REMU
    } muldiv_op_e;

    // alu端口，64/32位宽表示，访存长度，写回，csr
    // 以上NONE的普遍涉及必须气泡/中断的
    typedef enum logic [1:0] { OP_A_RS1, OP_A_PC, OP_A_ZERO } op_a_sel_e; //lui使用zero
    typedef enum logic       { OP_B_RS2, OP_B_IMM } op_b_sel_e;
    typedef enum logic       { OP_WIDTH_XLEN, OP_WIDTH_WORD } op_width_e;//决定64/32位运算
    typedef enum logic [1:0] { MEM_BYTE, MEM_HALF, MEM_WORD, MEM_DWORD } mem_size_e;
    typedef enum logic [2:0] { WB_NONE, WB_ALU, WB_LOAD, WB_SEQ_PC, WB_CSR } wb_sel_e;//SEQ_PC：顺序PC写回（j）
    typedef enum logic [1:0] { CSR_RW, CSR_RS, CSR_RC } csr_cmd_e;
    typedef enum logic [1:0] { SYS_NONE, SYS_ECALL, SYS_EBREAK, SYS_MRET } sys_op_e;//涉及特权指令：ecall，ebreak，M级别的reset，none，一般指令是none
                                                                                    //ecall，ebreak，mret都涉及csr的写入/读取，一定注意！

    // 乘除法请求状态寄存器，用于提交乘除法运算（由于乘除法跨周期，便于管理寄存器与连线，alu与branch就没必要的了）
    typedef struct packed {
        muldiv_op_e operation;
        op_width_e  op_width;
        xlen_t      operand_a;
        xlen_t      operand_b;
    } muldiv_req_t;

    //上述选择后，提供给整体控制信息，用于传递打包好的整体信息（经过解码）(micro-op)
    typedef struct packed {
        // 上述必要指令解码,alu,branch，muldiv并行处理
        fu_sel_e       fu;
        alu_op_e       alu_op;
        muldiv_op_e    muldiv_op;
        branch_op_e    branch_op;
        op_a_sel_e     op_a_sel;
        op_b_sel_e     op_b_sel;
        op_width_e     op_width;
        mem_size_e     mem_size;
        wb_sel_e       wb_sel;
        csr_cmd_e      csr_cmd;
        sys_op_e       sys_op;
        // 控制位
        logic          rs1_used; //rs是否使用，例如在l-u冒险中用于判断是否使用决定是否停顿
        logic          rs2_used;
        logic          gpr_write; //gpr，mem是否写入/读取，同样用于冒险判断等
        logic          mem_read;
        logic          mem_write;
        logic          load_unsigned;//加载数据扩展
        logic          csr_valid; //csr是否使用，是否写入rd，是否用立即数/rs1,种类少是因为这个真的就只有这点。
        logic          csr_imm; //类似load_unsigned，csr是否使用立即数/rs1
        logic          csr_write;
        logic          illegal;//是否非法指令
    } uop_t; //micro-op


endpackage
