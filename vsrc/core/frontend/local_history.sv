// Module: local_history
// Description: PC-indexed local histories and a shared read-first two-bit pattern table.
module local_history #(
    parameter int unsigned LHT_ENTRIES = 64,
    parameter int unsigned HISTORY_W = 8
) (
    input logic clk, rst,
    input core_types_pkg::xlen_t lookup_pc,
    output logic lookup_taken,
    output logic [HISTORY_W-1:0] lookup_idx,
    input logic update_valid,
    input core_types_pkg::xlen_t update_pc,
    input logic [HISTORY_W-1:0] update_idx,
    input logic update_taken,
    input core_types_pkg::xlen_t lookup_pc_1,
    output logic lookup_taken_1,
    output logic [HISTORY_W-1:0] lookup_idx_1
);
    localparam int unsigned LHT_IDX_W = $clog2(LHT_ENTRIES);
    localparam int unsigned PHT_ENTRIES = 1 << HISTORY_W;
    logic [HISTORY_W-1:0] history_q [LHT_ENTRIES];
    logic [1:0] counters_q [PHT_ENTRIES];
    logic [LHT_IDX_W-1:0] update_history_idx;
    logic [1:0] update_counter;

    // Local 的 LHT→PHT 仍有内部串联；与 GShare 并行查询不消除这一依赖。
    // 同拍训练沿后才可见，不将 update_valid/data 旁路到当前取指预测。
    assign lookup_idx = history_q[lookup_pc[2 +: LHT_IDX_W]];
    assign lookup_taken = counters_q[lookup_idx][1];
    assign lookup_idx_1 = history_q[lookup_pc_1[2 +: LHT_IDX_W]];
    assign lookup_taken_1 = counters_q[lookup_idx_1][1];
    assign update_history_idx = update_pc[2 +: LHT_IDX_W];

    always_comb begin
        update_counter = counters_q[update_idx];
        if (update_taken && update_counter != 2'b11)
            update_counter = update_counter + 2'b01;
        else if (!update_taken && update_counter != 2'b00)
            update_counter = update_counter - 2'b01;
    end

    // PHT 按查询时保存的索引训练；LHT 在当前历史后追加真实结果。
    // 使用旧查询历史重建 LHT 会丢掉同一 PC 中间已经退休的分支结果。
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < LHT_ENTRIES; i++) history_q[i] <= '0;
            for (int i = 0; i < PHT_ENTRIES; i++) counters_q[i] <= 2'b01;
        end else if (update_valid) begin
            history_q[update_history_idx] <=
                (history_q[update_history_idx] << 1) | HISTORY_W'(update_taken);
            counters_q[update_idx] <= update_counter;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (LHT_ENTRIES >= 2 && (LHT_ENTRIES & (LHT_ENTRIES-1)) == 0 &&
                HISTORY_W >= 1 && HISTORY_W <= 16)
            else $fatal(1, "Local predictor requires power-of-two LHT >= 2 and history width 1..16");
    end
`endif
endmodule
