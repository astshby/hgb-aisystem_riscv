// Package: rv_asm_pkg
// Description: Small instruction encoders for self-contained directed tests.
// 类似于一个解码器,仿真便利化使用
package rv_asm_pkg;
    import riscv_unpriv_pkg::*;
    import riscv_priv_pkg::*;

    localparam logic [31:0] TEST_RESULT_ADDR = 32'h0000_1000;

    // function用于‘函数’计算，是零时间计算（通常不包含时序），task可包含，module是标准的模块
    // automatic,每次 function 调用拥有自己独立的局部存储，对于递归/并发很重要
    // 名字赋值，每次返回的都是名字所“调用”的函数

    // 下方的 enc_* 函数生成rv指令的二进制编码
    function automatic logic [31:0] enc_r(
        input logic [6:0] funct7,
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [2:0] funct3,
        input logic [4:0] rd,
        input logic [6:0] opcode
    );
        enc_r = {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction

    function automatic logic [31:0] enc_i(
        input integer imm,
        input logic [4:0] rs1,
        input logic [2:0] funct3,
        input logic [4:0] rd,
        input logic [6:0] opcode
    );
        enc_i = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction

    function automatic logic [31:0] enc_s(
        input integer imm,
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [2:0] funct3
    );
        enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], OPCODE_STORE};
    endfunction

    function automatic logic [31:0] enc_b(
        input integer imm,
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [2:0] funct3
    );
        enc_b = {imm[12], imm[10:5], rs2, rs1, funct3,
                 imm[4:1], imm[11], OPCODE_BRANCH};
    endfunction

    function automatic logic [31:0] enc_u(
        input logic [19:0] imm20,
        input logic [4:0] rd,
        input logic [6:0] opcode
    );
        enc_u = {imm20, rd, opcode};
    endfunction

    function automatic logic [31:0] enc_j(
        input integer imm,
        input logic [4:0] rd
    );
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, OPCODE_JAL};
    endfunction

    // 语义化封装按照汇编操作数顺序传参，便于阅读整核测试程序
    function automatic logic [31:0] enc_add(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        enc_add = enc_r(F7_OP_BASE, rs2, rs1, F3_OP_ADD_SUB, rd, OPCODE_OP);
    endfunction

    function automatic logic [31:0] enc_addi(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_addi = enc_i(imm, rs1, F3_OP_IMM_ADDI, rd, OPCODE_OP_IMM);
    endfunction

    // M 指令仍是 R 编码；独立语义封装避免测试中混淆 signed、高半积和 W 形式。
    function automatic logic [31:0] enc_mul(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_MUL, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_mulh(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_MULH, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_mulhsu(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_MULHSU, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_mulhu(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_MULHU, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_div(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_DIV, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_divu(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_DIVU, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_rem(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_REM, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_remu(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_REMU, rd, OPCODE_OP);
    endfunction
    function automatic logic [31:0] enc_mulw(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_32_MULW, rd, OPCODE_OP_32);
    endfunction
    function automatic logic [31:0] enc_divw(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_32_DIVW, rd, OPCODE_OP_32);
    endfunction
    function automatic logic [31:0] enc_divuw(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_32_DIVUW, rd, OPCODE_OP_32);
    endfunction
    function automatic logic [31:0] enc_remw(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_32_REMW, rd, OPCODE_OP_32);
    endfunction
    function automatic logic [31:0] enc_remuw(input logic [4:0] rd, rs1, rs2);
        return enc_r(F7_OP_MULDIV, rs2, rs1, F3_OP_32_REMUW, rd, OPCODE_OP_32);
    endfunction

    function automatic logic [31:0] enc_lw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_lw = enc_i(imm, rs1, F3_LOAD_LW, rd, OPCODE_LOAD);
    endfunction

    function automatic logic [31:0] enc_ld(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_ld = enc_i(imm, rs1, F3_LOAD_LD, rd, OPCODE_LOAD);
    endfunction

    function automatic logic [31:0] enc_lwu(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_lwu = enc_i(imm, rs1, F3_LOAD_LWU, rd, OPCODE_LOAD);
    endfunction

    function automatic logic [31:0] enc_sw(
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_sw = enc_s(imm, rs2, rs1, F3_STORE_SW);
    endfunction

    function automatic logic [31:0] enc_sd(
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_sd = enc_s(imm, rs2, rs1, F3_STORE_SD);
    endfunction

    function automatic logic [31:0] enc_slli(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer shamt
    );
        enc_slli = enc_i(shamt, rs1, F3_OP_IMM_SLLI, rd, OPCODE_OP_IMM);
    endfunction

    function automatic logic [31:0] enc_srli(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer shamt
    );
        enc_srli = enc_i(shamt, rs1, F3_OP_IMM_SRLI_SRAI, rd, OPCODE_OP_IMM);
    endfunction

    function automatic logic [31:0] enc_addiw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_addiw = enc_i(imm, rs1, F3_OP_IMM_32_ADDIW, rd, OPCODE_OP_IMM_32);
    endfunction

    function automatic logic [31:0] enc_slliw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer shamt
    );
        enc_slliw = enc_i(shamt, rs1, F3_OP_IMM_32_SLLIW, rd, OPCODE_OP_IMM_32);
    endfunction

    function automatic logic [31:0] enc_addw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        enc_addw = enc_r(F7_OP_BASE, rs2, rs1, F3_OP_32_ADDW_SUBW, rd, OPCODE_OP_32);
    endfunction

    function automatic logic [31:0] enc_subw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        enc_subw = enc_r(F7_OP_SUB_SRA, rs2, rs1, F3_OP_32_ADDW_SUBW, rd, OPCODE_OP_32);
    endfunction

    function automatic logic [31:0] enc_sraw(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input logic [4:0] rs2
    );
        enc_sraw = enc_r(F7_OP_SUB_SRA, rs2, rs1, F3_OP_32_SRLW_SRAW, rd, OPCODE_OP_32);
    endfunction

    function automatic logic [31:0] enc_beq(
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer imm
    );
        enc_beq = enc_b(imm, rs2, rs1, F3_BRANCH_BEQ);
    endfunction

    function automatic logic [31:0] enc_bne(
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer imm
    );
        enc_bne = enc_b(imm, rs2, rs1, F3_BRANCH_BNE);
    endfunction

    function automatic logic [31:0] enc_blt(
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer imm
    );
        enc_blt = enc_b(imm, rs2, rs1, F3_BRANCH_BLT);
    endfunction

    function automatic logic [31:0] enc_lui(
        input logic [4:0] rd,
        input logic [19:0] imm20
    );
        enc_lui = enc_u(imm20, rd, OPCODE_LUI);
    endfunction

    function automatic logic [31:0] enc_jal(
        input logic [4:0] rd,
        input integer imm
    );
        enc_jal = enc_j(imm, rd);
    endfunction

    function automatic logic [31:0] enc_jalr(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer imm
    );
        enc_jalr = enc_i(imm, rs1, F3_JALR, rd, OPCODE_JALR);
    endfunction

    function automatic logic [31:0] enc_csr(
        input logic [11:0] csr,
        input logic [4:0] source,
        input logic [2:0] funct3,
        input logic [4:0] rd
    );
        enc_csr = {csr, source, funct3, rd, OPCODE_SYSTEM};
    endfunction

    function automatic logic [31:0] enc_csrrw(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] rs1
    );
        enc_csrrw = enc_csr(csr, rs1, F3_SYSTEM_CSRRW, rd);
    endfunction

    function automatic logic [31:0] enc_csrrs(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] rs1
    );
        enc_csrrs = enc_csr(csr, rs1, F3_SYSTEM_CSRRS, rd);
    endfunction

    function automatic logic [31:0] enc_csrrc(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] rs1
    );
        enc_csrrc = enc_csr(csr, rs1, F3_SYSTEM_CSRRC, rd);
    endfunction

    function automatic logic [31:0] enc_csrrwi(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] zimm
    );
        enc_csrrwi = enc_csr(csr, zimm, F3_SYSTEM_CSRRWI, rd);
    endfunction

    function automatic logic [31:0] enc_csrrsi(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] zimm
    );
        enc_csrrsi = enc_csr(csr, zimm, F3_SYSTEM_CSRRSI, rd);
    endfunction

    function automatic logic [31:0] enc_csrrci(
        input logic [4:0] rd,
        input logic [11:0] csr,
        input logic [4:0] zimm
    );
        enc_csrrci = enc_csr(csr, zimm, F3_SYSTEM_CSRRCI, rd);
    endfunction

    function automatic logic [31:0] enc_ecall();
        enc_ecall = INST_ECALL;
    endfunction

    function automatic logic [31:0] enc_ebreak();
        enc_ebreak = INST_EBREAK;
    endfunction

    function automatic logic [31:0] enc_mret();
        enc_mret = INST_MRET;
    endfunction

    function automatic logic [31:0] nop();
        nop = enc_addi(5'd0, 5'd0, 0);
    endfunction
endpackage
