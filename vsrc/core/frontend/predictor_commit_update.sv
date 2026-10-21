// Module: predictor_commit_update
// Description: Formats one normally retiring branch into the sole predictor training event.
module predictor_commit_update (
    input  logic                            retire_fire,
    input  pipeline_pkg::retire_alloc_t      head_meta,
    input  pipeline_pkg::retire_result_t     head_result,
    output pipeline_pkg::pred_update_t      update
);
    import pipeline_pkg::*;

    // 查询快照由分配槽持有，实际结果由完成口持有；未退休、异常或已取消项均不能训练。
    // 不看前端 redirect：正常分支纠错与训练可以同拍，不引入恢复到训练有效位的组合门控。
    always_comb begin
        update = '0;
        if (retire_fire && !head_result.exc.valid && head_meta.kind == RET_BRANCH) begin
            update.valid = 1'b1;
            update.kind = head_meta.branch_kind;
            update.pc = head_meta.pc;
            update.taken = head_result.branch.taken;
            update.target = head_result.branch.target;
            update.train = head_meta.pred_train;
            update.ras_op = head_meta.ras_op;
        end
    end
endmodule
