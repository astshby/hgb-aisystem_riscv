// Module: wb_stage
// Description: Formats ordinary WB packets and early exceptions into tagged retirement completions.
// 外部访存与响应槽由 lsu_transaction 唯一持有；普通 WB 的反压由原 MEM/WB 包保持。
module wb_stage (
    input  pipeline_pkg::mem_wb_t       in_packet,
    output pipeline_pkg::retire_completion_t completion,
    output logic                        completion_valid
);
    import core_types_pkg::*;

    // 继承早期异常；总线 access fault 只从 LSU 完成口交付。
    // 完成源来自已寄存 WB 包，不能用其自身产生的 Trap flush 组合撤销 valid。
    always_comb begin
        completion_valid = in_packet.valid;
        completion = '0;
        completion.id = in_packet.retire_id;
        completion.result.next_pc = in_packet.next_pc;
        completion.result.branch = in_packet.branch;
        completion.result.csr_write = in_packet.csr_we;
        completion.result.csr_data = in_packet.csr_new;
        completion.result.exc = in_packet.exc;
        unique case (in_packet.uop.wb_sel)
            WB_LOAD:   completion.result.gpr_data = '0; // 仅早期异常 Load 可到达此口。
            WB_SEQ_PC: completion.result.gpr_data = in_packet.seq_pc;
            WB_CSR:    completion.result.gpr_data = in_packet.csr_old;
            default:   completion.result.gpr_data = in_packet.result;
        endcase
    end
    // 普通包完成资格由本级持有；架构写口与 trace 只接退休队头。
    // 当前 WB 优先且队列常态 ready，直通不增加周期；未来仲裁反压须 HOLD 原 MEM/WB。
endmodule
