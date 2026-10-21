// Module: ex_stage
// Description: Applies forwarding and executes ALU, CSR, branch, and multi-cycle M operations.
module ex_stage (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         csr_is_head,
    input  logic                         mdu_operands_ready, // 完整 ID 解析的 GPR 就绪资格
    input  logic                         advance, // 当前 EX 指令已离开：送 MEM 或转交独立 MDU
    input  logic                         cancel, // 同步 WB 事件取消年轻执行状态
    input  logic                         mdu_req_ready,
    output logic                         mdu_req_valid,
    output core_types_pkg::muldiv_req_t  mdu_request,
    input  pipeline_pkg::d2_ex_t         in_packet,
    input  core_types_pkg::xlen_t        rs1_value, rs2_value,
    input  core_types_pkg::xlen_t        csr_committed_data, // csr在ex阶段，不写入流水级寄存器合理
    input  pipeline_pkg::csr_forward_t   mem_csr_forward,
    input  pipeline_pkg::csr_forward_t   wb_csr_forward,
    output pipeline_pkg::ex_mem_t        out_packet,
    output pipeline_pkg::redirect_t      redirect,
    output logic                         serialize_req,
    output logic                         execution_stall
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    xlen_t forwarded_rs1;
    xlen_t forwarded_rs2;
    xlen_t operand_a;
    xlen_t operand_b;
    xlen_t alu_result;
    xlen_t lsu_effective_address;
    logic branch_taken;
    xlen_t branch_target;
    logic computed_branch_taken;
    xlen_t computed_branch_target;
    logic branch_wait;
    logic control_op;
    logic branch_valid;
    logic mispredict;
    xlen_t csr_operand;
    xlen_t csr_old_data;
    xlen_t csr_proposed_data;
    xlen_t csr_new_data;
    exception_t execute_exc;
    logic mdu_selected;
    logic mdu_execution_stall;
    logic csr_wait;

    // D2/EX 所有者已按完整生产者 ID 解析/保存两源，不再重复按寄存器地址猜测旁路。
    assign forwarded_rs1 = rs1_value;
    assign forwarded_rs2 = rs2_value;

    // CSR 旁路在执行阶段选择最新值，与 GPR 操作数旁路类似。
    csr_bypass u_csr_bypass (
        .read_addr(in_packet.csr_addr),
        .committed_data(csr_committed_data),
        .mem_forward(mem_csr_forward),
        .wb_forward(wb_csr_forward),
        .bypass_data(csr_old_data)
    );

    // 操作数选择。
    always_comb begin
        unique case (in_packet.uop.op_a_sel)
            OP_A_RS1:  operand_a = forwarded_rs1;
            OP_A_PC:   operand_a = in_packet.pc;
            default:   operand_a = '0;
        endcase
        operand_b = (in_packet.uop.op_b_sel == OP_B_IMM)
                  ? in_packet.imm : forwarded_rs2;
        csr_operand = in_packet.uop.csr_imm
                    ? xlen_t'(in_packet.rs1) : forwarded_rs1;
    end

    // ALU、分支与 CSR 执行单元。
    alu u_alu (
        .operand_a,
        .operand_b,
        .operation(in_packet.uop.alu_op),
        .op_width(in_packet.uop.op_width),
        .result(alu_result)
    );

    branch_unit u_branch_unit (
        .branch_op(in_packet.uop.branch_op),
        .pc(in_packet.pc),
        .seq_pc(in_packet.seq_pc),
        .operand_a(forwarded_rs1),
        .operand_b(forwarded_rs2),
        .imm(in_packet.imm),
        .taken(computed_branch_taken),
        .target(computed_branch_target)
    );

    // 条件分支/JALR 先保存比较与目标，再处理重定向；JAL 仍在 D1 解析，不额外等待。
    // 快照只使用真实就绪的 GPR；允许越过独立旧MDU纠错，架构效果仍等唯一队列按序退休。
    assign control_op = (in_packet.uop.branch_op != BR_NONE) &&
                        (in_packet.uop.branch_op != BR_JAL);
    branch_result_register u_branch_result_register (
        .clk, .rst, .cancel, .advance,
        .selected(in_packet.valid && !in_packet.exc.valid && control_op),
        .operands_ready(mdu_operands_ready),
        .computed_taken(computed_branch_taken),
        .computed_target(computed_branch_target),
        .taken(branch_taken), .target(branch_target),
        .wait_for_result(branch_wait)
    );

    // csr的计算放在这个阶段,并行与alu处理
    csr_exec u_csr_exec (
        .command(in_packet.uop.csr_cmd),
        .old_value(csr_old_data),
        .operand(csr_operand),
        .new_value(csr_proposed_data)
    );
    // 先执行，后合法化
    csr_warl u_csr_warl (
        .address(in_packet.csr_addr),
        .proposed_value(csr_proposed_data),
        .legal_value(csr_new_data)
    );

    // M 扩展：EX 子模块组织前递操作数和请求；跨级运算由 Core 中的 MDU 管理。
    ex_mdu u_ex_mdu (
        .clk, .rst, .cancel, .mdu_operands_ready, .advance,
        .packet_valid(in_packet.valid), .exception_valid(execute_exc.valid),
        .uop(in_packet.uop), .forwarded_rs1, .forwarded_rs2,
        .selected(mdu_selected), .execution_stall(mdu_execution_stall),
        .req_ready(mdu_req_ready), .req_valid(mdu_req_valid), .request(mdu_request)
    );

    // 访存地址由前递后的 rs1 与立即数直接计算，避免异常判断依赖通用 ALU 的比较/选择链。
    assign lsu_effective_address = forwarded_rs1 + in_packet.imm;

    // 同步异常处理：控制流仍检查实际分支目标，访存检查独立的 LSU 地址。
    ex_exception_check u_ex_exception_check (
        .in_packet,
        .operands_ready(mdu_operands_ready), .branch_ready(!branch_wait),
        .effective_address(lsu_effective_address),
        .branch_taken,
        .branch_target,
        .exception(execute_exc)
    );

    // CSR 在自身成为队头后执行：旧写者可能已离开 MEM/WB、但仍未更新架构 CSR。
    // 包括 MINSTRET 的隐式增量，不以短流水旁路代替退休顺序。旧异常不等待无意义源。
    always_comb begin
        csr_wait = in_packet.uop.csr_valid && !csr_is_head;
        execution_stall = in_packet.valid && !in_packet.exc.valid &&
            (!mdu_operands_ready || csr_wait || branch_wait || mdu_execution_stall);
    end

    // 只为 EX 本级新发现的异常请求序列化，前级异常已经在 D1 处理。
    always_comb begin
        serialize_req = in_packet.valid && !in_packet.exc.valid && !execution_stall &&
                        execute_exc.valid;
    end

    // 分支控制只处理实际结果与预测错误；BTB/GShare 训练由正常退休端统一发出。
    // control_op 包含条件分支与 JALR；JAL 已在 D1 处理。
    always_comb begin
        branch_valid = in_packet.valid && !execute_exc.valid && control_op && !execution_stall;
        mispredict = (in_packet.pred.taken != branch_taken) ||
                     (branch_taken && (in_packet.pred.target != branch_target));

        redirect = '0;
        if (branch_valid && mispredict) begin
            redirect.valid = 1'b1;
            redirect.pc = branch_taken ? branch_target : in_packet.seq_pc;
            redirect.reason = REDIR_EX_BRANCH;
        end
    end

    // 输出打包：Store 使用前递后的 rs2，CSR 同时携带旧值和 WARL 合法新值。
    always_comb begin
        out_packet = '0;
        // 正常 M 指令只在独立完成口交付；异常 M 包仍走普通异常完成路径。
        out_packet.valid = in_packet.valid && !execution_stall && !mdu_selected;
        out_packet.retire_id = in_packet.retire_id;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
        // 保存槽在非分支期间可以保留旧 taken/target；只有本条控制流指令才能使用它。
        out_packet.next_pc = in_packet.uop.branch_op == BR_JAL ? in_packet.pc + in_packet.imm :
                             ((control_op && branch_taken) ? branch_target : in_packet.seq_pc);
        // JAL 复用已有目标；条件分支即使未跳转也必须保留真实目标，不能写成 next_pc。
        if (out_packet.valid && !execute_exc.valid) begin
            if (in_packet.uop.branch_op == BR_JAL)
                out_packet.branch = '{taken:1'b1, target:out_packet.next_pc};
            else if (branch_valid)
                out_packet.branch = '{taken:branch_taken, target:branch_target};
        end
        out_packet.inst = in_packet.inst;
        out_packet.rd = in_packet.rd;
        out_packet.result = alu_result;
        out_packet.store_data = forwarded_rs2; // 地址由 rs1+imm 计算，写数据来自 rs2。
        out_packet.csr_addr = in_packet.csr_addr;
        out_packet.csr_old = csr_old_data;
        out_packet.csr_new = csr_new_data;
        out_packet.csr_we = in_packet.valid && in_packet.uop.csr_valid &&
                            in_packet.uop.csr_write && !execute_exc.valid;
        out_packet.uop = in_packet.uop;
        out_packet.exc = execute_exc;
    end
endmodule
