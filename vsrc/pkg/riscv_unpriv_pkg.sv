// Package: riscv_unpriv_pkg
// Description: RISC-V unprivileged instruction encodings.
// 非特权指令集编码，包含基础指令、Zicsr 以及环境调用相关编码
package riscv_unpriv_pkg;
    localparam logic [6:0] OPCODE_LOAD      = 7'b0000011;
    localparam logic [6:0] OPCODE_MISC_MEM  = 7'b0001111; // FENCE 等杂项内存指令
    localparam logic [6:0] OPCODE_OP_IMM    = 7'b0010011; // I_ALU-XLEN
    localparam logic [6:0] OPCODE_AUIPC     = 7'b0010111;
    localparam logic [6:0] OPCODE_OP_IMM_32 = 7'b0011011; // I_ALU-32
    localparam logic [6:0] OPCODE_STORE     = 7'b0100011;
    localparam logic [6:0] OPCODE_OP        = 7'b0110011; // R-XLEN
    localparam logic [6:0] OPCODE_LUI       = 7'b0110111;
    localparam logic [6:0] OPCODE_OP_32     = 7'b0111011; // R-32
    localparam logic [6:0] OPCODE_BRANCH    = 7'b1100011;
    localparam logic [6:0] OPCODE_JALR      = 7'b1100111;
    localparam logic [6:0] OPCODE_JAL       = 7'b1101111;
    localparam logic [6:0] OPCODE_SYSTEM    = 7'b1110011;

    // funct3 的含义由 opcode 决定，因此名字保留所属指令组的上下文
    localparam logic [2:0] F3_JALR             = 3'b000;

    localparam logic [2:0] F3_BRANCH_BEQ       = 3'b000;
    localparam logic [2:0] F3_BRANCH_BNE       = 3'b001;
    localparam logic [2:0] F3_BRANCH_BLT       = 3'b100;
    localparam logic [2:0] F3_BRANCH_BGE       = 3'b101;
    localparam logic [2:0] F3_BRANCH_BLTU      = 3'b110;
    localparam logic [2:0] F3_BRANCH_BGEU      = 3'b111;

    localparam logic [2:0] F3_LOAD_LB          = 3'b000;
    localparam logic [2:0] F3_LOAD_LH          = 3'b001;
    localparam logic [2:0] F3_LOAD_LW          = 3'b010;
    localparam logic [2:0] F3_LOAD_LD          = 3'b011;
    localparam logic [2:0] F3_LOAD_LBU         = 3'b100;
    localparam logic [2:0] F3_LOAD_LHU         = 3'b101;
    localparam logic [2:0] F3_LOAD_LWU         = 3'b110;

    localparam logic [2:0] F3_STORE_SB         = 3'b000;
    localparam logic [2:0] F3_STORE_SH         = 3'b001;
    localparam logic [2:0] F3_STORE_SW         = 3'b010;
    localparam logic [2:0] F3_STORE_SD         = 3'b011;

    localparam logic [2:0] F3_OP_IMM_ADDI      = 3'b000;
    localparam logic [2:0] F3_OP_IMM_SLLI      = 3'b001;
    localparam logic [2:0] F3_OP_IMM_SLTI      = 3'b010;
    localparam logic [2:0] F3_OP_IMM_SLTIU     = 3'b011;
    localparam logic [2:0] F3_OP_IMM_XORI      = 3'b100;
    localparam logic [2:0] F3_OP_IMM_SRLI_SRAI = 3'b101;
    localparam logic [2:0] F3_OP_IMM_ORI       = 3'b110;
    localparam logic [2:0] F3_OP_IMM_ANDI      = 3'b111;

    localparam logic [2:0] F3_OP_ADD_SUB       = 3'b000;
    localparam logic [2:0] F3_OP_SLL           = 3'b001;
    localparam logic [2:0] F3_OP_SLT           = 3'b010;
    localparam logic [2:0] F3_OP_SLTU          = 3'b011;
    localparam logic [2:0] F3_OP_XOR           = 3'b100;
    localparam logic [2:0] F3_OP_SRL_SRA       = 3'b101;
    localparam logic [2:0] F3_OP_OR            = 3'b110;
    localparam logic [2:0] F3_OP_AND           = 3'b111;

    // RV64I 的 W 类指令只计算低 32 位，并将结果符号扩展到 XLEN（和原来的区别仅仅是opcode）
    // 从64角度讲，扩展都是取32的，有：R：addw，subw，sllw，srlw，sraw，
    // I：addiw，slliw，srliw，sraiw，L：lwu，ld，sd
    localparam logic [2:0] F3_OP_IMM_32_ADDIW      = 3'b000;
    localparam logic [2:0] F3_OP_IMM_32_SLLIW      = 3'b001;
    localparam logic [2:0] F3_OP_IMM_32_SRLIW_SRAIW = 3'b101;
    localparam logic [2:0] F3_OP_32_ADDW_SUBW      = 3'b000;
    localparam logic [2:0] F3_OP_32_SLLW           = 3'b001;
    localparam logic [2:0] F3_OP_32_SRLW_SRAW      = 3'b101;

    localparam logic [2:0] F3_MISC_MEM_FENCE   = 3'b000;
    localparam logic [2:0] F3_MISC_MEM_FENCE_I = 3'b001;

    // Zicsr 的寄存器与立即数形式共用 SYSTEM opcode
    localparam logic [2:0] F3_SYSTEM_ENV       = 3'b000; //ecall, ebreak, mret专用，它们用imm区分
    localparam logic [2:0] F3_SYSTEM_CSRRW     = 3'b001;
    localparam logic [2:0] F3_SYSTEM_CSRRS     = 3'b010;
    localparam logic [2:0] F3_SYSTEM_CSRRC     = 3'b011;
    localparam logic [2:0] F3_SYSTEM_CSRRWI    = 3'b101;
    localparam logic [2:0] F3_SYSTEM_CSRRSI    = 3'b110;
    localparam logic [2:0] F3_SYSTEM_CSRRCI    = 3'b111;

    // funct7 同样带上 OP/OP-IMM 上下文；M 扩展复用 F7_OP_MULDIV
    localparam logic [6:0] F7_OP_BASE          = 7'b0000000;
    localparam logic [6:0] F7_OP_SUB_SRA       = 7'b0100000;
    localparam logic [6:0] F7_OP_MULDIV        = 7'b0000001;
    // XLEN 位移在 RV32 检查 funct7，在 RV64 检查 funct6，避免误判合法的 shamt[5](多一位位移)
    localparam logic [6:0] F7_OP_IMM_SLLI      = 7'b0000000;
    localparam logic [6:0] F7_OP_IMM_SRLI      = 7'b0000000;
    localparam logic [6:0] F7_OP_IMM_SRAI      = 7'b0100000;
    localparam logic [5:0] F6_OP_IMM_SLLI      = 6'b000000;
    localparam logic [5:0] F6_OP_IMM_SRLI      = 6'b000000;
    localparam logic [5:0] F6_OP_IMM_SRAI      = 6'b010000;

    localparam logic [31:0] INST_ECALL  = 32'h0000_0073;
    localparam logic [31:0] INST_EBREAK = 32'h0010_0073;
endpackage
