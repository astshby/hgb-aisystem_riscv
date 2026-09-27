// Module: tb_mem_mdu
// Description: Checks registered MDU result joining, forwarding availability, and response backpressure.
module tb_mem_mdu;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    ex_mem_t in_packet, out_packet;
    logic issue_enable, rsp_valid, rsp_ready, result_stall;
    xlen_t rsp_data;
    mem_mdu dut (.*);

    initial begin
        in_packet = '0;
        issue_enable = 1'b1;
        rsp_valid = 1'b0;
        rsp_data = xlen_t'(21);
        in_packet.valid = 1'b1;
        in_packet.uop.fu = FU_ALU;
        in_packet.result = xlen_t'(9);
        #1;
        assert (out_packet == in_packet && !result_stall && !rsp_ready)
            else $fatal(1, "non-M packet changed");

        // 元数据仍在 MEM，但算法未完成时不能输出假结果或让年轻指令前进。
        in_packet.uop.fu = FU_MULDIV;
        in_packet.pc = xlen_t'(16);
        in_packet.rd = gpr_addr_t'(7);
        #1;
        assert (result_stall && !out_packet.valid && rsp_ready)
            else $fatal(1, "missing M result must stall");

        // WB 反压不隐藏已经完成的值，只延迟响应消费。
        issue_enable = 1'b0;
        rsp_valid = 1'b1;
        #1;
        assert (!result_stall && out_packet.valid && !rsp_ready &&
                out_packet.result == xlen_t'(21) && out_packet.pc == xlen_t'(16) &&
                out_packet.rd == gpr_addr_t'(7))
            else $fatal(1, "completed M result hidden under WB backpressure");
        issue_enable = 1'b1;
        #1;
        assert (rsp_ready && out_packet.valid) else $fatal(1, "MEM cannot accept completed M");

        // 异常 M 包不曾启动算法，不应等待或消费任何算术结果。
        in_packet.exc.valid = 1'b1;
        rsp_valid = 1'b0;
        #1;
        assert (out_packet == in_packet && !result_stall && !rsp_ready)
            else $fatal(1, "exception packet waits for nonexistent M request");
        in_packet.valid = 1'b0;
        in_packet.exc.valid = 1'b0;
        rsp_valid = 1'b1;
        #1;
        assert (!out_packet.valid && !rsp_ready && !result_stall)
            else $fatal(1, "empty MEM consumed M response");
        $display("PASS tb_mem_mdu RV%0d", XLEN);
        $finish;
    end
endmodule
