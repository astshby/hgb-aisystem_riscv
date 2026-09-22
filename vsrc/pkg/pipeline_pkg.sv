// Package: pipeline_pkg
// Description: Packed packets carried across the six pipeline boundaries.
// 保存流水线相关信息，包括异常处理、分支预测相关信息和流水级寄存器。
package pipeline_pkg;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    // 动态异常信息与uOp静态译码控制分离,也便于流水线扩展（异常与中断可能随时出现）
    typedef struct packed {
        logic       valid;  // 异常有效标记
        exc_cause_e cause; // 异常原因在rv_priv定义
        xlen_t      tval;
    } exception_t;

    // 向 EX 提供的前递，包括grp与csr
    typedef struct packed {
        logic      valid;
        gpr_addr_t addr;
        xlen_t     data;
    } gpr_forward_t;

    typedef struct packed {
        logic      valid;
        csr_addr_t addr;
        xlen_t     data;
    } csr_forward_t;

    // 流水线必备，与btb与预测有关
    // if阶段必须传递的预测信息
    typedef struct packed {
        logic                  hit; //btb命中(valid && tag==pc)
        logic                  taken; //pht是否采用(pht[pc^ghr]的高位)
        xlen_t                 target; //btb给出的分支目标(条件分支需要：hit && taken 判定，J指令仅仅要hit)
        logic [BTB_IDX_W-1:0]  btb_idx; //btb索引
        logic [PHT_IDX_W-1:0]  pht_idx; //pht索引
    } pred_info_t;

    // if阶段预测信息更新必要的信息
    typedef struct packed {
        logic       valid; // 更新信息有效标记
        branch_op_e kind; // 分支类型
        xlen_t      pc; // 分支指令的PC
        logic       taken; // 分支是否被采用
        xlen_t      target; // 分支目标地址
        pred_info_t pred; // if阶段的预测信息
    } pred_update_t;

    // 流水线重定向信息原因, 用于指示流水线需要跳转到新的PC
    typedef enum logic [2:0] {
        REDIR_NONE, REDIR_D1_JAL, REDIR_EX_BRANCH, REDIR_TRAP, REDIR_MRET
    } redirect_reason_e;

    // 重定向信息包
    typedef struct packed {
        logic             valid;
        xlen_t            pc;
        redirect_reason_e reason;
    } redirect_t;

    // 每个流水寄存器每拍只有三种动作：接收、保持、清除 valid。
    typedef enum logic [1:0] {
        PIPE_ADVANCE, PIPE_HOLD, PIPE_CLEAR
    } pipe_action_e;

    // 每个流水级寄存器的动作，给pipeline_control使用
    typedef struct packed {
        pipe_action_e if_d1;
        pipe_action_e d1_d2;
        pipe_action_e d2_ex;
        pipe_action_e ex_mem;
        pipe_action_e mem_wb;
    } pipeline_actions_t;

    // 流水级寄存器
    // special：valid 标记真实指令；PIPE_CLEAR 插入无效包，PIPE_HOLD 保持指令与控制。
    // csr后期出现：wb阶段才写回,与gpr写回时机一致
    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        logic [31:0] inst;
        pred_info_t  pred;
    } if_d1_t;

    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        logic [31:0] inst;
        gpr_addr_t   rs1;
        gpr_addr_t   rs2;
        gpr_addr_t   rd;
        xlen_t       imm;
        csr_addr_t   csr_addr;
        uop_t        uop;
        pred_info_t  pred;
        exception_t  exc;
    } d1_d2_t;

    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        logic [31:0] inst;
        gpr_addr_t   rs1;
        gpr_addr_t   rs2;
        gpr_addr_t   rd;
        xlen_t       rs1_data;
        xlen_t       rs2_data;
        xlen_t       imm;
        csr_addr_t   csr_addr;
        uop_t        uop;
        pred_info_t  pred;
        exception_t  exc;
    } d2_ex_t;

    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        logic [31:0] inst;
        gpr_addr_t   rd;
        xlen_t       result;
        xlen_t       store_data;   //没有写入uop，必须单独给出
        csr_addr_t   csr_addr;
        xlen_t       csr_old;
        xlen_t       csr_new;
        logic        csr_we;
        uop_t        uop;
        pred_info_t  pred;
        exception_t  exc;
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        logic [31:0] inst;
        gpr_addr_t   rd;
        xlen_t       result; // ALU 结果或访存地址；load 在 WB 使用地址低位选择返回数据
        csr_addr_t   csr_addr;
        xlen_t       csr_old;
        xlen_t       csr_new;
        logic        csr_we; // 没有pred信息，pred不在wb阶段解决
        uop_t        uop;
        exception_t  exc;
    } mem_wb_t;
endpackage
