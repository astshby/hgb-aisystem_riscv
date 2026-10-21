// Module: ras_decode
// Description: Decodes the architectural x1/x5 JAL and JALR return-stack hints.
module ras_decode (
    input logic [31:0] inst,
    output predictor_types_pkg::ras_op_e op
);
    import riscv_unpriv_pkg::*;
    import predictor_types_pkg::*;
    logic rd_link, rs1_link;

    // 本模块只解析 hint；调用方按指令 valid/异常资格决定是否应用事件。
    // 相同链接寄存器的 JALR 只 push；不同链接寄存器支持协程的 pop/push。
    always_comb begin
        rd_link = (inst[11:7] == 5'd1) || (inst[11:7] == 5'd5);
        rs1_link = (inst[19:15] == 5'd1) || (inst[19:15] == 5'd5);
        op = RAS_NONE;
        if (inst[6:0] == OPCODE_JAL && rd_link)
            op = RAS_PUSH;
        else if (inst[6:0] == OPCODE_JALR && inst[14:12] == F3_JALR) begin
            if (rd_link && rs1_link && inst[11:7] != inst[19:15])
                op = RAS_POP_PUSH;
            else if (rd_link)
                op = RAS_PUSH;
            else if (rs1_link)
                op = RAS_POP;
        end
    end
endmodule
