// Module: ex_exception_check
// Description: Adds synchronous exceptions that become known in the EX stage.
// 处理ex级检查出来的异常：检查 CSR 权限、访存地址及实际控制流目标是否有效。
module ex_exception_check (
    input  pipeline_pkg::d2_ex_t      in_packet,
    input  core_types_pkg::xlen_t     effective_address,
    input  logic                      branch_taken,
    input  core_types_pkg::xlen_t     branch_target,
    output pipeline_pkg::exception_t  exception
);
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic csr_access_illegal;
    logic control_op;

    // 用于检测mem地址对齐
    function automatic logic address_misaligned(
        input xlen_t address,
        input mem_size_e size
    );
        unique case (size)
            MEM_BYTE:  address_misaligned = 1'b0;
            MEM_HALF:  address_misaligned = address[0];
            MEM_WORD:  address_misaligned = |address[1:0];
            default:   address_misaligned = |address[2:0];
        endcase
    endfunction

    // 用于检测CSR 地址实现情况和写权限。(模块位于csr文件夹)
    csr_access_check u_csr_access_check (
        .address(in_packet.csr_addr),
        .write_intent(in_packet.uop.csr_write),
        .implemented(),
        .read_only(),
        .illegal(csr_access_illegal)
    );

    // 用于剩余的分支地址对齐检测：JAL 已在 D1 检查；条件分支与 JALR 的实际目标在 EX 才能确定。
    always_comb begin
        control_op = (in_packet.uop.branch_op != BR_NONE) &&
                     (in_packet.uop.branch_op != BR_JAL);
    end

    // 已有异常优先，后续阶段只能在没有异常时补充新的异常信息。
    always_comb begin
        exception = in_packet.exc;
        if (in_packet.valid && !exception.valid) begin
            if (in_packet.uop.csr_valid && csr_access_illegal) begin
                exception.valid = 1'b1;
                exception.cause = EXC_ILLEGAL_INST;
                exception.tval = xlen_t'(in_packet.inst);
            end
            else if ((in_packet.uop.mem_read || in_packet.uop.mem_write) &&
                         address_misaligned(effective_address, in_packet.uop.mem_size)) begin
                exception.valid = 1'b1;
                exception.cause = in_packet.uop.mem_read
                                ? EXC_LOAD_ADDR_MISALIGNED
                                : EXC_STORE_ADDR_MISALIGNED;
                exception.tval = effective_address;
            end
            else if (control_op && branch_taken && (branch_target[1:0] != 2'b00)) begin
                exception.valid = 1'b1;
                exception.cause = EXC_INST_ADDR_MISALIGNED;
                exception.tval = branch_target;
            end
        end
    end
endmodule
