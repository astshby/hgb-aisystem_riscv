// Module: interrupt_entry
// Description: Drains the in-order pipeline and records the architectural interrupt resume PC.
module interrupt_entry (
    input logic clk, rst,
    input logic irq_pending,
    input logic pipeline_busy,
    input logic retire_valid,
    input pipeline_pkg::mem_wb_t commit_packet,
    input pipeline_pkg::redirect_t wb_redirect,
    output logic interrupt_take,
    output core_types_pkg::xlen_t interrupt_pc
);
    import core_types_pkg::*;
    xlen_t resume_pc_q;
    // Core 在 irq_pending 期间停止新取指，保留已接受的 IF 响应；访存/MDU 必须先完成。
    // 若中断撤销则继续顺序执行；只有真正进入 Trap 的重定向才杀死尚未入流水的取指。
    assign interrupt_take = irq_pending && !pipeline_busy;
    assign interrupt_pc = resume_pc_q;

    // 保存已退休指令的实际后继，而非预测 PC 或固定 pc+4；Trap/MRET 覆盖正常后继。
    always_ff @(posedge clk) begin
        if (rst)
            resume_pc_q <= core_config_pkg::RESET_VECTOR;
        else if (wb_redirect.valid)
            resume_pc_q <= wb_redirect.pc;
        else if (retire_valid)
            resume_pc_q <= commit_packet.next_pc;
    end
endmodule
