// Module: predictor
// Description: Parallel read-first BTB and selectable GShare/Tournament prediction.
// BTB 提供目标与类型；方向表并行查询，全部状态只接正常退休训练。
module predictor (
    input  logic                       clk,
    input  logic                       rst,
    input  core_types_pkg::xlen_t      lookup_pc,
    input  logic                       ras_top_valid,
    input  core_types_pkg::xlen_t      ras_top_addr,
    output pipeline_pkg::pred_info_t   prediction,
    input  pipeline_pkg::pred_update_t update,
    input core_types_pkg::xlen_t lookup_pc_1,
    output pipeline_pkg::pred_info_t prediction_1
);
    import core_types_pkg::*;
    import core_config_pkg::*;
    import predictor_types_pkg::*;

    logic btb_hit;
    xlen_t btb_target;
    branch_op_e btb_kind;
    ras_op_e btb_ras_op;
    logic [core_config_pkg::BTB_IDX_W-1:0] btb_idx;
    logic gshare_taken;
    logic [core_config_pkg::PHT_IDX_W-1:0] pht_idx;
    logic lookup_conditional;
    logic update_conditional;
    logic local_taken, choose_local, direction_taken;
    logic [LOCAL_HISTORY_W-1:0] local_idx;
    logic [CHOOSER_IDX_W-1:0] chooser_idx;
    logic btb_hit_1, gshare_taken_1, local_taken_1, choose_local_1;
    logic conditional_1;
    xlen_t btb_target_1;
    branch_op_e btb_kind_1;
    ras_op_e btb_ras_op_1;
    logic [BTB_IDX_W-1:0] btb_idx_1;
    logic [PHT_IDX_W-1:0] pht_idx_1;
    logic [LOCAL_HISTORY_W-1:0] local_idx_1;
    logic [CHOOSER_IDX_W-1:0] chooser_idx_1;

    // BTB 接收所有正常退休分支，GShare 只接条件分支；查询不旁路本拍训练。
    btb u_btb (
        .clk,
        .rst,
        .lookup_pc,
        .lookup_hit(btb_hit),
        .lookup_target(btb_target),
        .lookup_kind(btb_kind),
        .lookup_ras_op(btb_ras_op),
        .lookup_idx(btb_idx),
        .update_valid(update.valid),
        .update_pc(update.pc),
        .update_target(update.target),
        .update_kind(update.kind),
        .update_ras_op(update.ras_op),
        .lookup_pc_1, .lookup_hit_1(btb_hit_1), .lookup_target_1(btb_target_1),
        .lookup_kind_1(btb_kind_1), .lookup_ras_op_1(btb_ras_op_1), .lookup_idx_1(btb_idx_1)
    );

    gshare u_gshare (
        .clk,
        .rst,
        .lookup_pc,
        .lookup_taken(gshare_taken),
        .lookup_idx(pht_idx),
        .update_valid(update.valid && update_conditional),
        .update_idx(update.train.pht_idx),
        .update_taken(update.taken), .lookup_pc_1,
        .lookup_taken_1(gshare_taken_1), .lookup_idx_1(pht_idx_1)
    );

    // 两个方向候选与 chooser 同拍查询；Local 内部 LHT→PHT 依赖仍需后续时序报告评估。
    generate
        if (PREDICTOR_MODE == 1) begin
            local_history #(.LHT_ENTRIES(LOCAL_ENTRIES), .HISTORY_W(LOCAL_HISTORY_W)) u_local (
                .clk, .rst, .lookup_pc, .lookup_taken(local_taken), .lookup_idx(local_idx),
                .update_valid(update.valid && update_conditional), .update_pc(update.pc),
                .update_idx(update.train.local_idx), .update_taken(update.taken),
                .lookup_pc_1, .lookup_taken_1(local_taken_1), .lookup_idx_1(local_idx_1)
            );
            chooser #(.ENTRIES(CHOOSER_ENTRIES)) u_chooser (
                .clk, .rst, .lookup_pc, .choose_local, .lookup_idx(chooser_idx),
                .update_valid(update.valid && update_conditional),
                .update_idx(update.train.chooser_idx),
                .update_local_taken(update.train.local_taken),
                .update_global_taken(update.train.global_taken), .update_taken(update.taken),
                .lookup_pc_1, .choose_local_1, .lookup_idx_1(chooser_idx_1)
            );
        end else begin
            assign local_taken = 1'b0;
            assign choose_local = 1'b0;
            assign local_idx = '0;
            assign chooser_idx = '0;
            assign local_taken_1 = 1'b0;
            assign choose_local_1 = 1'b0;
            assign local_idx_1 = '0;
            assign chooser_idx_1 = '0;
        end
    endgenerate

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
        direction_taken = choose_local ? local_taken : gshare_taken;
        prediction.taken = btb_hit && (lookup_conditional ? direction_taken : 1'b1);
        prediction.target = btb_target;
        prediction.ras_op = RAS_ENABLE ? btb_ras_op : RAS_NONE;
        if (RAS_ENABLE && ras_top_valid && btb_hit &&
            (btb_ras_op inside {RAS_POP, RAS_POP_PUSH})) prediction.target = ras_top_addr;
        prediction.btb_idx = btb_idx;
        prediction.train.pht_idx = pht_idx;
        prediction.train.local_idx = local_idx;
        prediction.train.chooser_idx = chooser_idx;
        prediction.train.global_taken = gshare_taken;
        prediction.train.local_taken = local_taken;
        prediction.train.choose_local = choose_local;
        conditional_1 = btb_kind_1 inside {BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU};
        prediction_1 = '0;
        prediction_1.hit = btb_hit_1;
        prediction_1.taken = btb_hit_1 && (!conditional_1 ||
            (choose_local_1 ? local_taken_1 : gshare_taken_1));
        prediction_1.target = btb_target_1;
        prediction_1.ras_op = RAS_ENABLE ? btb_ras_op_1 : RAS_NONE;
        if (RAS_ENABLE && ras_top_valid && btb_hit_1 &&
            (btb_ras_op_1 inside {RAS_POP, RAS_POP_PUSH})) prediction_1.target = ras_top_addr;
        prediction_1.btb_idx = btb_idx_1;
        prediction_1.train = '{pht_idx:pht_idx_1, local_idx:local_idx_1,
            chooser_idx:chooser_idx_1, global_taken:gshare_taken_1,
            local_taken:local_taken_1, choose_local:choose_local_1};
    end

`ifndef SYNTHESIS
    initial begin
        assert (PREDICTOR_MODE <= 1) else $fatal(1, "Unsupported predictor mode");
    end
`endif

endmodule
