// Module: csr_access_check
// Description: Validates implemented M-mode CSR addresses and write permission.
// csr检测，比如布线检查（有些没有声明），权限检查（有些寄存器read-only），等等
module csr_access_check (
    input  core_types_pkg::csr_addr_t address,
    input  logic                      write_intent,
    output logic                      implemented,
    output logic                      read_only,
    output logic                      illegal
);
    import core_config_pkg::*;
    import riscv_priv_pkg::*;

    // 实现机器级同步异常及中断 CSR；MIP 的只读字段允许 CSR 写入但忽略。
    always_comb begin
        unique case (address)
            CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MIP, CSR_MTVEC, CSR_MSCRATCH, CSR_MEPC,
            CSR_MCAUSE, CSR_MTVAL, CSR_MCYCLE, CSR_MINSTRET,
            CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID:
                implemented = 1'b1;
            CSR_MCYCLEH, CSR_MINSTRETH:
                implemented = (XLEN == 32);
            default:
                implemented = 1'b0;
        endcase
        read_only = (address == CSR_MISA) ||
                    (address[11:10] == 2'b11); // 0xFxx 区域只读,0xBxx 不是只读
        illegal = !implemented || (write_intent && read_only);
    end
endmodule
