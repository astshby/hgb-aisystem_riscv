// Module: csr_file
// Description: Implements the minimal machine CSR state, counters, trap entry, and MRET state.
// 真正的csr文件
module csr_file (
    input  logic                         clk,
    input  logic                         rst,
    input  core_types_pkg::csr_addr_t    read_addr,
    output core_types_pkg::xlen_t        read_data,
    input  logic                         write_valid,
    input  core_types_pkg::csr_addr_t    write_addr,
    input  core_types_pkg::xlen_t        write_legal_data,
    input  logic                         trap_enter,  // trap必要（暂时：ecall，ebreak）
    input  core_types_pkg::xlen_t        trap_pc,
    input  riscv_priv_pkg::exc_cause_e   trap_cause,
    input  core_types_pkg::xlen_t        trap_tval,
    input  logic                         mret_commit, // mret必要
    input  logic                         retire_valid, //指令计数相关
    output core_types_pkg::xlen_t        mtvec,
    output core_types_pkg::xlen_t        mepc
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;

    // Trap 状态使用 XLEN 宽寄存器；计数器始终保留完整 64 位状态。
    xlen_t mstatus_q, mstatus_d;
    xlen_t mtvec_q, mtvec_d;
    xlen_t mscratch_q, mscratch_d;
    xlen_t mepc_q, mepc_d;
    xlen_t mcause_q, mcause_d;
    xlen_t mtval_q, mtval_d;
    logic [63:0] mcycle_q, mcycle_d;
    logic [63:0] minstret_q, minstret_d;

    // misa 只读，通过函数写入值
    function automatic xlen_t misa_value();
        xlen_t value;
        value = '0;
        value[XLEN-1 -: 2] = (XLEN == 32) ? 2'b01 : 2'b10;
        value[8] = 1'b1;
        return value;
    endfunction

    // 必须给出mtevc与mepc的值，trap_controller中使用
    assign mtvec = mtvec_q;
    assign mepc = mepc_q;

    // 以下得_d连线，连线后写入寄存器
    // CSR 读取：只暴露 A4 已实现的机器级状态和只读标识。
    always_comb begin
        unique case (read_addr)
            CSR_MSTATUS:  read_data = mstatus_q;
            CSR_MISA:     read_data = misa_value();
            CSR_MTVEC:    read_data = mtvec_q;
            CSR_MSCRATCH: read_data = mscratch_q;
            CSR_MEPC:     read_data = mepc_q;
            CSR_MCAUSE:   read_data = mcause_q;
            CSR_MTVAL:    read_data = mtval_q;
            CSR_MCYCLE:   read_data = xlen_t'(mcycle_q);
            CSR_MINSTRET: read_data = xlen_t'(minstret_q);
            CSR_MCYCLEH:  read_data = xlen_t'(mcycle_q[63:32]);
            CSR_MINSTRETH: read_data = xlen_t'(minstret_q[63:32]);
            CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID,
            CSR_MHARTID:  read_data = '0;
            default:      read_data = '0;
        endcase
    end

    // Trap CSR 下一状态：普通 CSR 写 < MRET < trap，最老的 trap 优先级最高。
    // 普通写入值已在 EX 完成 WARL；Trap/MRET 按架构语义直接更新多个状态位。
    always_comb begin
        mstatus_d = mstatus_q;
        mtvec_d = mtvec_q;
        mscratch_d = mscratch_q;
        mepc_d = mepc_q;
        mcause_d = mcause_q;
        mtval_d = mtval_q;

        if (write_valid) begin
            unique case (write_addr)
                CSR_MSTATUS:  mstatus_d = write_legal_data;
                CSR_MTVEC:    mtvec_d = write_legal_data;
                CSR_MSCRATCH: mscratch_d = write_legal_data;
                CSR_MEPC:     mepc_d = write_legal_data;
                CSR_MCAUSE:   mcause_d = write_legal_data;
                CSR_MTVAL:    mtval_d = write_legal_data;
                default: ;
            endcase
        end

        if (mret_commit) begin
            mstatus_d[MSTATUS_MIE_BIT] = mstatus_q[MSTATUS_MPIE_BIT];
            mstatus_d[MSTATUS_MPIE_BIT] = 1'b1;
            mstatus_d[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = 2'b11;
        end

        if (trap_enter) begin
            mepc_d = trap_pc & ~xlen_t'(3);
            mcause_d = xlen_t'(trap_cause);
            mtval_d = trap_tval;
            mstatus_d[MSTATUS_MPIE_BIT] = mstatus_q[MSTATUS_MIE_BIT];
            mstatus_d[MSTATUS_MIE_BIT] = 1'b0;
            mstatus_d[MSTATUS_MPP_MSB:MSTATUS_MPP_LSB] = 2'b11;
        end
    end

    // 性能计数器下一状态：每拍增加 MCYCLE，只有正常退休才增加 MINSTRET；显式写入优先。
    // RV32 可分别访问低/高 32 位，RV64 通过低地址一次访问全部 64 位。
    always_comb begin
        mcycle_d = mcycle_q + 64'd1;
        minstret_d = minstret_q;
        if (retire_valid)
            minstret_d = minstret_q + 64'd1;

        if (write_valid) begin
            unique case (write_addr)
                CSR_MCYCLE: begin
                    if (XLEN == 32)
                        mcycle_d[31:0] = write_legal_data[31:0];
                    else
                        mcycle_d = {{(64-XLEN){1'b0}}, write_legal_data};
                end
                CSR_MINSTRET: begin
                    if (XLEN == 32)
                        minstret_d[31:0] = write_legal_data[31:0];
                    else
                        minstret_d = {{(64-XLEN){1'b0}}, write_legal_data};
                end
                CSR_MCYCLEH: begin
                    if (XLEN == 32)
                        mcycle_d[63:32] = write_legal_data[31:0];
                end
                CSR_MINSTRETH: begin
                    if (XLEN == 32)
                        minstret_d[63:32] = write_legal_data[31:0];
                end
                default: ;
            endcase
        end
    end

    // 正式写入寄存器
    // Trap 相关状态寄存器。
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_q <= xlen_t'(32'h0000_1800);
            mtvec_q <= '0;
            mscratch_q <= '0;
            mepc_q <= '0;
            mcause_q <= '0;
            mtval_q <= '0;
        end else begin
            mstatus_q <= mstatus_d;
            mtvec_q <= mtvec_d;
            mscratch_q <= mscratch_d;
            mepc_q <= mepc_d;
            mcause_q <= mcause_d;
            mtval_q <= mtval_d;
        end
    end

    // 性能计数器的寄存器。
    always_ff @(posedge clk) begin
        if (rst) begin
            mcycle_q <= '0;
            minstret_q <= '0;
        end else begin
            mcycle_q <= mcycle_d;
            minstret_q <= minstret_d;
        end
    end
endmodule
