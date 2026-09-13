// Module: btb
// Description: Direct-mapped target table with synchronous update and explicit lookup bypass.
// 直接映射 BTB 保存完整 PC 标签、目标地址和控制流类型,并且在仲裁后更新
module btb (
    input  logic                              clk,
    input  logic                              rst,
    input  core_types_pkg::xlen_t             lookup_pc,
    output logic                              lookup_hit,
    output core_types_pkg::xlen_t             lookup_target,
    output core_types_pkg::branch_op_e        lookup_kind,
    output logic [core_config_pkg::BTB_IDX_W-1:0] lookup_idx,
    input  logic                              update_valid,
    input  core_types_pkg::xlen_t             update_pc,
    input  core_types_pkg::xlen_t             update_target,
    input  core_types_pkg::branch_op_e        update_kind
);
    import core_config_pkg::*;
    import core_types_pkg::*;

    // btb必须有：target，tag(from pc)，valid，kind,只有符合后才能给出结果
    logic valid_q [0:BTB_ENTRIES-1];
    xlen_t tag_q [0:BTB_ENTRIES-1];
    xlen_t target_q [0:BTB_ENTRIES-1];
    branch_op_e kind_q [0:BTB_ENTRIES-1];
    logic [BTB_IDX_W-1:0] update_idx;
    integer entry;

    // 同时查表与更新旁路：旁路避免刚训练的入口还不可见。
    always_comb begin
        // idx直接映射，取PC的低位作为索引
        lookup_idx = lookup_pc[2 +: BTB_IDX_W];
        update_idx = update_pc[2 +: BTB_IDX_W];
        lookup_hit = valid_q[lookup_idx] && (tag_q[lookup_idx] == lookup_pc);
        lookup_target = lookup_hit ? target_q[lookup_idx] : '0;
        lookup_kind = lookup_hit ? kind_q[lookup_idx] : BR_NONE;

        // 同步更新，直接比较pc(而不是target)
        if (update_valid && (update_idx == lookup_idx)) begin
            lookup_hit = (update_pc == lookup_pc);
            lookup_target = lookup_hit ? update_target : '0;
            lookup_kind = lookup_hit ? update_kind : BR_NONE;
        end
    end

    // 表项写入：同索引不同标签会直接替换旧入口。
    always_ff @(posedge clk) begin
        if (rst) begin
            for (entry = 0; entry < BTB_ENTRIES; entry = entry + 1)
                valid_q[entry] <= 1'b0;
        end else if (update_valid) begin
            valid_q[update_idx] <= 1'b1;
            tag_q[update_idx] <= update_pc;
            target_q[update_idx] <= update_target;
            kind_q[update_idx] <= update_kind;
        end
    end
endmodule
