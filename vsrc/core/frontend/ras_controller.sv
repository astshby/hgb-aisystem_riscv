// Module: ras_controller
// Description: Couples accepted-fetch speculation and normal-retirement RAS state through age-ordered recovery.
module ras_controller (
    input logic clk, rst, clear,
    input logic fetch_fire,
    input core_types_pkg::xlen_t fetch_pc,
    input predictor_types_pkg::ras_op_e predicted_op,
    input logic normal_retire,
    input pipeline_pkg::retire_alloc_t head_meta,
    input pipeline_pkg::retire_id_t head_id,
    input pipeline_pkg::retire_ras_entry_t entries [core_config_pkg::RETIRE_ENTRIES],
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic recover, flush_all,
    input logic ex_exception_valid,
    input pipeline_pkg::retire_id_t ex_exception_id,
    input logic dispatch_fire,
    input pipeline_pkg::retire_alloc_t alloc_meta,
    input logic d1_advance,
    input pipeline_pkg::d1_d2_t d1_packet,
    output logic top_valid,
    output core_types_pkg::xlen_t top_addr,
    input logic fetch_second,
    input pipeline_pkg::pred_info_t prediction_1,
    input logic normal_retire_1,
    input pipeline_pkg::retire_id_t head_id_1
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import predictor_types_pkg::*;
    ras_event_t fetch_event, fetch_event_1, commit_event;
    ras_event_t replay [RETIRE_ENTRIES+2];
    logic [RETIRE_ENTRIES+1:0] replay_valid;

    // 取指反压期间不反复推栈；仅正常退休更新 committed，普通重定向不清已提交调用链。
    assign fetch_event = '{op:predicted_op, addr:fetch_pc + xlen_t'(4)};
    assign commit_event = '{op:head_meta.ras_op, addr:head_meta.seq_pc};
    assign fetch_event_1 = '{op:prediction_1.ras_op, addr:fetch_pc + xlen_t'(8)};
    ras_replay_builder u_replay_builder (
        .entries, .head_slot, .normal_retire, .retiring_id(head_id), .flush_all,
        .ex_exception_valid, .ex_exception_id, .dispatch_fire, .alloc_meta,
        .d1_advance, .d1_packet, .replay_valid, .replay,
        .normal_retire_1, .retiring_id_1(head_id_1)
    );
    ras #(.DEPTH(RAS_DEPTH), .REPLAY_SLOTS(RETIRE_ENTRIES+2)) u_ras (
        .clk, .rst, .clear, .fetch_fire, .fetch_event, .fetch_second, .fetch_event_1,
        .commit_valid(normal_retire), .commit_event, .recover, .replay_valid, .replay,
        .commit_valid_1(1'b0), .commit_event_1('0),
        .top_valid, .top_addr
    );
endmodule
