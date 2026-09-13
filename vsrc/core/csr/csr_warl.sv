// Module: csr_warl
// Description: Legalizes writable CSR values before forwarding and architectural commit.
// 将软件写入的值合法化
module csr_warl (
    input  core_types_pkg::csr_addr_t address,
    input  core_types_pkg::xlen_t    proposed_value,
    output core_types_pkg::xlen_t    legal_value
);
    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    // 旁路和最终提交必须看到同一个合法值，避免相邻 CSR 指令读取非法中间态。
    always_comb begin
        legal_value = proposed_value;
        unique case (address)
            // mstatus只保留实现的MIE/MPIE/MPP位，其他位写入0
            CSR_MSTATUS: begin
                legal_value = '0;
                legal_value[MSTATUS_MIE_BIT] = proposed_value[MSTATUS_MIE_BIT];
                legal_value[MSTATUS_MPIE_BIT] = proposed_value[MSTATUS_MPIE_BIT];
                legal_value[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = 2'b11;
            end
            // mtvec和mepc的低两位必须为0
            CSR_MTVEC, CSR_MEPC: legal_value = proposed_value & ~xlen_t'(3);
            default: ;
        endcase
    end
endmodule
