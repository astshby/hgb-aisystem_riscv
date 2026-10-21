// Module: commit_control
// Description: Qualifies architectural writes and commit trace from a completed oldest packet.
module commit_control (
    input  logic                        retire_fire,
    input  pipeline_pkg::retire_alloc_t head_meta,
    input  pipeline_pkg::retire_result_t head_result,
    output pipeline_pkg::gpr_forward_t  gpr_write,
    output pipeline_pkg::csr_forward_t  csr_write,
    output logic                        commit_valid,
    output core_types_pkg::xlen_t       commit_pc,
    output logic [31:0]                 commit_inst,
    output core_types_pkg::gpr_addr_t   commit_rd,
    output logic                        commit_rd_we,
    output core_types_pkg::xlen_t       commit_rd_data,
    output logic                        commit_exception
);
    import core_types_pkg::*;

    logic normal_commit;

    // retire_fire 只代表队头及所需响应均完整；等待资格由完成源保有。
    // D1 已将非法指令转换为异常；异常提交仍有效，但不能写架构寄存器。
    assign normal_commit = retire_fire && !head_result.exc.valid;

    // 按序退休写入 GPR，寄存器读口可同沿写穿透；x0 不产生真实写入。
    // EX 的带 ID 完成前递由完成源直接提供，不等待这里的退休资格。
    always_comb begin
        gpr_write.valid = normal_commit && head_meta.gpr_write && (head_meta.rd != '0);
        gpr_write.addr = head_meta.rd;
        gpr_write.data = head_result.gpr_data;
    end

    // CSR 只有在队头完整且无异常时提交，地址来自接纳信息，值来自完成结果。
    always_comb begin
        csr_write.valid = normal_commit && head_result.csr_write;
        csr_write.addr = head_meta.csr_addr;
        csr_write.data = head_result.csr_data;
    end

    // commit 仅在指令及其所需响应完整时产生；异常事件仍交给 Trap 观察。
    // 本模块不保存状态或增加寄存边界，不额外推迟队头退休。
    always_comb begin
        commit_valid = retire_fire;
        commit_pc = head_meta.pc;
        commit_inst = head_meta.inst;
        commit_rd = head_meta.rd;
        commit_rd_we = gpr_write.valid;
        commit_rd_data = head_result.gpr_data;
        commit_exception = retire_fire && head_result.exc.valid;
    end
endmodule
