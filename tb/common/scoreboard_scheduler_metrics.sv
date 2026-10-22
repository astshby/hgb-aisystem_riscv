// Module: scoreboard_scheduler_metrics
// Description: Passive whole-run integer-IQ occupancy, tagged RAW and MDU-resource observations.
module scoreboard_scheduler_metrics #(
    parameter int unsigned DEPTH = core_config_pkg::ISSUE_QUEUE_ENTRIES,
    parameter bit EMIT_STATS = 1
) (
    input logic clk, rst, flush, mdu_available,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic [DEPTH-1:0] valid_slots, eligible,
    input pipeline_pkg::d2_ex_t packets [DEPTH], selected [2],
    input pipeline_pkg::retire_gpr_entry_t producers [core_config_pkg::RETIRE_ENTRIES],
    input logic [1:0] accept_count
);
    timeunit 1ns;
    timeprecision 1ps;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    longint unsigned cycles, occupied_cycles, ready_cycles, full_cycles;
    longint unsigned raw_cycles, raw_alu_cycles, raw_mdu_cycles, raw_load_cycles;
    longint unsigned mdu_resource_cycles, mdu_iq_idle_cycles, accepted_cycles, accepted_operations;
    longint unsigned bypass_raw_cycles, bypass_mdu_cycles;
    logic raw_wait, alu_wait, mdu_raw_wait, load_wait, mdu_wait, bypass_raw, bypass_mdu;
    logic [DEPTH-1:0] raw_slots, mdu_slots;
    localparam string STATS_FORMAT = {
        "SCHEDULER_STATS {\"window\":\"whole_run\",\"cycles\":%0d,",
        "\"occupied_cycles\":%0d,\"ready_cycles\":%0d,\"full_cycles\":%0d,",
        "\"raw_cycles\":%0d,\"raw_alu_cycles\":%0d,\"raw_mdu_cycles\":%0d,\"raw_load_cycles\":%0d,",
        "\"mdu_resource_cycles\":%0d,\"mdu_iq_idle_cycles\":%0d,",
        "\"accepted_cycles\":%0d,\"accepted_operations\":%0d,",
        "\"bypass_raw_cycles\":%0d,\"bypass_mdu_cycles\":%0d}"
    };
    function automatic logic pending_kind(input gpr_dependency_t dependency, input retire_kind_e kind);
        retire_gpr_entry_t producer;
        producer = producers[dependency.id.slot];
        return dependency.pending && producer.valid && producer.id == dependency.id && producer.kind == kind;
    endfunction

    // 这些是可重叠的队列状态周期，不与互斥 no_issue 分类相加；清空/恢复不计为等待。
    always_comb begin
        raw_slots = 0; mdu_slots = 0;
        raw_wait = 0; alu_wait = 0; mdu_raw_wait = 0; load_wait = 0; mdu_wait = 0;
        for (int slot = 0; slot < DEPTH; slot++) begin
            if (valid_slots[slot] && !flush && !recovery.valid) begin
                raw_slots[slot] = packets[slot].rs1_dependency.pending || packets[slot].rs2_dependency.pending;
                mdu_slots[slot] = schedule_class(packets[slot]) == SCHED_MDU && !raw_slots[slot] && !mdu_available;
                raw_wait |= raw_slots[slot];
                mdu_wait |= mdu_slots[slot];
                alu_wait |= pending_kind(packets[slot].rs1_dependency, RET_EXEC) || pending_kind(packets[slot].rs2_dependency, RET_EXEC);
                mdu_raw_wait |= pending_kind(packets[slot].rs1_dependency, RET_MDU) || pending_kind(packets[slot].rs2_dependency, RET_MDU);
                load_wait |= pending_kind(packets[slot].rs1_dependency, RET_LOAD) || pending_kind(packets[slot].rs2_dependency, RET_LOAD);
            end
        end
    end
    always_comb begin
        bypass_raw = 0; bypass_mdu = 0;
        for (int lane = 0; lane < 2; lane++) begin
            for (int slot = 0; slot < DEPTH; slot++) begin
                if (lane < int'(accept_count) && younger_than(selected[lane].retire_id, packets[slot].retire_id, head_slot)) begin
                    bypass_raw |= raw_slots[slot];
                    bypass_mdu |= mdu_slots[slot];
                end
            end
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0; occupied_cycles <= 0; ready_cycles <= 0; full_cycles <= 0;
            raw_cycles <= 0; raw_alu_cycles <= 0; raw_mdu_cycles <= 0; raw_load_cycles <= 0;
            mdu_resource_cycles <= 0; mdu_iq_idle_cycles <= 0;
            accepted_cycles <= 0; accepted_operations <= 0; bypass_raw_cycles <= 0; bypass_mdu_cycles <= 0;
        end else begin
            cycles <= cycles + 1;
            if (|valid_slots) occupied_cycles <= occupied_cycles + 1;
            if (|eligible) ready_cycles <= ready_cycles + 1;
            if (&valid_slots) full_cycles <= full_cycles + 1;
            if (raw_wait) raw_cycles <= raw_cycles + 1;
            if (alu_wait) raw_alu_cycles <= raw_alu_cycles + 1;
            if (mdu_raw_wait) raw_mdu_cycles <= raw_mdu_cycles + 1;
            if (load_wait) raw_load_cycles <= raw_load_cycles + 1;
            if (mdu_wait) mdu_resource_cycles <= mdu_resource_cycles + 1;
            // 仅指整数 IQ 无候选，访存 bank 同拍仍可能发射，不能直接当作 Core 空转。
            if (mdu_wait && !(|eligible)) mdu_iq_idle_cycles <= mdu_iq_idle_cycles + 1;
            if (accept_count != 0) accepted_cycles <= accepted_cycles + 1;
            accepted_operations <= accepted_operations + 64'(accept_count);
            if (bypass_raw) bypass_raw_cycles <= bypass_raw_cycles + 1;
            if (bypass_mdu) bypass_mdu_cycles <= bypass_mdu_cycles + 1;
        end
    end
    final begin
        if (EMIT_STATS) $display("%s", $sformatf(STATS_FORMAT,
            cycles, occupied_cycles, ready_cycles, full_cycles, raw_cycles, raw_alu_cycles, raw_mdu_cycles,
            raw_load_cycles, mdu_resource_cycles, mdu_iq_idle_cycles, accepted_cycles, accepted_operations,
            bypass_raw_cycles, bypass_mdu_cycles));
    end
endmodule
