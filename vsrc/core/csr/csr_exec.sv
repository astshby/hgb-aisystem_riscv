// Module: csr_exec
// Description: Computes the atomic Zicsr read-modify-write result.
module csr_exec (
    input  core_types_pkg::csr_cmd_e command,
    input  core_types_pkg::xlen_t   old_value,
    input  core_types_pkg::xlen_t   operand,  //立即数/寄存器值
    output core_types_pkg::xlen_t   new_value
);
    import core_types_pkg::*;

    // Zicsr 在一个组合块内完成“读旧值、按命令修改、产生新值”。
    always_comb begin
        unique case (command)
            CSR_RW:  new_value = operand;
            CSR_RS:  new_value = old_value | operand;
            CSR_RC:  new_value = old_value & ~operand;
            default: new_value = old_value;
        endcase
    end
endmodule
