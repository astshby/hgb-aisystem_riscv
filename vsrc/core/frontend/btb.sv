// Module: btb
// Description: Direct-mapped target table with synchronous update and read-first lookup.
// 直接映射 BTB 保存完整 PC 标签、目标地址、控制流类型和RAS hint，只接受正常退休更新。
module btb (
    input  logic                              clk,
    input  logic                              rst,
    input  core_types_pkg::xlen_t             lookup_pc,
    output logic                              lookup_hit,
    output core_types_pkg::xlen_t             lookup_target,
    output core_types_pkg::branch_op_e        lookup_kind,
    output predictor_types_pkg::ras_op_e     lookup_ras_op,
    output logic [core_config_pkg::BTB_IDX_W-1:0] lookup_idx,
    input  logic                              update_valid,
    input  core_types_pkg::xlen_t             update_pc,
    input  core_types_pkg::xlen_t             update_target,
    input  core_types_pkg::branch_op_e        update_kind,
    input  predictor_types_pkg::ras_op_e     update_ras_op,
    input core_types_pkg::xlen_t lookup_pc_1,
    output logic lookup_hit_1,
    output core_types_pkg::xlen_t lookup_target_1,
    output core_types_pkg::branch_op_e lookup_kind_1,
    output predictor_types_pkg::ras_op_e lookup_ras_op_1,
    output logic [core_config_pkg::BTB_IDX_W-1:0] lookup_idx_1
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import predictor_types_pkg::*;

    // btb必须有：target，tag(from pc)，valid，kind,只有符合后才能给出结果
    logic valid_q [0:BTB_ENTRIES-1];
    xlen_t tag_q [0:BTB_ENTRIES-1];
    xlen_t target_q [0:BTB_ENTRIES-1];
    branch_op_e kind_q [0:BTB_ENTRIES-1];
    ras_op_e ras_op_q [0:BTB_ENTRIES-1];
    logic [BTB_IDX_W-1:0] update_idx;
    integer entry;

    // 查询只看已寄存表项；同拍训练在时钟沿后可见，不把退休训练链接回 IF。
    always_comb begin
        // idx直接映射，取PC的低位作为索引
        lookup_idx = lookup_pc[2 +: BTB_IDX_W];
        lookup_hit = valid_q[lookup_idx] && (tag_q[lookup_idx] == lookup_pc);
        lookup_target = lookup_hit ? target_q[lookup_idx] : '0;
        lookup_kind = lookup_hit ? kind_q[lookup_idx] : BR_NONE;
        lookup_ras_op = lookup_hit ? ras_op_q[lookup_idx] : RAS_NONE;
        // 两个PC读取同一份已寄存表；退休更新仍只有一个写入口。
        lookup_idx_1 = lookup_pc_1[2 +: BTB_IDX_W];
        lookup_hit_1 = valid_q[lookup_idx_1] && tag_q[lookup_idx_1] == lookup_pc_1;
        lookup_target_1 = lookup_hit_1 ? target_q[lookup_idx_1] : '0;
        lookup_kind_1 = lookup_hit_1 ? kind_q[lookup_idx_1] : BR_NONE;
        lookup_ras_op_1 = lookup_hit_1 ? ras_op_q[lookup_idx_1] : RAS_NONE;
    end

    // 表项写入：同索引不同标签会直接替换旧入口。
    // 写入前仍按旧完整 PC 标签查询，不以新 target 或未接受的训练覆盖查询结果。
    assign update_idx = update_pc[2 +: BTB_IDX_W];
    always_ff @(posedge clk) begin
        if (rst) begin
            for (entry = 0; entry < BTB_ENTRIES; entry = entry + 1)
                valid_q[entry] <= 1'b0;
        end else if (update_valid) begin
            valid_q[update_idx] <= 1'b1;
            tag_q[update_idx] <= update_pc;
            target_q[update_idx] <= update_target;
            kind_q[update_idx] <= update_kind;
            ras_op_q[update_idx] <= update_ras_op;
        end
    end
endmodule
