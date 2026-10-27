// Module: lsu_age_checker
// Description: Checks stored LSQ age against independent modular distances for live entries.
module lsu_age_checker #(
    parameter int ENTRIES = core_config_pkg::LOAD_QUEUE_ENTRIES + core_config_pkg::STORE_QUEUE_ENTRIES
) (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic [ENTRIES-1:0] valid_slots, killed_slots,
    input pipeline_pkg::lsu_descriptor_t entries [ENTRIES],
    input logic [ENTRIES-1:0] age_order [ENTRIES]
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    // 用截断后的环形距离作参考，不复用 RTL 的回卷比较函数或分配更新逻辑。
    for (genvar a = 0; a < ENTRIES; a++) begin : g_candidate
        for (genvar b = 0; b < ENTRIES; b++) begin : g_prior
            logic [RETIRE_IDX_W-1:0] distance_a, distance_b;
            assign distance_a = entries[a].id.slot - head_slot;
            assign distance_b = entries[b].id.slot - head_slot;
            always_ff @(posedge clk) begin
                if (!rst && !flush && !recovery.valid && valid_slots[a] && !killed_slots[a] &&
                    valid_slots[b] && !killed_slots[b]) begin
                    assert (age_order[a][b] == ((distance_a > distance_b) ||
                            (distance_a == distance_b && b < a)))
                        else $fatal(1, "LSQ age mismatch a=%0d b=%0d head=%0d distances=%0d/%0d", a,b,head_slot,distance_a,distance_b);
                end
            end
        end
    end
endmodule

bind load_store_queue lsu_age_checker u_age_reference (
    .clk, .rst, .flush, .recovery, .head_slot,
    .valid_slots(valid_q), .killed_slots(killed_q), .entries(entry_q), .age_order(older)
);
