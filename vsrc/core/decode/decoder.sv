// Module: decoder
// Description: Converts a canonical 32-bit instruction into a typed uOp.
// 负责解码，获得静态信息uop
module decoder (
    input  logic [31:0]              inst,
    output core_types_pkg::uop_t     uop,
    output core_types_pkg::gpr_addr_t rs1,
    output core_types_pkg::gpr_addr_t rs2,
    output core_types_pkg::gpr_addr_t rd,
    output core_types_pkg::csr_addr_t csr_addr
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_unpriv_pkg::*;
    import riscv_priv_pkg::*;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    always_comb begin
        opcode = inst[6:0];
        funct3 = inst[14:12];
        funct7 = inst[31:25];
        rs1 = inst[19:15];
        rs2 = inst[24:20];
        rd = inst[11:7];
        csr_addr = inst[31:20];
        uop = '0;
        // 默认不合法，‘白名单’
        uop.illegal = 1'b1;

        // unique case:并行执行，互斥分支,case类似c语言顺序执行
        unique case (opcode)
            OPCODE_LUI: begin
                uop.illegal = 1'b0;
                uop.fu = FU_ALU;
                uop.alu_op = ALU_ADD;
                uop.op_a_sel = OP_A_ZERO;
                uop.op_b_sel = OP_B_IMM;
                uop.gpr_write = 1'b1;
                uop.wb_sel = WB_ALU;
            end
            OPCODE_AUIPC: begin
                uop.illegal = 1'b0;
                uop.fu = FU_ALU;
                uop.alu_op = ALU_ADD;
                uop.op_a_sel = OP_A_PC;
                uop.op_b_sel = OP_B_IMM;
                uop.gpr_write = 1'b1;
                uop.wb_sel = WB_ALU;
            end
            OPCODE_JAL: begin
                uop.illegal = 1'b0;
                uop.fu = FU_BRANCH;
                uop.branch_op = BR_JAL;
                uop.gpr_write = 1'b1;
                uop.wb_sel = WB_SEQ_PC;
            end
            OPCODE_JALR: begin
                if (funct3 == F3_JALR) begin // RV 要求 JALR 的 funct3 必须为 000
                    uop.illegal = 1'b0;
                    uop.fu = FU_BRANCH;
                    uop.branch_op = BR_JALR;
                    uop.rs1_used = 1'b1;
                    uop.gpr_write = 1'b1;
                    uop.wb_sel = WB_SEQ_PC;
                end
            end
            OPCODE_BRANCH: begin
                uop.fu = FU_BRANCH;
                uop.rs1_used = 1'b1;
                uop.rs2_used = 1'b1;
                unique case (funct3)
                    F3_BRANCH_BEQ:  begin uop.branch_op = BR_EQ;  uop.illegal = 1'b0; end
                    F3_BRANCH_BNE:  begin uop.branch_op = BR_NE;  uop.illegal = 1'b0; end
                    F3_BRANCH_BLT:  begin uop.branch_op = BR_LT;  uop.illegal = 1'b0; end
                    F3_BRANCH_BGE:  begin uop.branch_op = BR_GE;  uop.illegal = 1'b0; end
                    F3_BRANCH_BLTU: begin uop.branch_op = BR_LTU; uop.illegal = 1'b0; end
                    F3_BRANCH_BGEU: begin uop.branch_op = BR_GEU; uop.illegal = 1'b0; end
                    default: ;
                endcase
            end
            OPCODE_LOAD: begin
                uop.fu = FU_LSU;
                uop.alu_op = ALU_ADD;
                uop.op_a_sel = OP_A_RS1;
                uop.op_b_sel = OP_B_IMM;
                uop.rs1_used = 1'b1;
                uop.gpr_write = 1'b1;
                uop.mem_read = 1'b1;
                uop.wb_sel = WB_LOAD;
                unique case (funct3)
                    F3_LOAD_LB:  begin uop.mem_size = MEM_BYTE; uop.illegal = 1'b0; end
                    F3_LOAD_LH:  begin uop.mem_size = MEM_HALF; uop.illegal = 1'b0; end
                    F3_LOAD_LW:  begin uop.mem_size = MEM_WORD; uop.illegal = 1'b0; end
                    F3_LOAD_LD:  if (XLEN == 64) begin  // 64XLEN才会出现
                        uop.mem_size = MEM_DWORD;
                        uop.illegal = 1'b0;
                    end
                    F3_LOAD_LBU: begin uop.mem_size = MEM_BYTE; uop.load_unsigned = 1'b1; uop.illegal = 1'b0; end
                    F3_LOAD_LHU: begin uop.mem_size = MEM_HALF; uop.load_unsigned = 1'b1; uop.illegal = 1'b0; end
                    F3_LOAD_LWU: if (XLEN == 64) begin
                        uop.mem_size = MEM_WORD;
                        uop.load_unsigned = 1'b1;
                        uop.illegal = 1'b0;
                    end
                    default: ;
                endcase
            end
            OPCODE_STORE: begin
                uop.fu = FU_LSU;
                uop.alu_op = ALU_ADD;
                uop.op_a_sel = OP_A_RS1;
                uop.op_b_sel = OP_B_IMM;
                uop.rs1_used = 1'b1;
                uop.rs2_used = 1'b1;
                uop.mem_write = 1'b1;
                unique case (funct3)
                    F3_STORE_SB: begin uop.mem_size = MEM_BYTE; uop.illegal = 1'b0; end
                    F3_STORE_SH: begin uop.mem_size = MEM_HALF; uop.illegal = 1'b0; end
                    F3_STORE_SW: begin uop.mem_size = MEM_WORD; uop.illegal = 1'b0; end
                    F3_STORE_SD: if (XLEN == 64) begin uop.mem_size = MEM_DWORD; uop.illegal = 1'b0; end
                    default: ;
                endcase
            end
            OPCODE_OP_IMM: begin
                uop.fu = FU_ALU;
                uop.op_a_sel = OP_A_RS1;
                uop.op_b_sel = OP_B_IMM;
                uop.rs1_used = 1'b1;
                uop.gpr_write = 1'b1;
                uop.wb_sel = WB_ALU;
                unique case (funct3)
                    F3_OP_IMM_ADDI:  begin uop.alu_op = ALU_ADD;  uop.illegal = 1'b0; end
                    F3_OP_IMM_SLTI:  begin uop.alu_op = ALU_SLT;  uop.illegal = 1'b0; end
                    F3_OP_IMM_SLTIU: begin uop.alu_op = ALU_SLTU; uop.illegal = 1'b0; end
                    F3_OP_IMM_XORI:  begin uop.alu_op = ALU_XOR;  uop.illegal = 1'b0; end
                    F3_OP_IMM_ORI:   begin uop.alu_op = ALU_OR;   uop.illegal = 1'b0; end
                    F3_OP_IMM_ANDI:  begin uop.alu_op = ALU_AND;  uop.illegal = 1'b0; end
                    F3_OP_IMM_SLLI: begin
                        // imm的32/64由于位移位数的不同产生里funct7与funct6的区别
                        if (((XLEN == 32) && (funct7 == F7_OP_IMM_SLLI)) ||
                            ((XLEN == 64) && (inst[31:26] == F6_OP_IMM_SLLI))) begin
                            uop.alu_op = ALU_SLL;
                            uop.illegal = 1'b0;
                        end
                    end
                    F3_OP_IMM_SRLI_SRAI: begin
                        if (((XLEN == 32) && (funct7 == F7_OP_IMM_SRLI)) ||
                            ((XLEN == 64) && (inst[31:26] == F6_OP_IMM_SRLI))) begin
                            uop.alu_op = ALU_SRL;
                            uop.illegal = 1'b0;
                        end else if (((XLEN == 32) && (funct7 == F7_OP_IMM_SRAI)) ||
                                     ((XLEN == 64) && (inst[31:26] == F6_OP_IMM_SRAI))) begin
                            uop.alu_op = ALU_SRA;
                            uop.illegal = 1'b0;
                        end
                    end
                    default: ;
                endcase
            end
            OPCODE_OP_IMM_32: begin
                if (XLEN == 64) begin
                    uop.fu = FU_ALU;
                    uop.op_a_sel = OP_A_RS1;
                    uop.op_b_sel = OP_B_IMM;
                    uop.op_width = OP_WIDTH_WORD;
                    uop.rs1_used = 1'b1;
                    uop.gpr_write = 1'b1;
                    uop.wb_sel = WB_ALU;
                    unique case (funct3)
                        F3_OP_IMM_32_ADDIW: begin
                            uop.alu_op = ALU_ADD;
                            uop.illegal = 1'b0;
                        end
                        F3_OP_IMM_32_SLLIW: if (funct7 == F7_OP_BASE) begin
                            uop.alu_op = ALU_SLL;
                            uop.illegal = 1'b0;
                        end
                        F3_OP_IMM_32_SRLIW_SRAIW: begin
                            if (funct7 == F7_OP_BASE) begin
                                uop.alu_op = ALU_SRL;
                                uop.illegal = 1'b0;
                            end else if (funct7 == F7_OP_SUB_SRA) begin
                                uop.alu_op = ALU_SRA;
                                uop.illegal = 1'b0;
                            end
                        end
                        default: ;
                    endcase
                end
            end
            OPCODE_OP: begin
                uop.fu = FU_ALU;
                uop.op_a_sel = OP_A_RS1;
                uop.op_b_sel = OP_B_RS2;
                uop.rs1_used = 1'b1;
                uop.rs2_used = 1'b1;
                uop.gpr_write = 1'b1;
                uop.wb_sel = WB_ALU;
                unique case (funct3)
                    F3_OP_ADD_SUB: begin
                        if (funct7 == F7_OP_BASE) begin
                            uop.alu_op = ALU_ADD;
                            uop.illegal = 1'b0;
                        end else if (funct7 == F7_OP_SUB_SRA) begin
                            uop.alu_op = ALU_SUB;
                            uop.illegal = 1'b0;
                        end
                    end
                    F3_OP_SLL:  if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_SLL;  uop.illegal = 1'b0; end
                    F3_OP_SLT:  if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_SLT;  uop.illegal = 1'b0; end
                    F3_OP_SLTU: if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_SLTU; uop.illegal = 1'b0; end
                    F3_OP_XOR:  if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_XOR;  uop.illegal = 1'b0; end
                    F3_OP_SRL_SRA: begin
                        if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_SRL; uop.illegal = 1'b0; end
                        else if (funct7 == F7_OP_SUB_SRA) begin uop.alu_op = ALU_SRA; uop.illegal = 1'b0; end
                    end
                    F3_OP_OR:  if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_OR;  uop.illegal = 1'b0; end
                    F3_OP_AND: if (funct7 == F7_OP_BASE) begin uop.alu_op = ALU_AND; uop.illegal = 1'b0; end
                    default: ;
                endcase
            end
            OPCODE_OP_32: begin
                if (XLEN == 64) begin
                    uop.fu = FU_ALU;
                    uop.op_a_sel = OP_A_RS1;
                    uop.op_b_sel = OP_B_RS2;
                    uop.op_width = OP_WIDTH_WORD;
                    uop.rs1_used = 1'b1;
                    uop.rs2_used = 1'b1;
                    uop.gpr_write = 1'b1;
                    uop.wb_sel = WB_ALU;
                    unique case (funct3)
                        F3_OP_32_ADDW_SUBW: begin
                            if (funct7 == F7_OP_BASE) begin
                                uop.alu_op = ALU_ADD;
                                uop.illegal = 1'b0;
                            end else if (funct7 == F7_OP_SUB_SRA) begin
                                uop.alu_op = ALU_SUB;
                                uop.illegal = 1'b0;
                            end
                        end
                        F3_OP_32_SLLW: if (funct7 == F7_OP_BASE) begin
                            uop.alu_op = ALU_SLL;
                            uop.illegal = 1'b0;
                        end
                        F3_OP_32_SRLW_SRAW: begin
                            if (funct7 == F7_OP_BASE) begin
                                uop.alu_op = ALU_SRL;
                                uop.illegal = 1'b0;
                            end else if (funct7 == F7_OP_SUB_SRA) begin
                                uop.alu_op = ALU_SRA;
                                uop.illegal = 1'b0;
                            end
                        end
                        default: ;
                    endcase
                end
            end
            OPCODE_SYSTEM: begin
                if (funct3 == F3_SYSTEM_ENV) begin
                    unique case (inst)
                        INST_ECALL:  begin uop.sys_op = SYS_ECALL;  uop.illegal = 1'b0; end
                        INST_EBREAK: begin uop.sys_op = SYS_EBREAK; uop.illegal = 1'b0; end
                        INST_MRET:   begin uop.sys_op = SYS_MRET;   uop.illegal = 1'b0; end
                        default: ;
                    endcase
                end
                else begin
                    unique case (funct3)
                        F3_SYSTEM_CSRRW, F3_SYSTEM_CSRRWI: begin
                            uop.csr_cmd = CSR_RW;
                            uop.csr_write = 1'b1;
                            uop.illegal = 1'b0;
                        end
                        F3_SYSTEM_CSRRS, F3_SYSTEM_CSRRSI: begin
                            uop.csr_cmd = CSR_RS;
                            uop.csr_write = (rs1 != '0);
                            uop.illegal = 1'b0;
                        end
                        F3_SYSTEM_CSRRC, F3_SYSTEM_CSRRCI: begin
                            uop.csr_cmd = CSR_RC;
                            uop.csr_write = (rs1 != '0);
                            uop.illegal = 1'b0;
                        end
                        default: ;
                    endcase
                    if (!uop.illegal) begin
                        uop.fu = FU_CSR;
                        uop.csr_valid = 1'b1;
                        uop.csr_imm = funct3[2]; //imm由高位指定
                        uop.rs1_used = !funct3[2] && (rs1 != '0);
                        uop.gpr_write = 1'b1;
                        uop.wb_sel = WB_CSR;
                    end
                end
            end
            // 内存排序与取指同步指令
            OPCODE_MISC_MEM: begin
                if ((funct3 == F3_MISC_MEM_FENCE) ||
                    (funct3 == F3_MISC_MEM_FENCE_I))
                    uop.illegal = 1'b0;
            end
            default: ;
        endcase
    end
endmodule
