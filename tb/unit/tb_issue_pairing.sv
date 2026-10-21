// Module: tb_issue_pairing
// Description: Checks pairing eligibility with an independent semantic and register-set model.
module tb_issue_pairing;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    d1_d2_t first_packet, second_packet;
    logic second_waw_block, second_operands_ready, pair_eligible;
    int checks = 0, allowed = 0, rejected = 0, war_allowed = 0;
    int raw_cases = 0, waw_cases = 0, ready_cases = 0, external_waw_cases = 0;
    int high_pc_cases = 0;
    int unsigned random_state = 32'h91c5_74b3, initial_seed;

    issue_pairing dut (.*);

    function automatic int unsigned random_word();
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    // 用寄存器集合相交描述跨组依赖，不复用 DUT 的逐字段比较表达式。
    function automatic logic [31:0] writes(input d1_d2_t value);
        logic [31:0] mask;
        mask = 0;
        if (value.uop.gpr_write && value.rd != 0) mask[int'(value.rd)] = 1;
        return mask;
    endfunction
    function automatic logic [31:0] reads(input d1_d2_t value);
        logic [31:0] mask;
        mask = 0;
        if (value.uop.rs1_used && value.rs1 != 0) mask[int'(value.rs1)] = 1;
        if (value.uop.rs2_used && value.rs2 != 0) mask[int'(value.rs2)] = 1;
        return mask;
    endfunction
    function automatic bit reference_pair();
        if (!first_packet.valid || !second_packet.valid) return 0;
        if (first_packet.exc.valid || second_packet.exc.valid) return 0;
        if (second_packet.pc != first_packet.seq_pc) return 0;
        if (second_waw_block || !second_operands_ready) return 0;
        unique case (first_packet.uop.fu)
            FU_ALU, FU_LSU, FU_MULDIV: ;
            default: return 0;
        endcase
        if (first_packet.uop.branch_op != BR_NONE || first_packet.uop.csr_valid ||
            first_packet.uop.sys_op != SYS_NONE) return 0;
        if (second_packet.uop.fu != FU_ALU || second_packet.uop.branch_op != BR_NONE ||
            second_packet.uop.csr_valid || second_packet.uop.mem_read || second_packet.uop.mem_write ||
            second_packet.uop.sys_op != SYS_NONE) return 0;
        if ((writes(first_packet) & reads(second_packet)) != 0) return 0;
        if ((writes(first_packet) & writes(second_packet)) != 0) return 0;
        return 1;
    endfunction

    function automatic d1_d2_t instruction(input int kind, input xlen_t pc);
        d1_d2_t value;
        value = '0;
        value.valid = 1; value.pc = pc; value.seq_pc = pc + xlen_t'(4);
        value.inst = 32'h0000_0013;
        value.rd = 9; value.rs1 = 2; value.rs2 = 3;
        value.uop.fu = FU_ALU; value.uop.gpr_write = 1;
        value.uop.rs1_used = 1; value.uop.rs2_used = 1;
        unique case (kind)
            0: ;
            1: begin value.uop.fu = FU_LSU; value.uop.mem_read = 1; value.uop.rs2_used = 0; end
            2: begin value.uop.fu = FU_LSU; value.uop.mem_write = 1; value.uop.gpr_write = 0; end
            3: value.uop.fu = FU_MULDIV;
            4: begin value.uop.fu = FU_BRANCH; value.uop.branch_op = BR_EQ; value.uop.gpr_write = 0; end
            5: begin value.uop.fu = FU_CSR; value.uop.csr_valid = 1; value.uop.csr_write = 1; end
            6: begin value.uop.fu = FU_NONE; value.uop.sys_op = SYS_FENCE; value.uop.gpr_write = 0; end
            7: begin value.uop.illegal = 1; value.exc.valid = 1; value.exc.cause = EXC_ILLEGAL_INST; end
            default: value.uop.fu = FU_NONE;
        endcase
        return value;
    endfunction

    task automatic base(input int first_kind = 0, input int second_kind = 0);
        first_packet = instruction(first_kind, xlen_t'(64'h1234_5678_8000_0100));
        second_packet = instruction(second_kind, first_packet.seq_pc);
        first_packet.rd = 7;
        second_waw_block = 0; second_operands_ready = 1;
    endtask

    task automatic check(input string label_text, input int required = -1);
        bit expected;
        expected = reference_pair();
        #1;
        assert (pair_eligible == expected && (required < 0 || int'(pair_eligible) == required))
            else $fatal(1, "%s: pair actual=%b expected=%b required=%0d", label_text, pair_eligible, expected, required);
        checks++;
        if (expected) begin
            allowed++;
            if ((reads(first_packet) & writes(second_packet)) != 0) war_allowed++;
        end else rejected++;
        if ((writes(first_packet) & reads(second_packet)) != 0) raw_cases++;
        if ((writes(first_packet) & writes(second_packet)) != 0) waw_cases++;
        if (!second_operands_ready) ready_cases++;
        if (second_waw_block) external_waw_cases++;
    endtask

    initial begin
        int regs [4];
        if ($value$plusargs("SEED=%d", random_state)) begin end
        assert (random_state != 0) else $fatal(1, "SEED must be nonzero");
        initial_seed = random_state;
        regs[0] = 0; regs[1] = 1; regs[2] = 5; regs[3] = 31;
        for (int first_kind = 0; first_kind < 9; first_kind++) begin
            for (int second_kind = 0; second_kind < 9; second_kind++) begin
                base(first_kind, second_kind);
                check("semantic kind cross product", first_kind < 4 && second_kind == 0 ? 1 : 0);
            end
        end

        // 每个独立资格单独破坏，防止另一个更早的禁止条件掩盖漏检。
        base(); first_packet.valid = 0; check("first invalid", 0);
        base(); second_packet.valid = 0; check("second invalid", 0);
        base(); first_packet.exc.valid = 1; check("first exception", 0);
        base(); second_packet.exc.valid = 1; check("second exception", 0);
        base(); second_packet.pc += xlen_t'(4); check("PC gap", 0);
        if (XLEN == 64) begin
            base(); second_packet.pc ^= xlen_t'(64'h0000_0100_0000_0000);
            check("same low address different RV64 high address", 0); high_pc_cases++;
        end
        base(); first_packet.uop.branch_op = BR_JAL; check("first control", 0);
        base(); second_packet.uop.branch_op = BR_JALR; check("second control", 0);
        base(); first_packet.uop.csr_valid = 1; check("first CSR qualification", 0);
        base(); second_packet.uop.csr_valid = 1; check("second CSR qualification", 0);
        base(); first_packet.uop.sys_op = SYS_MRET; check("first system", 0);
        base(); second_packet.uop.sys_op = SYS_FENCE_I; check("second system", 0);
        base(); second_packet.uop.mem_read = 1; check("second read side effect", 0);
        base(); second_packet.uop.mem_write = 1; check("second write side effect", 0);
        base(); second_waw_block = 1; check("external WAW", 0);
        base(); second_operands_ready = 0; check("second RAW readiness", 0);
        base(); second_packet.rs1 = first_packet.rd; check("cross-group rs1 RAW", 0);
        base(); second_packet.rs2 = first_packet.rd; check("cross-group rs2 RAW", 0);
        base(); second_packet.rd = first_packet.rd; check("cross-group WAW", 0);
        base(); first_packet.rs1 = second_packet.rd; check("WAR allowed", 1);
        base(); second_packet.rs1 = first_packet.rd; second_packet.uop.rs1_used = 0;
        check("unused source does not create RAW", 1);
        base(); first_packet.rd = 0; second_packet.rd = 0; second_packet.rs1 = 0;
        check("x0 is neither RAW nor WAW writer", 1);
        base(); first_packet.uop.gpr_write = 0; second_packet.rd = first_packet.rd;
        second_packet.rs1 = first_packet.rd; check("nonwriter encoding is not a dependency", 1);

        // 源/目的关系穷举：含 x0、链接寄存器和最高地址，used/write 位独立变化。
        for (int a = 0; a < 4; a++)
            for (int b = 0; b < 4; b++)
                for (int c = 0; c < 4; c++)
                    for (int d = 0; d < 4; d++)
                        for (int qualifiers = 0; qualifiers < 16; qualifiers++) begin
                            base();
                            first_packet.rd = gpr_addr_t'(regs[a]);
                            second_packet.rd = gpr_addr_t'(regs[b]);
                            second_packet.rs1 = gpr_addr_t'(regs[c]);
                            second_packet.rs2 = gpr_addr_t'(regs[d]);
                            first_packet.rs1 = second_packet.rd;
                            first_packet.uop.gpr_write = qualifiers[0];
                            second_packet.uop.gpr_write = qualifiers[1];
                            second_packet.uop.rs1_used = qualifiers[2];
                            second_packet.uop.rs2_used = qualifiers[3];
                            check("register relation cross product");
                        end

        // 随机按合法类别生成包，再变化有效性/显式异常/准备资格与寄存器关系。
        // 不把 illegal 无异常、csr_write 无 csr_valid 等未约定畸形 uOp 当作规范要求。
        for (int trial = 0; trial < 10000; trial++) begin
            base(int'(random_word() % 9), int'(random_word() % 9));
            first_packet.valid = random_word() % 8 != 0;
            second_packet.valid = random_word() % 8 != 0;
            if (random_word() % 16 == 0) first_packet.exc.valid = 1;
            if (random_word() % 16 == 0) second_packet.exc.valid = 1;
            if (random_word() % 8 == 0) second_packet.pc ^= xlen_t'(16);
            first_packet.rd = gpr_addr_t'(random_word());
            second_packet.rd = gpr_addr_t'(random_word());
            first_packet.rs1 = gpr_addr_t'(random_word());
            first_packet.rs2 = gpr_addr_t'(random_word());
            second_packet.rs1 = gpr_addr_t'(random_word());
            second_packet.rs2 = gpr_addr_t'(random_word());
            first_packet.uop.rs1_used = 1'(random_word());
            first_packet.uop.rs2_used = 1'(random_word());
            second_packet.uop.rs1_used = 1'(random_word());
            second_packet.uop.rs2_used = 1'(random_word());
            second_waw_block = random_word() % 8 == 0;
            second_operands_ready = random_word() % 4 != 0;
            check("random pairing");
        end
        assert (allowed > 0 && rejected > 0 && war_allowed > 0 && raw_cases > 0 && waw_cases > 0 &&
                ready_cases > 0 && external_waw_cases > 0 && (XLEN != 64 || high_pc_cases == 1))
            else $fatal(1, "pairing coverage missing");
        $display("PASS tb_issue_pairing RV%0d seed=%0d checks=%0d allowed=%0d rejected=%0d WAR=%0d RAW=%0d WAW=%0d ready_block=%0d external_WAW=%0d high_PC=%0d",
            XLEN, initial_seed, checks, allowed, rejected, war_allowed, raw_cases, waw_cases,
            ready_cases, external_waw_cases, high_pc_cases);
        $finish;
    end
endmodule
