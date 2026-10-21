// Package: pipeline_pkg
// Description: Packed packets carried across the six pipeline boundaries.
// 保存流水线相关信息，包括异常处理、分支预测相关信息和流水级寄存器。
package pipeline_pkg;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;
    import predictor_types_pkg::*;

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

    // 槽号用于索引，代次用于区分物理槽的不同使用者；二者不能直接比较指令年龄。
    typedef struct packed {
        logic [RETIRE_IDX_W-1:0] slot;
        logic [RETIRE_GEN_W-1:0] generation;
    } retire_id_t;

    // EX 直接交付 LSU 的唯一事务描述符；替代未来 EX/MEM 的访存边界，不串接第二层。
    // PC/rd/指令与顺序后继归退休队列；Store 数据和字节掩码在交付前完成格式化。
    typedef struct packed {
        retire_id_t id;
        xlen_t      address;
        logic       write;
        mem_size_e  size;
        logic       unsigned_load;
        xlen_t      wdata;
        logic [DBUS_BYTES-1:0] wstrb;
    } lsu_descriptor_t;

    typedef enum logic [2:0] {
        RET_EXEC, RET_BRANCH, RET_LOAD, RET_STORE, RET_CSR, RET_SERIAL, RET_MDU
    } retire_kind_e;

    // pending 表示绑定了尚未捕获的老生产者；ID 的槽号与代次必须一起匹配。
    typedef struct packed {
        logic       pending;
        retire_id_t id;
    } gpr_dependency_t;

    // 执行前递按指令 ID 匹配，区别于架构退休写口按 GPR 地址匹配。
    typedef struct packed {
        logic       valid;
        retire_id_t id;
        xlen_t      data;
    } retire_gpr_forward_t;

    // 退休槽的只读连线视图，不是第二份 scoreboard；所有状态仍保存在 retire_queue。
    typedef struct packed {
        logic         valid;
        logic         ready;
        retire_id_t   id;
        logic         gpr_write;
        gpr_addr_t    rd;
        retire_kind_e kind;
        xlen_t        data;
    } retire_gpr_entry_t;

    // D2 只绑定来源、不等待数据；EX 依据已绑定 ID 查询已寄存结果与老 MDU 年龄。
    // dispatch_valid 是原始 D2 有效，不能再用本查询输出 waw_block 自门控。
    typedef struct packed {
        logic            dispatch_valid;
        logic            rs1_used, rs2_used;
        gpr_addr_t       rs1, rs2, rd;
        logic            gpr_write;
        logic            consumer_valid;
        retire_id_t      consumer_id;
        gpr_dependency_t rs1_dependency, rs2_dependency;
    } retire_query_t;

    typedef struct packed {
        gpr_dependency_t     rs1_dependency, rs2_dependency;
        // D2第二槽只接纳已就绪旧来源；这是队列只读结果，不另存生产者状态。
        retire_gpr_forward_t dispatch_rs1, dispatch_rs2;
        logic                waw_block;
        retire_gpr_forward_t rs1_forward, rs2_forward;
        logic                consumer_live; // 无效消费者不推断年龄；接入者不能把它当作无老指令。
        logic                any_unretired_mdu, older_mdu_pending;
    } retire_query_result_t;

    // 索引和两个候选必须来自同次查询；退休时不能用新历史重算，也不复制预测目标。
    typedef struct packed {
        logic [PHT_IDX_W-1:0] pht_idx;
        logic [LOCAL_HISTORY_W-1:0] local_idx;
        logic [CHOOSER_IDX_W-1:0] chooser_idx;
        logic global_taken, local_taken, choose_local;
    } pred_train_context_t;

    // 实际方向与分支目标独立保存；next_pc 在未跳转时只是顺序地址，不能还原二者。
    typedef struct packed {
        logic  taken;
        xlen_t target;
    } branch_result_t;

    // 接纳时保存退休所需的静态信息及紧凑训练上下文，不复制源操作数或完整 uOp。
    typedef struct packed {
        xlen_t        pc;
        xlen_t        seq_pc;
        logic [31:0]  inst;
        gpr_addr_t    rd;
        logic         gpr_write;
        csr_addr_t    csr_addr;
        sys_op_e      sys_op;
        retire_kind_e kind;
        branch_op_e   branch_kind;
        pred_train_context_t pred_train;
        ras_op_e      ras_op; // 已译码且无D1异常；返回地址复用seq_pc
    } retire_alloc_t;

    // 仅连出唯一退休队列的存活调用事件；无独立valid/年龄状态。
    typedef struct packed {
        logic valid;
        retire_id_t id;
        ras_event_t event_info;
        logic exception;
    } retire_ras_entry_t;

    // gpr_data 已完成 Load 格式化、CSR 旧值或跳转链接值选择，不在退休时再次计算。
    // next_pc 仅由分支覆盖；其他操作的实际后继由接纳包的 seq_pc 给出。
    typedef struct packed {
        xlen_t      next_pc;
        xlen_t      gpr_data;
        xlen_t      csr_data;
        logic       csr_write;
        exception_t exc;
        branch_result_t branch;
    } retire_result_t;

    typedef struct packed {
        retire_id_t     id;
        retire_result_t result;
    } retire_completion_t;

    // 两条退休记录按年龄排列；旧标量端口仍别名第一条，差分与统计应读取全部有效项。
    typedef struct packed {
        logic valid;
        retire_id_t id;
        xlen_t pc, next_pc;
        logic [31:0] inst;
        gpr_addr_t rd;
        logic rd_we;
        xlen_t rd_data;
        logic exception;
    } retire_trace_t;

    // 流水线必备，与btb与预测有关
    // if阶段必须传递的预测信息
    typedef struct packed {
        logic                  hit; //btb命中(valid && tag==pc)
        logic                  taken; //pht是否采用(pht[pc^ghr]的高位)
        xlen_t                 target; //btb给出的分支目标(条件分支需要：hit && taken 判定，J指令仅仅要hit)
        logic [BTB_IDX_W-1:0]  btb_idx; //btb索引
        pred_train_context_t train; // 被取指握手保存的方向预测快照
        ras_op_e              ras_op; // 仅用于被接受取指的推测栈事件
    } pred_info_t;

    // 唯一退休端训练包：静态上下文来自分配时快照，实际方向与目标来自完成结果。
    typedef struct packed {
        logic       valid; // 更新信息有效标记
        branch_op_e kind; // 分支类型
        xlen_t      pc; // 分支指令的PC
        logic       taken; // 分支是否被采用
        xlen_t      target; // 分支目标地址
        pred_train_context_t train; // IF 请求被接受时的查询索引，不在退休时重新查询。
        ras_op_e    ras_op; // 实际指令hint，只在正常退休时写入BTB
    } pred_update_t;

    // 流水线重定向信息原因, 用于指示流水线需要跳转到新的PC
    typedef enum logic [2:0] {
        REDIR_NONE, REDIR_D1_JAL, REDIR_EX_BRANCH, REDIR_TRAP, REDIR_MRET, REDIR_FENCE
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
        exception_t  exc; // 取指错误随请求 PC 传播；被重定向杀死的响应不进入流水。
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
        gpr_dependency_t rs1_dependency, rs2_dependency;
        retire_id_t  retire_id; // D2 实际发射时分配，后续级透明携带。
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
        xlen_t       next_pc; // 已执行的实际后继 PC，供排空流水后的中断恢复。
        branch_result_t branch; // 实际分支结果随完成保存，直到该指令正常退休才训练。
        logic [31:0] inst;
        gpr_addr_t   rd;
        xlen_t       result;
        xlen_t       store_data;   //没有写入uop，必须单独给出
        retire_id_t  retire_id;
        csr_addr_t   csr_addr;
        xlen_t       csr_old;
        xlen_t       csr_new;
        logic        csr_we;
        uop_t        uop;
        exception_t  exc;
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        xlen_t       pc;
        xlen_t       seq_pc;
        xlen_t       next_pc; // 已执行的实际后继 PC，供排空流水后的中断恢复。
        branch_result_t branch;
        logic [31:0] inst;
        gpr_addr_t   rd;
        xlen_t       result; // ALU 结果或访存地址；load 在 WB 使用地址低位选择返回数据
        retire_id_t  retire_id;
        csr_addr_t   csr_addr;
        xlen_t       csr_old;
        xlen_t       csr_new;
        logic        csr_we; // 预测查询上下文已归退休队列；WB 只交付实际分支结果。
        uop_t        uop;
        exception_t  exc;
    } mem_wb_t;
endpackage
