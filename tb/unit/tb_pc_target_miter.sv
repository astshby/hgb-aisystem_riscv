// Module: tb_pc_target_miter
// Description: Compares default and precomputed B/JAL targets with the frozen raw-immediate implementation.
module tb_pc_target_miter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    if_d1_t in_packet;
    d1_d2_t legacy_decode, default_decode, target_decode, expected_decode;
    redirect_t legacy_redirect, default_redirect, target_redirect;
    logic legacy_serialize, default_serialize, target_serialize;
    xlen_t operand_a, operand_b, csr_data;
    logic legacy_taken, target_taken;
    xlen_t legacy_target, target_target;
    retire_id_t alloc_id;
    gpr_dependency_t dependency;
    retire_alloc_t legacy_alloc, target_alloc;
    d2_ex_t legacy_execute, target_execute, expected_execute;
    retire_completion_t legacy_completion, target_completion;
    lsu_descriptor_t legacy_descriptor, target_descriptor;
    logic [31:0] random_state = 32'h59b724ce;
    int checks = 0, branches = 0, jals = 0, jalrs = 0, raw_checks = 0;
    int taken_branches = 0, untaken_branches = 0, misaligned = 0;

    d1_stage_reference reference_decode (.in_packet, .out_packet(legacy_decode),
        .redirect(legacy_redirect), .serialize_req(legacy_serialize));
    d1_stage default_dut (.in_packet, .out_packet(default_decode),
        .redirect(default_redirect), .serialize_req(default_serialize));
    d1_stage #(.PC_REL_TARGET_IN_IMM(1'b1)) target_dut (.in_packet, .out_packet(target_decode),
        .redirect(target_redirect), .serialize_req(target_serialize));
    branch_unit_reference reference_branch (.branch_op(legacy_decode.uop.branch_op),
        .pc(legacy_decode.pc), .seq_pc(legacy_decode.seq_pc), .operand_a, .operand_b,
        .imm(legacy_decode.imm), .taken(legacy_taken), .target(legacy_target));
    branch_unit #(.PC_REL_TARGET_IN_IMM(1'b1)) target_branch (.branch_op(target_decode.uop.branch_op),
        .pc(target_decode.pc), .seq_pc(target_decode.seq_pc), .operand_a, .operand_b,
        .imm(target_decode.imm), .taken(target_taken), .target(target_target));
    d2_stage reference_d2 (.in_packet(legacy_decode), .rs1_data(operand_a), .rs2_data(operand_b),
        .alloc_id, .rs1_dependency(dependency), .rs2_dependency(dependency),
        .alloc_meta(legacy_alloc), .out_packet(legacy_execute));
    d2_stage target_d2 (.in_packet(target_decode), .rs1_data(operand_a), .rs2_data(operand_b),
        .alloc_id, .rs1_dependency(dependency), .rs2_dependency(dependency),
        .alloc_meta(target_alloc), .out_packet(target_execute));
    scoreboard_execute reference_execute (.packet(legacy_execute), .branch_taken(legacy_taken),
        .branch_target(legacy_target), .csr_old_data(csr_data), .completion(legacy_completion),
        .descriptor(legacy_descriptor));
    scoreboard_execute target_execution (.packet(target_execute), .branch_taken(target_taken),
        .branch_target(target_target), .csr_old_data(csr_data), .completion(target_completion),
        .descriptor(target_descriptor));

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction
    function automatic xlen_t random_xlen;
        return xlen_t'({random_word(), random_word()});
    endfunction
    task automatic check;
        #1;
        assert (default_decode === legacy_decode && default_redirect === legacy_redirect &&
                default_serialize === legacy_serialize)
            else $fatal(1, "default D1 changed pc=%h inst=%h", in_packet.pc, in_packet.inst);
        expected_decode = legacy_decode;
        if (legacy_decode.uop.branch_op inside {BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU, BR_JAL})
            expected_decode.imm = legacy_decode.pc + legacy_decode.imm;
        else raw_checks++;
        assert (target_decode === expected_decode && target_redirect === legacy_redirect &&
                target_serialize === legacy_serialize)
            else $fatal(1, "target D1 changed other fields pc=%h inst=%h", in_packet.pc, in_packet.inst);
        assert (legacy_taken === target_taken && legacy_target === target_target)
            else $fatal(1, "branch result changed pc=%h inst=%h", in_packet.pc, in_packet.inst);
        expected_execute = legacy_execute;
        expected_execute.imm = expected_decode.imm;
        assert (target_execute === expected_execute && target_alloc === legacy_alloc)
            else $fatal(1, "D2 metadata changed");
        assert (target_completion === legacy_completion)
            else $fatal(1, "completion/link/exception changed pc=%h inst=%h", in_packet.pc, in_packet.inst);
        // B/JAL 的无效 LSU 描述符可以变化；真正的访存描述符必须逐位相同。
        if (legacy_decode.uop.mem_read || legacy_decode.uop.mem_write)
            assert (target_descriptor === legacy_descriptor) else $fatal(1, "memory descriptor changed");
        if (legacy_decode.uop.branch_op == BR_JAL) jals++;
        else if (legacy_decode.uop.branch_op == BR_JALR) jalrs++;
        else if (legacy_decode.uop.branch_op != BR_NONE) begin
            branches++;
            if (legacy_taken) taken_branches++;
            else untaken_branches++;
        end
        if (legacy_completion.result.exc.valid) misaligned++;
        checks++;
    endtask

    initial begin
        in_packet = '0;
        in_packet.valid = 1;
        operand_a = 0;
        operand_b = 0;
        csr_data = 0;
        alloc_id = '{slot:RETIRE_IDX_W'(3), generation:RETIRE_GEN_W'(2)};
        dependency = '0;
        // 全 B 位移和全部 funct3，含保留编码；PC 选择覆盖跨 XLEN 回绕。
        for (int pc_case = 0; pc_case < 4; pc_case++) begin
            unique case (pc_case)
                0: in_packet.pc = 0;
                1: in_packet.pc = xlen_t'(32'h80000000);
                2: in_packet.pc = ~xlen_t'(3);
                default: in_packet.pc = xlen_t'(1) << (XLEN-1);
            endcase
            in_packet.seq_pc = in_packet.pc + xlen_t'(4);
            for (int funct3 = 0; funct3 < 8; funct3++) begin
                for (int displacement = 0; displacement < 4096; displacement++) begin
                    in_packet.inst = enc_b(displacement * 2, 5'd2, 5'd1, 3'(funct3));
                    operand_a = xlen_t'($signed(displacement));
                    operand_b = displacement[0] ? operand_a : ~operand_a;
                    check();
                end
            end
        end
        // 全 J 位移复用 D1 原专用加法器；链接始终来自 seq_pc。
        in_packet.pc = ~xlen_t'(32'h7ffff);
        in_packet.seq_pc = in_packet.pc + xlen_t'(4);
        for (int displacement = 0; displacement < 1048576; displacement++) begin
            in_packet.inst = enc_j(displacement * 2, 5'(displacement));
            in_packet.pred.taken = displacement[0];
            in_packet.pred.target = displacement[1] ? in_packet.pc + xlen_t'(4) :
                in_packet.pc + xlen_t'(displacement * 2);
            check();
        end
        // JALR 原始 I 位移、bit0 清除、操作数依赖与异常门控独立检查。
        for (int displacement = 0; displacement < 4096; displacement++) begin
            in_packet.inst = enc_jalr(5'd1, 5'd2, displacement);
            operand_a = random_xlen();
            check();
        end
        // 随机全 opcode、异常/预测/无效载荷及 RV64 高地址。
        for (int sample = 0; sample < 65536; sample++) begin
            in_packet.inst = random_word();
            in_packet.pc = random_xlen();
            in_packet.seq_pc = random_xlen();
            in_packet.valid = sample[0];
            in_packet.exc = '{valid:sample[1], cause:EXC_INST_ACCESS_FAULT, tval:random_xlen()};
            in_packet.pred.taken = sample[2];
            in_packet.pred.target = random_xlen();
            operand_a = random_xlen();
            operand_b = random_xlen();
            csr_data = random_xlen();
            dependency.pending = sample[3];
            dependency.id = alloc_id;
            check();
        end
        assert (taken_branches > 10000 && untaken_branches > 10000 && jalrs >= 4096 && raw_checks > 60000)
            else $fatal(1, "target coverage incomplete");
        $display("PASS tb_pc_target_miter RV%0d checks=%0d B=%0d JAL=%0d JALR=%0d raw=%0d taken=%0d untaken=%0d exceptions=%0d packet_bits=%0d",
                 XLEN, checks, branches, jals, jalrs, raw_checks, taken_branches, untaken_branches,
                 misaligned, $bits(d2_ex_t));
        $finish;
    end
endmodule
