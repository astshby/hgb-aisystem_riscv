// Module: predictor
// Description: Combines one BTB with one GShare direction predictor.
// 分支预测逻辑：BTB 提供目标与类型；仅条件分支使用 GShare 决定 taken。(需要接入updata用于更新)
module predictor (
    input  logic                       clk,
    input  logic                       rst,
    input  core_types_pkg::xlen_t      lookup_pc,
    output pipeline_pkg::pred_info_t   prediction,
    input  pipeline_pkg::pred_update_t update
);
    import core_types_pkg::*;

    logic btb_hit;
    xlen_t btb_target;
    branch_op_e btb_kind;
    logic [core_config_pkg::BTB_IDX_W-1:0] btb_idx;
    logic gshare_taken;
    logic [core_config_pkg::PHT_IDX_W-1:0] pht_idx;
    logic lookup_conditional;
    logic update_conditional;

    // updata:btb只要有效就更新，gshare不考虑J指令跳转（所以加一位 &）
    btb u_btb (
        .clk,
        .rst,
        .lookup_pc,
        .lookup_hit(btb_hit),
        .lookup_target(btb_target),
        .lookup_kind(btb_kind),
        .lookup_idx(btb_idx),
        .update_valid(update.valid),
        .update_pc(update.pc),
        .update_target(update.target),
        .update_kind(update.kind)
    );

    gshare u_gshare (
        .clk,
        .rst,
        .lookup_pc,
        .lookup_taken(gshare_taken),
        .lookup_idx(pht_idx),
        .update_valid(update.valid && update_conditional),
        .update_idx(update.pred.pht_idx),
        .update_taken(update.taken)
    );

    // 汇总预测，并识别查询/更新是否属于条件分支。
    always_comb begin
        lookup_conditional = (btb_kind == BR_EQ) || (btb_kind == BR_NE) ||
                             (btb_kind == BR_LT) || (btb_kind == BR_GE) ||
                             (btb_kind == BR_LTU) || (btb_kind == BR_GEU);
        update_conditional = (update.kind == BR_EQ) || (update.kind == BR_NE) ||
                             (update.kind == BR_LT) || (update.kind == BR_GE) ||
                             (update.kind == BR_LTU) || (update.kind == BR_GEU);
        prediction = '0;
        prediction.hit = btb_hit;
        prediction.taken = btb_hit && (lookup_conditional ? gshare_taken : 1'b1);
        prediction.target = btb_target;
        prediction.btb_idx = btb_idx;
        prediction.pht_idx = pht_idx;
    end

endmodule
