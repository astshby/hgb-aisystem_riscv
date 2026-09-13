// Module: ex_stage
// Description: Applies forwarding and executes ALU, CSR, address, branch, and JALR operations.
module ex_stage (
    input  pipeline_pkg::d2_ex_t         in_packet,
    input  pipeline_pkg::gpr_forward_t  mem_gpr_forward,
    input  pipeline_pkg::gpr_forward_t  wb_gpr_forward,
    input  core_types_pkg::xlen_t        csr_committed_data, // csr在ex阶段，不写入流水级寄存器合理
    input  pipeline_pkg::csr_forward_t  mem_csr_forward,
    input  pipeline_pkg::csr_forward_t  wb_csr_forward,
    output pipeline_pkg::ex_mem_t        out_packet,
    output pipeline_pkg::redirect_t      redirect,
    output pipeline_pkg::pred_update_t   pred_update,
    output logic                         serialize_req
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    xlen_t forwarded_rs1;
    xlen_t forwarded_rs2;
    xlen_t operand_a;
    xlen_t operand_b;
    xlen_t alu_result;
    logic branch_taken;
    xlen_t branch_target;
    logic control_op;
    logic mispredict;
    xlen_t csr_operand;
    xlen_t csr_old_data;
    xlen_t csr_proposed_data;
    xlen_t csr_new_data;
    exception_t execute_exc;

    // GPR 前递：MEM 比 WB 更新，因此 gpr_bypass 内部优先选择 MEM。
    gpr_bypass u_rs1_bypass (
        .source_addr(in_packet.rs1),
        .source_used(in_packet.uop.rs1_used),
        .original_data(in_packet.rs1_data),
        .mem_forward(mem_gpr_forward),
        .wb_forward(wb_gpr_forward),
        .forwarded_data(forwarded_rs1)
    );

    gpr_bypass u_rs2_bypass (
        .source_addr(in_packet.rs2),
        .source_used(in_packet.uop.rs2_used),
        .original_data(in_packet.rs2_data),
        .mem_forward(mem_gpr_forward),
        .wb_forward(wb_gpr_forward),
        .forwarded_data(forwarded_rs2)
    );

    // 操作数选择：CSR 立即数使用指令 rs1 字段中的零扩展 zimm。
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
        .taken(branch_taken),
        .target(branch_target)
    );

    // CSR 旁路在执行阶段选择最新值，与 GPR 操作数旁路保持相同边界。
    csr_bypass u_csr_bypass (
        .read_addr(in_packet.csr_addr),
        .committed_data(csr_committed_data),
        .mem_forward(mem_csr_forward),
        .wb_forward(wb_csr_forward),
        .bypass_data(csr_old_data)
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

    // EX 异常检测使用经过前递后的实际地址和控制流结果。
    ex_exception_check u_ex_exception_check (
        .in_packet,
        .effective_address(alu_result),
        .branch_taken,
        .branch_target,
        .exception(execute_exc)
    );

    // 只为 EX 本级新发现的异常请求序列化，前级异常已经在 D1 处理。
    always_comb begin
        serialize_req = in_packet.valid && !in_packet.exc.valid &&
                        execute_exc.valid;
    end

    // 分支控制：判断预测错误，并生成给 BTB/GShare 的实际执行结果。
    // control_op 包含条件分支与 JALR；JAL 已在 D1 处理。
    always_comb begin
        control_op = (in_packet.uop.branch_op != BR_NONE) &&
                     (in_packet.uop.branch_op != BR_JAL);
        mispredict = control_op &&
                     ((in_packet.pred.taken != branch_taken) ||
                      (branch_taken && (in_packet.pred.target != branch_target)));

        pred_update = '0;
        if (in_packet.valid && !execute_exc.valid && control_op) begin
            pred_update.valid = 1'b1;
            pred_update.kind = in_packet.uop.branch_op;
            pred_update.pc = in_packet.pc;
            pred_update.taken = branch_taken;
            pred_update.target = branch_target;
            pred_update.pred = in_packet.pred;
        end

        redirect = '0;
        if (in_packet.valid && mispredict && !execute_exc.valid) begin
            redirect.valid = 1'b1;
            redirect.pc = branch_taken ? branch_target : in_packet.seq_pc;
            redirect.reason = REDIR_EX_BRANCH;
        end
    end

    // 输出打包：Store 使用前递后的 rs2，CSR 同时携带旧值和 WARL 合法新值。
    always_comb begin
        out_packet = '0;
        out_packet.valid = in_packet.valid;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
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
        out_packet.pred = in_packet.pred;
        out_packet.exc = execute_exc;
    end
endmodule
