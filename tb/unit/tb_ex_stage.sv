// Module: tb_ex_stage
// Description: Checks MDU issue snapshots, early metadata, MEM response holding, and cancellation.
module tb_ex_stage;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic mdu_operands_ready = 1'b0;
    logic advance = 1'b0;
    logic cancel = 1'b0;
    logic mdu_rsp_ready = 1'b0;
    logic mdu_rsp_valid;
    xlen_t mdu_rsp_data;
    d2_ex_t in_packet;
    gpr_forward_t mem_gpr_forward;
    gpr_forward_t wb_gpr_forward;
    xlen_t csr_committed_data;
    csr_forward_t mem_csr_forward;
    csr_forward_t wb_csr_forward;
    ex_mem_t out_packet;
    redirect_t redirect;
    pred_update_t pred_update;
    logic serialize_req;
    logic execution_stall;

    always #5 clk = ~clk;
    ex_stage dut (.*);

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
        assert (out_packet.valid && !execution_stall && !mdu_rsp_valid)
            else $fatal(1, "metadata must be eligible on the request edge, before registered result");
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
            assert (!execution_stall && out_packet.valid && mdu_rsp_data == xlen_t'(21) &&
                    !dut.u_ex_mdu.req_valid &&
                    out_packet.pc == xlen_t'(8) && out_packet.rd == gpr_addr_t'(7) &&
                    !redirect.valid && !pred_update.valid && !serialize_req)
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

        // EX 元数据离开并不消费结果；MEM 尚未允许交付时仍保持运算输出。
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
        assert (!mdu_rsp_valid) else $fatal(1, "MEM response repeated after acceptance");

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
            assert (!dut.u_ex_mdu.rsp_valid && !out_packet.valid)
                else $fatal(1, "cancelled EX division returned late");
        end

        // 元数据已交给 MEM 后也允许取消，不能因 EX 空闲而留下晚到的响应。
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
        assert (!mdu_rsp_valid) else $fatal(1, "cancel must suppress MEM-bound response immediately");
        @(posedge clk);
        @(negedge clk);
        cancel = 1'b0;
        repeat (XLEN + 4) begin
            @(negedge clk);
            assert (!mdu_rsp_valid) else $fatal(1, "cancelled MEM M response returned late");
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
        $display("PASS tb_ex_stage RV%0d", XLEN);
        $finish;
    end
endmodule
