// Module: ex_operand_register
// Description: Owns one D2/EX packet and independently captures tagged operands without an extra execute stage.
module ex_operand_register (
    input logic clk, rst,
    input pipeline_pkg::pipe_action_e action,
    input pipeline_pkg::d2_ex_t in_packet,
    input pipeline_pkg::retire_gpr_forward_t queue_rs1, queue_rs2,
    input pipeline_pkg::retire_gpr_forward_t wb_forward, lsu_forward, mdu_forward, mem_forward,
    output pipeline_pkg::d2_ex_t out_packet,
    output core_types_pkg::xlen_t rs1_value, rs2_value,
    output logic operands_ready,
    input pipeline_pkg::retire_gpr_forward_t aux_forward
);
    import core_types_pkg::*;
    import pipeline_pkg::*;

    // 这就是 D2/EX 边界本身；rs*_data 同时保存初始 RF 值和后来捕获值，不另复制数据寄存器。
    d2_ex_t packet_q;
    logic rs1_ready, rs2_ready;
    retire_gpr_forward_t resolved_rs1, resolved_rs2;

    // 完整 ID 匹配才可使用前递；同 ID 多副本应当同值，已接纳的 queue 值优先。
    // 前递 valid 只表示已寄存值可用，不依赖完成 ready、退休许可或自产 flush。
    function automatic retire_gpr_forward_t resolve_source(
        input logic used,
        input gpr_addr_t addr,
        input xlen_t saved_data,
        input gpr_dependency_t dependency,
        input retire_gpr_forward_t queue_value
    );
        retire_gpr_forward_t resolved;
        resolved = '0;
        if (!used || addr == '0)
            resolved.valid = 1'b1;
        else if (!dependency.pending)
            resolved = '{valid:1'b1, id:'0, data:saved_data};
        else if (queue_value.valid && queue_value.id == dependency.id)
            resolved = queue_value;
        else if (wb_forward.valid && wb_forward.id == dependency.id)
            resolved = wb_forward;
        else if (lsu_forward.valid && lsu_forward.id == dependency.id)
            resolved = lsu_forward;
        else if (mdu_forward.valid && mdu_forward.id == dependency.id)
            resolved = mdu_forward;
        else if (aux_forward.valid && aux_forward.id == dependency.id)
            resolved = aux_forward;
        else if (mem_forward.valid && mem_forward.id == dependency.id)
            resolved = mem_forward;
        return resolved;
    endfunction

    always_comb begin
        resolved_rs1 = resolve_source(packet_q.uop.rs1_used, packet_q.rs1,
                                      packet_q.rs1_data, packet_q.rs1_dependency, queue_rs1);
        resolved_rs2 = resolve_source(packet_q.uop.rs2_used, packet_q.rs2,
                                      packet_q.rs2_data, packet_q.rs2_dependency, queue_rs2);
        rs1_ready = resolved_rs1.valid;
        rs2_ready = resolved_rs2.valid;
        rs1_value = resolved_rs1.data;
        rs2_value = resolved_rs2.data;
        operands_ready = !packet_q.valid || (rs1_ready && rs2_ready);
        out_packet = packet_q;
    end

    // 本拍可用值直接给 EX，无需先捕获一拍；停留时每个源独立保存，另一个源可继续等待。
    // CLEAR/新包替换优先于旧包捕获；控制者必须在 flush 时给 CLEAR，不能只撤销前递 valid。
    always_ff @(posedge clk) begin
        if (rst || action == PIPE_CLEAR)
            packet_q.valid <= 1'b0;
        else if (action == PIPE_ADVANCE)
            packet_q <= in_packet;
        else if (packet_q.valid) begin
            if (packet_q.rs1_dependency.pending && rs1_ready) begin
                packet_q.rs1_data <= rs1_value;
                packet_q.rs1_dependency.pending <= 1'b0;
            end
            if (packet_q.rs2_dependency.pending && rs2_ready) begin
                packet_q.rs2_data <= rs2_value;
                packet_q.rs2_dependency.pending <= 1'b0;
            end
        end
    end
endmodule
