// Module: d1_exception_check
// Description: Creates synchronous exceptions that are fully known after initial decode.
// 处理 D1 级检查出来的异常：检查指令地址、译码结果、SYSTEM 操作及 JAL 目标地址。
module d1_exception_check (
    input  pipeline_pkg::if_d1_t      in_packet,
    input  core_types_pkg::uop_t      uop,
    input  core_types_pkg::xlen_t     jal_target,
    output pipeline_pkg::exception_t  exception
);
    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    // D1 按优先级记录最早发现的异常，后续流水级只允许补充而不能覆盖。
    always_comb begin
        exception = '0;
        if (in_packet.valid) begin
            if (in_packet.pc[1:0] != 2'b00) begin
                exception.valid = 1'b1;
                exception.cause = EXC_INST_ADDR_MISALIGNED;
                exception.tval = in_packet.pc;
            end
            else if (uop.illegal) begin
                exception.valid = 1'b1;
                exception.cause = EXC_ILLEGAL_INST;
                exception.tval = xlen_t'(in_packet.inst);
            end
            else if (uop.sys_op == SYS_ECALL) begin
                exception.valid = 1'b1;
                exception.cause = EXC_ECALL_M;
            end
            else if (uop.sys_op == SYS_EBREAK) begin
                exception.valid = 1'b1;
                exception.cause = EXC_BREAKPOINT;
            end
            // JAL 无寄存器依赖，其实际目标可以在 D1 提前完成地址对齐检查。
            else if ((uop.branch_op == BR_JAL) && (jal_target[1:0] != 2'b00)) begin
                exception.valid = 1'b1;
                exception.cause = EXC_INST_ADDR_MISALIGNED;
                exception.tval = jal_target;
            end
        end
    end
endmodule
