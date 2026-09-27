// Module: mem_mdu
// Description: Joins EX/MEM metadata with registered MDU results without another result register.
// 乘除法统一出口接收，在 MEM 内拼包，rsp握手
module mem_mdu (
    input  pipeline_pkg::ex_mem_t in_packet,
    input  logic                  issue_enable, // mem阶段允许推进(WB相关)才能交付结果
    input  logic                  rsp_valid,
    input  core_types_pkg::xlen_t rsp_data,
    output logic                  rsp_ready,
    output logic                  result_stall,
    output pipeline_pkg::ex_mem_t out_packet
);
    import core_types_pkg::*;
    logic selected;

    // 只为有效、无异常的 M 指令等待结果。WB 允许推进时才交付，年轻 EX 不能取消它。
    // rsp_ready：MEM 可向 WB 交付本条指令时才消费结果。
    always_comb begin
        selected = in_packet.valid && !in_packet.exc.valid && (in_packet.uop.fu == FU_MULDIV);
        result_stall = selected && !rsp_valid;
        rsp_ready = selected && issue_enable;
    end

    // 元数据与算法输出都已经寄存；在寄存器后拼包，避免再复制一拍结果。
    // 未完成的包仍保留在 ex_mem_q，仅关闭面向 LSU/WB 的有效位与前递。
    always_comb begin
        out_packet = in_packet;
        if (selected) begin
            out_packet.valid = rsp_valid;
            out_packet.result = rsp_data;
        end
    end
endmodule
