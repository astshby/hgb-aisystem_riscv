// Module: chooser
// Description: Read-first PC-indexed tournament choice trained only on candidate disagreement.
module chooser #(
    parameter int unsigned ENTRIES = 32
) (
    input logic clk, rst,
    input core_types_pkg::xlen_t lookup_pc,
    output logic choose_local,
    output logic [$clog2(ENTRIES)-1:0] lookup_idx,
    input logic update_valid,
    input logic [$clog2(ENTRIES)-1:0] update_idx,
    input logic update_local_taken,
    input logic update_global_taken,
    input logic update_taken,
    input core_types_pkg::xlen_t lookup_pc_1,
    output logic choose_local_1,
    output logic [$clog2(ENTRIES)-1:0] lookup_idx_1
);
    logic [1:0] counters_q [ENTRIES];
    logic train;
    logic [1:0] update_counter;

    // 候选与索引都来自同一次取指快照；意见一致时不训练 chooser。
    // 00/01 偏向 GShare，10/11 偏向 local，查询不旁路本拍训练。
    assign lookup_idx = lookup_pc[2 +: $clog2(ENTRIES)];
    assign choose_local = counters_q[lookup_idx][1];
    assign lookup_idx_1 = lookup_pc_1[2 +: $clog2(ENTRIES)];
    assign choose_local_1 = counters_q[lookup_idx_1][1];
    assign train = update_valid && (update_local_taken != update_global_taken);

    always_comb begin
        update_counter = counters_q[update_idx];
        if (update_local_taken == update_taken) begin
            if (update_counter != 2'b11) update_counter = update_counter + 2'b01;
        end else if (update_counter != 2'b00)
            update_counter = update_counter - 2'b01;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ENTRIES; i++) counters_q[i] <= 2'b01;
        end else if (train)
            counters_q[update_idx] <= update_counter;
    end

`ifndef SYNTHESIS
    initial begin
        assert (ENTRIES >= 2 && (ENTRIES & (ENTRIES-1)) == 0)
            else $fatal(1, "Chooser requires power-of-two ENTRIES >= 2");
    end
`endif
endmodule
