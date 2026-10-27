// Module: tb_d1_stage
// Description: Compares D1 packets and early JAL control with the original full-decode reference.
module tb_d1_stage;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;
    logic clk = 0;
    if_d1_t in_packet;
    d1_d2_t out_packet, reference_packet;
    redirect_t redirect, reference_redirect;
    logic serialize_req, reference_serialize;
    uop_t reference_uop;
    gpr_addr_t reference_rs1, reference_rs2, reference_rd;
    csr_addr_t reference_csr;
    xlen_t reference_imm, reference_target;
    exception_t reference_exception;
    int checks = 0, redirects = 0, faults = 0;
    logic [31:0] random_state = 32'h4b16a903;
    always #5 clk = ~clk;
    d1_stage dut (.*);
    // 保留原来的完整译码→立即数→异常→重定向顺序作为独立结构参考。
    decoder reference_decoder (.inst(in_packet.inst), .uop(reference_uop),
        .rs1(reference_rs1), .rs2(reference_rs2), .rd(reference_rd), .csr_addr(reference_csr));
    imm_gen reference_immediate (.inst(in_packet.inst), .imm(reference_imm));
    assign reference_target = in_packet.pc + reference_imm;
    d1_exception_check reference_check (.in_packet, .uop(reference_uop),
        .jal_target(reference_target), .exception(reference_exception));
    always_comb begin
        reference_packet = '{valid:in_packet.valid, pc:in_packet.pc, seq_pc:in_packet.seq_pc,
            inst:in_packet.inst, rs1:reference_rs1, rs2:reference_rs2, rd:reference_rd,
            csr_addr:reference_csr, imm:reference_imm, uop:reference_uop,
            pred:in_packet.pred, exc:reference_exception};
        reference_serialize = in_packet.valid && (reference_exception.valid ||
            reference_uop.sys_op == SYS_MRET || reference_uop.sys_op == SYS_FENCE ||
            reference_uop.sys_op == SYS_FENCE_I);
        reference_redirect = '0;
        if (in_packet.valid && !reference_exception.valid && reference_uop.branch_op == BR_JAL &&
            (!in_packet.pred.taken || in_packet.pred.target != reference_target))
            reference_redirect = '{valid:1, pc:reference_target, reason:REDIR_D1_JAL};
    end
    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction
    task automatic check;
        #1;
        assert (out_packet == reference_packet && redirect == reference_redirect &&
                serialize_req == reference_serialize)
            else $fatal(1, "D1 mismatch pc=%h inst=%h actual_redirect=%h expected=%h",
                        in_packet.pc, in_packet.inst, redirect, reference_redirect);
        checks++;
        if (redirect.valid) redirects++;
        if (out_packet.valid && out_packet.exc.valid) faults++;
    endtask
    task automatic set_prediction(input int mode);
        #1;
        in_packet.pred.taken = mode != 0;
        in_packet.pred.target = mode == 1 ? reference_target : reference_target ^ xlen_t'(4);
    endtask
    initial begin
        in_packet = '0;
        // 穷举全部 20 位 JAL 位移编码，交替使用普通 PC 和跨 XLEN 边界的 PC。
        for (int offset = 0; offset < (1 << 20); offset++) begin
            @(negedge clk);
            in_packet = '0;
            in_packet.valid = 1;
            in_packet.pc = offset[2] ? ~xlen_t'(4095) : xlen_t'(4096);
            in_packet.seq_pc = in_packet.pc + 4;
            in_packet.inst = enc_jal(5'(offset), offset << 1);
            set_prediction((offset >> 1) & 3);
            check();
        end
        // PC 对齐、取指异常、valid、预测组合分别覆盖，不把取指错误数据当成合法 JAL。
        for (int scenario = 0; scenario < 256; scenario++) begin
            @(negedge clk);
            in_packet = '0;
            in_packet.valid = scenario[0];
            in_packet.pc = xlen_t'(32'hffff_fffc | ((scenario >> 1) & 3));
            in_packet.seq_pc = in_packet.pc + 4;
            in_packet.inst = enc_jal(5'(scenario), scenario[6] ? -2 : 8);
            in_packet.exc = '{valid:scenario[3], cause:EXC_INST_ACCESS_FAULT, tval:in_packet.pc};
            set_prediction((scenario >> 4) & 3);
            check();
        end
        // 所有 opcode 的随机其余字段，包括 JALR、SYSTEM、非法指令及取指异常。
        for (int sample_no = 0; sample_no < 32768; sample_no++) begin
            @(negedge clk);
            in_packet = '0;
            in_packet.valid = sample_no[3:0] != 0;
            in_packet.pc = xlen_t'(random_word()) & ~xlen_t'(3);
            in_packet.seq_pc = in_packet.pc + 4;
            in_packet.inst = (random_word() & 32'hffff_ff80) | 32'(sample_no & 127);
            in_packet.exc.valid = sample_no[4:0] == 0;
            in_packet.exc.cause = EXC_INST_ACCESS_FAULT;
            in_packet.exc.tval = in_packet.pc;
            set_prediction(sample_no & 3);
            check();
        end
        assert (redirects > 100000 && faults > 100000) else $fatal(1, "D1 coverage incomplete");
        $display("PASS tb_d1_stage RV%0d checks=%0d jal_offsets=1048576 corners=256 random=32768 redirects=%0d faults=%0d",
                 XLEN, checks, redirects, faults);
        $finish;
    end
endmodule
