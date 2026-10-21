// Module: alu_secondary
// Description: Executes the independent second integer lane and holds one tagged completion.
module alu_secondary (
    input logic clk, rst, cancel,
    input logic issue_valid,
    output logic issue_ready,
    input pipeline_pkg::d2_ex_t packet,
    output logic complete_valid,
    input logic complete_ready,
    output pipeline_pkg::retire_completion_t completion,
    output logic busy
);
    import core_types_pkg::*;
    import pipeline_pkg::*;
    logic valid_q;
    retire_completion_t result_q;
    xlen_t operand_a, operand_b, alu_result;
    always_comb begin
        unique case (packet.uop.op_a_sel)
            OP_A_RS1: operand_a = packet.rs1_data;
            OP_A_PC: operand_a = packet.pc;
            default: operand_a = '0;
        endcase
        operand_b = packet.uop.op_b_sel == OP_B_IMM ? packet.imm : packet.rs2_data;
    end
    alu u_alu (.operation(packet.uop.alu_op), .operand_a, .operand_b,
               .op_width(packet.uop.op_width), .result(alu_result));

    // 第二槽只有普通ALU，结果仍先寄存再回填；可同沿交付旧结果并接纳下一条。
    assign complete_valid = !rst && valid_q;
    assign completion = result_q;
    assign issue_ready = !rst && !cancel && (!valid_q || complete_ready);
    assign busy = valid_q;
    always_ff @(posedge clk) begin
        if (rst || cancel) valid_q <= 1'b0;
        else begin
            if (complete_valid && complete_ready) valid_q <= 1'b0;
            if (issue_valid && issue_ready) begin
                valid_q <= 1'b1;
                result_q <= '{id:packet.retire_id, result:'{next_pc:packet.seq_pc,
                    gpr_data:alu_result, csr_data:'0, csr_write:1'b0, exc:'0, branch:'0}};
            end
        end
    end
endmodule
