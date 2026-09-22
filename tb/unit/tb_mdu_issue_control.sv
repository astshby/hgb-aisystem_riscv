// Module: tb_mdu_issue_control
// Description: Checks dependency-aware MDU admission around an unresolved WB load.
module tb_mdu_issue_control;
    timeunit 1ns;
    timeprecision 1ps;

    import core_types_pkg::*;
    import pipeline_pkg::*;

    d2_ex_t ex_packet;
    mem_wb_t wb_packet;
    logic wb_wait;
    logic mdu_operands_ready;

    mdu_issue_control dut (.*);

    initial begin
        ex_packet = '0;
        wb_packet = '0;
        wb_wait = 1'b0;
        ex_packet.valid = 1'b1;
        ex_packet.uop.fu = FU_MULDIV;
        ex_packet.uop.rs1_used = 1'b1;
        ex_packet.uop.rs2_used = 1'b1;
        ex_packet.rs1 = gpr_addr_t'(5);
        ex_packet.rs2 = gpr_addr_t'(7);
        wb_packet.valid = 1'b1;
        wb_packet.uop.mem_read = 1'b1;
        wb_packet.uop.gpr_write = 1'b1;
        wb_packet.rd = gpr_addr_t'(5);
        #1;
        assert (mdu_operands_ready) else $fatal(1, "idle WB must not block MDU");

        wb_wait = 1'b1;
        #1;
        assert (!mdu_operands_ready) else $fatal(1, "dependent rs1 must wait for load response");

        wb_packet.rd = gpr_addr_t'(7);
        #1;
        assert (!mdu_operands_ready) else $fatal(1, "dependent rs2 must wait for load response");

        wb_packet.rd = gpr_addr_t'(9);
        #1;
        assert (mdu_operands_ready) else $fatal(1, "independent MDU must overlap WB wait");

        ex_packet.uop.rs2_used = 1'b0;
        wb_packet.rd = gpr_addr_t'(7);
        #1;
        assert (mdu_operands_ready) else $fatal(1, "unused source must not create dependency");

        ex_packet.uop.rs2_used = 1'b1;
        ex_packet.rs1 = '0;
        ex_packet.rs2 = '0;
        wb_packet.rd = '0;
        #1;
        assert (mdu_operands_ready) else $fatal(1, "x0 must not create a dependency");

        $display("PASS tb_mdu_issue_control");
        $finish;
    end
endmodule
