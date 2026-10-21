// Module: tb_ex_stage
// Description: Checks MDU and branch snapshots, forwarding, precise exceptions, and cancellation.
module tb_ex_stage;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic older_instruction_pending = 1'b0;
    logic csr_is_head;
    logic mdu_operands_ready = 1'b0;
    logic advance = 1'b0;
    logic cancel = 1'b0;
    logic mdu_req_valid, mdu_req_ready;
    muldiv_req_t mdu_request;
    logic mdu_rsp_ready = 1'b0;
    logic mdu_rsp_valid;
    xlen_t mdu_rsp_data;
    d2_ex_t in_packet;
    gpr_forward_t mem_gpr_forward;
    gpr_forward_t wb_gpr_forward;
    xlen_t rs1_value, rs2_value;
    xlen_t csr_committed_data;
    csr_forward_t mem_csr_forward;
    csr_forward_t wb_csr_forward;
    ex_mem_t out_packet;
    redirect_t redirect;
    logic serialize_req;
    logic execution_stall;

    always #5 clk = ~clk;
    ex_stage dut (.*);
    // 此 TB 注入已经解析的源，完整 ID/逐源保存由 tb_ex_operand_register 单独验证。
    assign csr_is_head = !older_instruction_pending;
    assign rs1_value = mem_gpr_forward.valid && mem_gpr_forward.addr == in_packet.rs1 ?
        mem_gpr_forward.data : wb_gpr_forward.valid && wb_gpr_forward.addr == in_packet.rs1 ?
        wb_gpr_forward.data : in_packet.rs1_data;
    assign rs2_value = mem_gpr_forward.valid && mem_gpr_forward.addr == in_packet.rs2 ?
        mem_gpr_forward.data : wb_gpr_forward.valid && wb_gpr_forward.addr == in_packet.rs2 ?
        wb_gpr_forward.data : in_packet.rs2_data;

    // MDU 独立于 EX；本 TB 保留原算术接口，带 ID 的取消/完成另由 adapter TB 覆盖。
    muldiv_unit u_muldiv_unit (
        .clk, .rst, .cancel,
        .req_valid(mdu_req_valid), .req_ready(mdu_req_ready), .request(mdu_request),
        .result_available(),
        .rsp_valid(mdu_rsp_valid), .rsp_ready(mdu_rsp_ready), .rsp_data(mdu_rsp_data)
    );

    initial begin
        in_packet = '0;
        mem_gpr_forward = '0;
        wb_gpr_forward = '0;
        csr_committed_data = '0;
        mem_csr_forward = '0;
        wb_csr_forward = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        in_packet.valid = 1'b1;
        in_packet.pc = xlen_t'(8);
        in_packet.rd = gpr_addr_t'(7);
        in_packet.rs1 = gpr_addr_t'(1);
        in_packet.rs2 = gpr_addr_t'(2);
        in_packet.rs1_data = xlen_t'(3);
        in_packet.rs2_data = xlen_t'(3);
        in_packet.uop.fu = FU_MULDIV;
        in_packet.uop.muldiv_op = MD_MUL;
        in_packet.uop.rs1_used = 1'b1;
        in_packet.uop.rs2_used = 1'b1;
        in_packet.uop.gpr_write = 1'b1;
        in_packet.uop.wb_sel = WB_ALU;
        mem_gpr_forward = '{valid:1'b1, addr:gpr_addr_t'(1), data:xlen_t'(7)};
        wb_gpr_forward = '{valid:1'b1, addr:gpr_addr_t'(1), data:xlen_t'(5)};
        repeat (3) begin
            @(negedge clk);
            assert (execution_stall && !out_packet.valid && dut.u_ex_mdu.req_ready)
                else $fatal(1, "EX started MDU despite older pipeline wait");
        end
        mdu_operands_ready = 1'b1;
        #1;
        assert (!out_packet.valid && !execution_stall && !mdu_rsp_valid && mdu_req_valid)
            else $fatal(1, "MDU must leave EX without a duplicate MEM packet");
        @(posedge clk);
        @(negedge clk);
        mem_gpr_forward.data = xlen_t'(99);
        wb_gpr_forward.data = xlen_t'(98);
        for (int cycles = 0; !mdu_rsp_valid; cycles++) begin
            assert (cycles < XLEN + 4) else $fatal(1, "EX MDU timeout");
            assert (!dut.u_ex_mdu.req_valid) else $fatal(1, "EX did not withdraw accepted M request");
            @(negedge clk);
        end
        repeat (3) begin
            assert (!execution_stall && !out_packet.valid && mdu_rsp_data == xlen_t'(21) &&
                    !dut.u_ex_mdu.req_valid &&
                    out_packet.pc == xlen_t'(8) && out_packet.rd == gpr_addr_t'(7) &&
                    !redirect.valid && !dut.branch_valid && !serialize_req)
                else $fatal(1, "EX operand snapshot or held result");
            @(negedge clk);
        end
        advance = 1'b1;
        @(posedge clk);
        @(negedge clk);
        advance = 1'b0;
        in_packet.valid = 1'b0;
        mem_gpr_forward.valid = 1'b0;
        wb_gpr_forward.valid = 1'b0;
        #1;
        assert (!execution_stall && !out_packet.valid) else $fatal(1, "EX repeated completed M instruction");

        // EX 离开并不消费结果；独立接收端尚未允许交付时仍保持运算输出。
        repeat (3) begin
            assert (mdu_rsp_valid && mdu_rsp_data == xlen_t'(21))
                else $fatal(1, "result lost after EX metadata advanced");
            @(negedge clk);
        end
        mdu_rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        mdu_rsp_ready = 1'b0;
        #1;
        assert (!mdu_rsp_valid) else $fatal(1, "native MDU response repeated after acceptance");

        @(negedge clk);
        in_packet.valid = 1'b1;
        in_packet.uop.muldiv_op = MD_DIV;
        @(posedge clk);
        repeat (3) @(negedge clk);
        cancel = 1'b1;
        in_packet.valid = 1'b0;
        @(posedge clk);
        @(negedge clk);
        cancel = 1'b0;
        repeat (XLEN + 4) begin
            @(negedge clk);
            assert (!mdu_rsp_valid && !out_packet.valid)
                else $fatal(1, "cancelled EX division returned late");
        end

        // 请求已交给 MDU 后也允许取消，不能因 EX 空闲而留下晚到的响应。
        // 此处是原生算术接口；Core 的带 ID completion 不通过 cancel 组合门控。
        @(negedge clk);
        in_packet.valid = 1'b1;
        advance = 1'b1;
        @(posedge clk);
        @(negedge clk);
        in_packet.valid = 1'b0;
        advance = 1'b0;
        repeat (3) @(negedge clk);
        cancel = 1'b1;
        #1;
        assert (!mdu_rsp_valid) else $fatal(1, "cancel must suppress native MDU response immediately");
        @(posedge clk);
        @(negedge clk);
        cancel = 1'b0;
        repeat (XLEN + 4) begin
            @(negedge clk);
            assert (!mdu_rsp_valid) else $fatal(1, "cancelled independent MDU response returned late");
        end

        // 已知异常的 M 包只携带异常向后流动，不启动无意义运算。
        in_packet.valid = 1'b1;
        in_packet.exc = '{valid:1'b1, cause:EXC_ILLEGAL_INST, tval:xlen_t'(32'hffff_ffff)};
        #1;
        assert (!execution_stall && !dut.u_ex_mdu.req_valid && out_packet.valid &&
                out_packet.exc.valid && !serialize_req)
            else $fatal(1, "exception-bearing M instruction issued arithmetic");
        @(negedge clk);
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.uop.fu = FU_ALU;
        in_packet.uop.op_a_sel = OP_A_RS1;
        in_packet.uop.op_b_sel = OP_B_RS2;
        in_packet.rs1_data = xlen_t'(4);
        in_packet.rs2_data = xlen_t'(5);
        #1;
        assert (out_packet.valid && !execution_stall && out_packet.result == xlen_t'(9))
            else $fatal(1, "ordinary ALU path changed");
        // 所有 CSR 都等自身队头，已有异常不能误进入此等待。
        @(negedge clk);
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.uop.csr_valid = 1'b1;
        in_packet.csr_addr = CSR_MINSTRET;
        older_instruction_pending = 1'b1;
        #1;
        assert (execution_stall && !out_packet.valid) else $fatal(1, "MINSTRET did not wait");
        older_instruction_pending = 1'b0;
        #1;
        assert (!execution_stall && out_packet.valid) else $fatal(1, "MINSTRET wait stuck");
        older_instruction_pending = 1'b1;
        in_packet.csr_addr = CSR_MSCRATCH;
        #1;
        assert (execution_stall) else $fatal(1, "ordinary CSR bypassed its head permission");
        in_packet.csr_addr = CSR_MINSTRET;
        in_packet.exc.valid = 1'b1;
        #1;
        assert (!execution_stall) else $fatal(1, "exception incorrectly waited for counter");
        older_instruction_pending = 1'b0;

        // 合法 load 的异常地址使用前递 rs1 + 立即数，和 ALU 的访存结果一致。
        in_packet = '0;
        in_packet.valid = 1'b1;
        in_packet.rs1 = gpr_addr_t'(1);
        in_packet.rs1_data = xlen_t'(4);
        in_packet.imm = xlen_t'(2);
        in_packet.uop.fu = FU_LSU;
        in_packet.uop.rs1_used = 1'b1;
        in_packet.uop.mem_read = 1'b1;
        in_packet.uop.mem_size = MEM_WORD;
        in_packet.uop.alu_op = ALU_ADD;
        in_packet.uop.op_a_sel = OP_A_RS1;
        in_packet.uop.op_b_sel = OP_B_IMM;
        in_packet.uop.op_width = OP_WIDTH_XLEN;
        mem_gpr_forward = '{valid:1'b1, addr:gpr_addr_t'(1), data:xlen_t'(9)};
        mdu_operands_ready = 1'b0;
        #1;
        assert (execution_stall && !out_packet.exc.valid && !serialize_req)
            else $fatal(1, "unavailable LSU operand caused premature exception");
        mdu_operands_ready = 1'b1;
        #1;
        assert (out_packet.result == xlen_t'(11) && out_packet.exc.valid &&
                out_packet.exc.cause == EXC_LOAD_ADDR_MISALIGNED &&
                out_packet.exc.tval == xlen_t'(11))
            else $fatal(1, "forwarded load address or alignment exception changed");
        mem_gpr_forward.data = xlen_t'(6);
        #1;
        assert (out_packet.result == xlen_t'(8) && !out_packet.exc.valid)
            else $fatal(1, "aligned forwarded load was rejected");

        // 分支沿前必须等待，且只有前递操作数就绪后才保存；MEM 同名值优先于 WB。
        @(negedge clk);
        in_packet = '0;
        in_packet.valid = 1;
        in_packet.pc = xlen_t'(32'h80);
        in_packet.seq_pc = xlen_t'(32'h84);
        in_packet.imm = xlen_t'(16);
        in_packet.rs1 = gpr_addr_t'(1);
        in_packet.rs2 = gpr_addr_t'(2);
        in_packet.rs1_data = xlen_t'(2);
        in_packet.rs2_data = xlen_t'(7);
        in_packet.uop.rs1_used = 1;
        in_packet.uop.rs2_used = 1;
        in_packet.uop.branch_op = BR_EQ;
        mem_gpr_forward = '{valid:1'b1, addr:gpr_addr_t'(1), data:xlen_t'(7)};
        wb_gpr_forward = '{valid:1'b1, addr:gpr_addr_t'(1), data:xlen_t'(1)};
        mdu_operands_ready = 0;
        repeat (3) begin
            #1;
            assert (execution_stall && !out_packet.valid && !redirect.valid &&
                    !dut.branch_valid && !serialize_req)
                else $fatal(1, "branch captured unavailable GPR or leaked stale control");
            @(negedge clk);
        end
        mdu_operands_ready = 1;
        #1;
        assert (execution_stall && !redirect.valid) else $fatal(1, "branch bypassed result register");
        @(negedge clk);
        repeat (3) begin
            #1;
            assert (!execution_stall && out_packet.valid && !out_packet.exc.valid &&
                    redirect.valid && redirect.pc == xlen_t'(32'h90) &&
                    out_packet.next_pc == xlen_t'(32'h90) && dut.branch_valid &&
                    out_packet.branch.taken && out_packet.branch.target == xlen_t'(32'h90))
                else $fatal(1, "registered branch gained delay or lost captured forwarding");
            mem_gpr_forward.data = xlen_t'(3);
            wb_gpr_forward.data = xlen_t'(4);
            @(negedge clk);
        end
        advance = 1;
        @(negedge clk);
        advance = 0;
        // 上一条 taken/target 仍留在保存槽；普通 ALU 必须退休到自己的顺序 PC。
        in_packet.pc = xlen_t'(32'ha0);
        in_packet.seq_pc = xlen_t'(32'ha4);
        in_packet.uop.branch_op = BR_NONE;
        in_packet.uop.fu = FU_ALU;
        in_packet.uop.op_a_sel = OP_A_RS1;
        in_packet.uop.op_b_sel = OP_B_IMM;
        in_packet.uop.alu_op = ALU_ADD;
        in_packet.uop.rs2_used = 0;
        in_packet.imm = xlen_t'(4);
        #1;
        assert (out_packet.valid && !execution_stall && !out_packet.exc.valid &&
                out_packet.result == xlen_t'(7) && out_packet.next_pc == xlen_t'(32'ha4) &&
                !redirect.valid && !dut.branch_valid && !serialize_req)
            else $fatal(1, "ordinary instruction consumed stale taken branch payload");
        advance = 1;
        @(negedge clk);
        advance = 0;
        in_packet.uop.branch_op = BR_EQ;
        in_packet.uop.rs2_used = 1;
        in_packet.pc = xlen_t'(32'h100);
        in_packet.seq_pc = xlen_t'(32'h104);
        in_packet.imm = xlen_t'(8);
        in_packet.pred.taken = 1;
        in_packet.pred.target = xlen_t'(32'h108);
        #1;
        assert (execution_stall && !redirect.valid) else $fatal(1, "next branch reused prior result");
        @(negedge clk);
        #1;
        assert (!execution_stall && out_packet.valid && !out_packet.exc.valid && dut.branch_valid &&
                redirect.valid && redirect.pc == xlen_t'(32'h104) &&
                !out_packet.branch.taken && out_packet.branch.target == xlen_t'(32'h108) &&
                out_packet.next_pc == xlen_t'(32'h104))
            else $fatal(1, "not-taken correction used old branch result");

        // taken 不能用 next_pc != seq_pc 推导：分支目标可以恰好落在顺序后继。
        advance = 1;
        @(negedge clk);
        advance = 0;
        in_packet.imm = xlen_t'(4);
        in_packet.pred.taken = 0;
        mem_gpr_forward.data = xlen_t'(7);
        #1;
        assert (execution_stall && !out_packet.valid && !dut.branch_valid && !redirect.valid)
            else $fatal(1, "same-successor branch reused the previous snapshot");
        @(negedge clk);
        #1;
        assert (out_packet.valid && !out_packet.exc.valid && !execution_stall && dut.branch_valid &&
                out_packet.branch.taken && out_packet.branch.target == in_packet.seq_pc &&
                out_packet.next_pc == in_packet.seq_pc && redirect.valid && redirect.pc == in_packet.seq_pc)
            else $fatal(1, "taken branch to sequential PC lost its actual direction");

        // JALR 清 bit 0 后仍可能不满足 IALIGN=32；异常只在本条结果已保存后序列化。
        advance = 1;
        @(negedge clk);
        advance = 0;
        in_packet.uop.branch_op = BR_JALR;
        in_packet.uop.rs2_used = 0;
        in_packet.imm = '0;
        mem_gpr_forward.data = xlen_t'(32'h203);
        #1;
        assert (execution_stall && !serialize_req && !redirect.valid)
            else $fatal(1, "JALR checked stale snapshot before capture");
        @(negedge clk);
        #1;
        assert (!execution_stall && out_packet.valid && out_packet.exc.valid &&
                out_packet.exc.cause == EXC_INST_ADDR_MISALIGNED &&
                out_packet.exc.tval == xlen_t'(32'h202) && serialize_req &&
                !redirect.valid && !dut.branch_valid)
            else $fatal(1, "registered JALR lost precise target exception");
        cancel = 1;
        in_packet.valid = 0;
        @(negedge clk);
        cancel = 0;
        in_packet.valid = 1;
        in_packet.exc = '{valid:1'b1, cause:EXC_ILLEGAL_INST, tval:xlen_t'(1)};
        #1;
        assert (out_packet.valid && out_packet.exc.valid && !execution_stall &&
                !dut.branch_valid && !serialize_req && !redirect.valid)
            else $fatal(1, "known exception incorrectly waited for branch snapshot");
        in_packet.exc = '0;
        in_packet.uop.branch_op = BR_JAL;
        in_packet.imm = xlen_t'(16);
        #1;
        assert (out_packet.valid && !out_packet.exc.valid && !execution_stall && !redirect.valid &&
                out_packet.next_pc == in_packet.pc + xlen_t'(16) &&
                out_packet.branch.taken && out_packet.branch.target == in_packet.pc + xlen_t'(16))
            else $fatal(1, "D1-resolved JAL gained an EX wait");
        // 同样检查带旧未对齐目标的槽不会让普通 CSR 获得控制流异常。
        in_packet.uop.branch_op = BR_NONE;
        in_packet.uop.csr_valid = 1;
        in_packet.csr_addr = CSR_MSCRATCH;
        #1;
        assert (out_packet.valid && !out_packet.exc.valid && !execution_stall &&
                out_packet.next_pc == in_packet.seq_pc && !redirect.valid &&
                !dut.branch_valid && !serialize_req)
            else $fatal(1, "CSR consumed stale misaligned branch payload");
        $display("PASS tb_ex_stage RV%0d", XLEN);
        $finish;
    end
endmodule
