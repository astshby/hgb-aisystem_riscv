// Module: gshare
// Description: Non-speculative global-history predictor trained by saved PHT index.
// 查询使用 PC 异或已提交历史；更新使用取指时保存的 PHT 索引。
module gshare (
    input  logic                              clk,
    input  logic                              rst,
    input  core_types_pkg::xlen_t             lookup_pc,
    output logic                              lookup_taken,
    output logic [core_config_pkg::PHT_IDX_W-1:0] lookup_idx,
    input  logic                              update_valid,
    input  logic [core_config_pkg::PHT_IDX_W-1:0] update_idx,
    input  logic                              update_taken
);
    import core_config_pkg::*;

    // 2-bit pht预测,pht必须包含valid，pht,ghr是历史记录(由于是2-bit，所以无法直接得出taken)
    logic [1:0] pht_q [0:PHT_ENTRIES-1];
    logic pht_valid_q [0:PHT_ENTRIES-1];
    logic [GHR_W-1:0] ghr_q;
    logic [1:0] lookup_counter; // 本次查询的计数器值
    logic [1:0] update_counter; // 本次更新的计数器值
    integer entry;

    // 2-bit计数器更新函数,不需要状态机
    function automatic logic [1:0] next_counter(
        input logic [1:0] current,
        input logic taken
    );
        if (taken)
            next_counter = (current == 2'b11) ? current : current + 2'b01;
        else
            next_counter = (current == 2'b00) ? current : current - 2'b01;
    endfunction

    // 更新值计算:从弱不跳转状态开始训练。
    always_comb begin
        update_counter = next_counter(
            pht_valid_q[update_idx] ? pht_q[update_idx] : 2'b01,
            update_taken
        );
    end

    // taken查询：同步更新保证看到最新计数器。
    always_comb begin
        lookup_idx = lookup_pc[2 +: PHT_IDX_W] ^ ghr_q; //gshare核心:^  (不是直接映射，而是^)
        lookup_counter = pht_valid_q[lookup_idx] ? pht_q[lookup_idx] : 2'b01;

        // 同步更新
        if (update_valid && (update_idx == lookup_idx))
            lookup_counter = update_counter;
        lookup_taken = lookup_counter[1];
    end

    // 只有条件分支到达此更新端口，JAL/JALR 不写 PHT，也不进入 GHR。
    always_ff @(posedge clk) begin
        if (rst) begin
            ghr_q <= '0;
            for (entry = 0; entry < PHT_ENTRIES; entry = entry + 1)
                pht_valid_q[entry] <= 1'b0;
        end else if (update_valid) begin
            pht_q[update_idx] <= update_counter;
            pht_valid_q[update_idx] <= 1'b1;
            // ghr：左移
            ghr_q <= {ghr_q[GHR_W-2:0], update_taken};
        end
    end
endmodule
