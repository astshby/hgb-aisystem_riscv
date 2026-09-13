// Module: d2_stage
// Description: Adds register operands to the decoded packet before EX.
// 得到寄存器数据，一并传给 EX 阶段
module d2_stage (
    input  pipeline_pkg::d1_d2_t in_packet,
    input  core_types_pkg::xlen_t rs1_data,
    input  core_types_pkg::xlen_t rs2_data,
    output pipeline_pkg::d2_ex_t  out_packet
);
    // 具体 regfile 连接在 core；CSR 立即数在 EX 使用 rs1 地址字段转换，避免覆盖真实读值。
    always_comb begin
        out_packet = '0;
        out_packet.valid = in_packet.valid;
        out_packet.pc = in_packet.pc;
        out_packet.seq_pc = in_packet.seq_pc;
        out_packet.inst = in_packet.inst;
        out_packet.rs1 = in_packet.rs1;
        out_packet.rs2 = in_packet.rs2;
        out_packet.rd = in_packet.rd;
        out_packet.rs1_data = rs1_data;
        out_packet.rs2_data = rs2_data;
        out_packet.imm = in_packet.imm;
        out_packet.csr_addr = in_packet.csr_addr;
        out_packet.uop = in_packet.uop;
        out_packet.pred = in_packet.pred;
        out_packet.exc = in_packet.exc;
    end
endmodule
