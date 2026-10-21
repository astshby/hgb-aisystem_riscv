// Module: mem_stage
// Description: Carries ordinary execution packets to WB and exposes registered MEM forwarding.
// 正常访存已在 EX 转交唯一 LSU owner；本级只保留普通执行包与早期异常。
module mem_stage (
    input  logic                              issue_enable, // 普通包本拍可推进至 WB。
    input  pipeline_pkg::ex_mem_t             in_packet,
    output pipeline_pkg::mem_wb_t             out_packet,
    output pipeline_pkg::gpr_forward_t        gpr_forward,
    output pipeline_pkg::csr_forward_t        csr_forward
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    // 输出打包：访存早期异常仍沿普通完成口返回，不创建外部事务。
    always_comb begin
        out_packet = '0;
        out_packet.retire_id = in_packet.retire_id;
        out_packet.valid = issue_enable && in_packet.valid;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
        out_packet.next_pc = in_packet.next_pc;
        out_packet.branch = in_packet.branch;
        out_packet.inst = in_packet.inst;
        out_packet.rd = in_packet.rd;
        out_packet.result = in_packet.result;
        out_packet.csr_addr = in_packet.csr_addr;
        out_packet.csr_old = in_packet.csr_old;
        out_packet.csr_new = in_packet.csr_new;
        out_packet.csr_we = in_packet.csr_we;
        out_packet.uop = in_packet.uop;
        out_packet.exc = in_packet.exc;
    end

    // MEM 前递：Load 地址永远不是结果；正常 Load 从 LSU 的寄存响应前递。
    always_comb begin
        unique case (in_packet.uop.wb_sel)
            WB_SEQ_PC: gpr_forward.data = in_packet.seq_pc;
            WB_CSR:    gpr_forward.data = in_packet.csr_old;
            default:   gpr_forward.data = in_packet.result;
        endcase
        // Store 不写 GPR；Load 的数据此时尚未返回。
        // 结果可用与能否推进分开：WB 等待时，MEM 中已算好的值仍可供 EX 使用。
        gpr_forward.valid = in_packet.valid && in_packet.uop.gpr_write &&
                            (in_packet.uop.wb_sel != WB_LOAD) && !in_packet.exc.valid;
        gpr_forward.addr = in_packet.rd;
    end

    // CSR 前递携带 EX 已完成 WARL 合法化的新值。
    always_comb begin
        csr_forward.valid = in_packet.valid && in_packet.csr_we &&
                            !in_packet.exc.valid;
        csr_forward.addr = in_packet.csr_addr;
        csr_forward.data = in_packet.csr_new;
    end
endmodule
