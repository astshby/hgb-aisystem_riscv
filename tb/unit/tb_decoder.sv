// Module: tb_decoder
// Description: Checks RV32I/RV64I/M decode and illegal encodings.
module tb_decoder;
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    import riscv_unpriv_pkg::*;

    logic [31:0] inst;
    uop_t uop;
    gpr_addr_t rs1;
    gpr_addr_t rs2;
    gpr_addr_t rd;
    csr_addr_t csr_addr;

    decoder dut (.*);

    initial begin
        inst = enc_add(5'd1, 5'd2, 5'd3); #1;
        assert (!uop.illegal && uop.alu_op == ALU_ADD && uop.rs2_used && uop.gpr_write)
            else $fatal(1, "ADD decode");
        inst = enc_lw(5'd1, 5'd2, 4); #1;
        assert (!uop.illegal && uop.mem_read && uop.mem_size == MEM_WORD)
            else $fatal(1, "LW decode");
        inst = enc_blt(5'd1, 5'd2, 8); #1;
        assert (!uop.illegal && uop.branch_op == BR_LT) else $fatal(1, "BLT decode");
        inst = 32'hffff_ffff; #1;
        assert (uop.illegal && !uop.gpr_write && !uop.mem_write) else $fatal(1, "illegal decode");

        // 同一编码在 RV64 合法、在 RV32 必须保持非法。
        inst = enc_ld(5'd1, 5'd2, 8); #1;
        if (XLEN == 64)
            assert (!uop.illegal && uop.mem_read && uop.mem_size == MEM_DWORD)
                else $fatal(1, "LD decode");
        else
            assert (uop.illegal) else $fatal(1, "LD must be illegal in RV32");

        inst = enc_lwu(5'd1, 5'd2, 4); #1;
        if (XLEN == 64)
            assert (!uop.illegal && uop.mem_size == MEM_WORD && uop.load_unsigned)
                else $fatal(1, "LWU decode");
        else
            assert (uop.illegal) else $fatal(1, "LWU must be illegal in RV32");

        inst = enc_addw(5'd1, 5'd2, 5'd3); #1;
        if (XLEN == 64)
            assert (!uop.illegal && uop.op_width == OP_WIDTH_WORD && uop.alu_op == ALU_ADD)
                else $fatal(1, "ADDW decode");
        else
            assert (uop.illegal) else $fatal(1, "ADDW must be illegal in RV32");
        inst = enc_ecall(); #1;
        assert (!uop.illegal && uop.sys_op == SYS_ECALL) else $fatal(1, "ECALL decode");
        inst = enc_ebreak(); #1;
        assert (!uop.illegal && uop.sys_op == SYS_EBREAK) else $fatal(1, "EBREAK decode");
        inst = enc_mret(); #1;
        assert (!uop.illegal && uop.sys_op == SYS_MRET) else $fatal(1, "MRET decode");
        inst = enc_csrrw(5'd1, CSR_MSCRATCH, 5'd2); #1;
        assert (!uop.illegal && uop.csr_valid && uop.csr_write &&
                uop.csr_cmd == CSR_RW && uop.rs1_used && csr_addr == CSR_MSCRATCH)
            else $fatal(1, "CSRRW decode");
        inst = enc_csrrs(5'd1, CSR_MSCRATCH, 5'd0); #1;
        assert (!uop.illegal && uop.csr_valid && !uop.csr_write && !uop.rs1_used)
            else $fatal(1, "CSRRS read-only form");
        inst = enc_csrrci(5'd1, CSR_MSCRATCH, 5'd3); #1;
        assert (!uop.illegal && uop.csr_valid && uop.csr_imm &&
                uop.csr_write && uop.csr_cmd == CSR_RC)
            else $fatal(1, "CSRRCI decode");
        inst = 32'h0020_0073; #1;
        assert (uop.illegal && !uop.csr_valid && !uop.gpr_write)
            else $fatal(1, "reserved SYSTEM decode");

        // RV64 XLEN 位移允许 shamt[5]，W 类位移仍只允许 5-bit shamt。
        inst = enc_slli(5'd1, 5'd2, 32); #1;
        if (XLEN == 64)
            assert (!uop.illegal && uop.alu_op == ALU_SLL) else $fatal(1, "RV64 SLLI shamt[5]");
        else
            assert (uop.illegal) else $fatal(1, "RV32 SLLI shamt[5] must be illegal");
        inst = enc_slliw(5'd1, 5'd2, 32); #1;
        assert (uop.illegal) else $fatal(1, "SLLIW shamt[5] must be illegal");

        // 八种 XLEN M 运算全部合法，且确实读取两个 GPR、写回执行结果。
        for (int operation = 0; operation < 8; operation++) begin
            inst = enc_r(F7_OP_MULDIV, 5'd3, 5'd2, 3'(operation), 5'd1, OPCODE_OP);
            #1;
            assert (!uop.illegal && uop.fu == FU_MULDIV &&
                    uop.muldiv_op == muldiv_op_e'(operation) &&
                    uop.op_width == OP_WIDTH_XLEN && uop.rs1_used && uop.rs2_used &&
                    uop.gpr_write && uop.wb_sel == WB_ALU &&
                    !uop.mem_read && !uop.mem_write && !uop.csr_valid)
                else $fatal(1, "M decode operation=%0d", operation);

            inst = enc_r(F7_OP_MULDIV, 5'd3, 5'd2, 3'(operation), 5'd1, OPCODE_OP_32);
            #1;
            if ((XLEN == 64) && ((operation == 0) || (operation >= 4)))
                assert (!uop.illegal && uop.fu == FU_MULDIV &&
                        uop.muldiv_op == muldiv_op_e'(operation) &&
                        uop.op_width == OP_WIDTH_WORD)
                    else $fatal(1, "M W decode operation=%0d", operation);
            else
                assert (uop.illegal) else $fatal(1, "reserved/RV32 M W encoding accepted");
        end
        inst = enc_r(7'b0000010, 5'd3, 5'd2, F3_OP_MUL, 5'd1, OPCODE_OP); #1;
        assert (uop.illegal) else $fatal(1, "reserved M funct7 accepted");

        $display("PASS tb_decoder");
        $finish;
    end
endmodule
