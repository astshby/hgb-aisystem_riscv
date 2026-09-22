// Module: mdu_issue_control
// Description: Allows an EX MDU request unless it depends on an older unresolved WB load.
// MDU 只阻止依赖未返回 load 的请求，允许无依赖提前开始运算。
module mdu_issue_control (
    input  pipeline_pkg::d2_ex_t  ex_packet,
    input  pipeline_pkg::mem_wb_t wb_packet,
    input  logic                  wb_wait,
    output logic                  mdu_operands_ready
);
    // 需要等待情况：wb堵塞且写回寄存器不为x0（是0的话无所谓可提交），且ex指令使用了wb的写回寄存器。
    always_comb begin
        mdu_operands_ready =
            !(wb_wait && (wb_packet.rd != '0) &&
              ((ex_packet.uop.rs1_used && (ex_packet.rs1 == wb_packet.rd)) ||
               (ex_packet.uop.rs2_used && (ex_packet.rs2 == wb_packet.rd))));
    end
endmodule
