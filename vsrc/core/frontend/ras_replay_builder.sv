// Module: ras_replay_builder
// Description: Selects surviving return-stack events from the unique retirement queue and pre-ID frontend.
module ras_replay_builder (
    input pipeline_pkg::retire_ras_entry_t entries [core_config_pkg::RETIRE_ENTRIES],
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic normal_retire,
    input pipeline_pkg::retire_id_t retiring_id,
    input logic flush_all,
    input logic ex_exception_valid,
    input pipeline_pkg::retire_id_t ex_exception_id,
    input logic dispatch_fire,
    input pipeline_pkg::retire_alloc_t alloc_meta,
    input logic d1_advance,
    input pipeline_pkg::d1_d2_t d1_packet,
    output logic [core_config_pkg::RETIRE_ENTRIES+1:0] replay_valid,
    output predictor_types_pkg::ras_event_t replay [core_config_pkg::RETIRE_ENTRIES+2],
    input logic normal_retire_1,
    input pipeline_pkg::retire_id_t retiring_id_1
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    import predictor_types_pkg::*;
    ras_op_e d1_op;
    ras_decode u_d1_decode (.inst(d1_packet.inst), .op(d1_op));

    // 槽号只用于读视图；年龄从真实 head 旋转，代次完整匹配本拍退休与异常项。
    // 包括已完成未退休的事件，不复制队列 valid/done，不将物理槽号当年龄。
    for (genvar age = 0; age < RETIRE_ENTRIES; age++) begin : g_age
        logic [RETIRE_IDX_W-1:0] slot;
        assign slot = head_slot + RETIRE_IDX_W'(age);
        always_comb begin
            replay[age] = entries[slot].event_info;
            replay_valid[age] = !flush_all && entries[slot].valid && !entries[slot].exception &&
                entries[slot].event_info.op != RAS_NONE &&
                !(normal_retire && entries[slot].id == retiring_id) &&
                !(normal_retire_1 && entries[slot].id == retiring_id_1) &&
                !(ex_exception_valid && entries[slot].id == ex_exception_id);
        end
    end

    // 当前 D2 尚未进入队列视图，同拍接纳后仍存活；D1 也尚无 ID，但确实推进才重放。
    // EX/WB 事件会使这两个 fire/advance 关闭；D1 冷 JAL 不得丢掉前面的 D2 call。
    always_comb begin
        replay[RETIRE_ENTRIES] = '{op:alloc_meta.ras_op, addr:alloc_meta.seq_pc};
        replay_valid[RETIRE_ENTRIES] = !flush_all && dispatch_fire && alloc_meta.ras_op != RAS_NONE;
        replay[RETIRE_ENTRIES+1] = '{op:d1_op, addr:d1_packet.seq_pc};
        replay_valid[RETIRE_ENTRIES+1] = !flush_all && d1_advance && d1_packet.valid &&
            !d1_packet.exc.valid && d1_op != RAS_NONE;
    end
endmodule
