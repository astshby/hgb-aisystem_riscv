// Module: imm_gen
// Description: Expands RISC-V immediates to XLEN using opcode format.
// 产生立即数并扩展到XLEN位宽
module imm_gen (
    input  logic [31:0]                       inst,
    output logic [core_config_pkg::XLEN-1:0] imm
);
    import core_config_pkg::*;
    import riscv_unpriv_pkg::*;

    always_comb begin
        unique case (inst[6:0])
            OPCODE_OP_IMM, OPCODE_OP_IMM_32, OPCODE_LOAD, OPCODE_JALR, OPCODE_SYSTEM: //sys指令也是I解码
                imm = {{(XLEN-12){inst[31]}}, inst[31:20]};
            OPCODE_STORE:
                imm = {{(XLEN-12){inst[31]}}, inst[31:25], inst[11:7]};
            OPCODE_BRANCH:
                imm = {{(XLEN-13){inst[31]}}, inst[31], inst[7],
                       inst[30:25], inst[11:8], 1'b0};
            OPCODE_LUI, OPCODE_AUIPC:
                imm = {{(XLEN-32){inst[31]}}, inst[31:12], 12'b0};
            OPCODE_JAL:
                imm = {{(XLEN-21){inst[31]}}, inst[31], inst[19:12],
                       inst[20], inst[30:21], 1'b0};
            default:
                imm = '0;
        endcase
    end
endmodule
