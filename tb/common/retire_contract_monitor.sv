// Module: retire_contract_monitor
// Description: Independently checks tagged completion, ordered retirement, strict-head LSU ownership and recovery.
module retire_contract_monitor (
    input logic clk, rst,
    input logic decode_valid, dispatch_valid, dispatch_ready,
    input pipeline_pkg::retire_id_t alloc_id,
    input pipeline_pkg::retire_alloc_t alloc_meta,
    input pipeline_pkg::d2_ex_t ex_packet,
    input pipeline_pkg::ex_mem_t mem_packet,
    input pipeline_pkg::mem_wb_t wb_packet,
    input pipeline_pkg::pipeline_actions_t actions,
    input logic complete_valid, complete_ready, complete_reject,
    input pipeline_pkg::retire_completion_t completion,
    input logic head_valid, head_complete, retire_fire,
    input pipeline_pkg::retire_id_t head_id,
    input pipeline_pkg::retire_alloc_t head_meta,
    input pipeline_pkg::retire_result_t head_result,
    input logic [core_config_pkg::RETIRE_COUNT_W-1:0] occupancy,
    input logic recovering, drain_complete, response_empty, mdu_idle,
    input logic lsu_owner_valid,
    input pipeline_pkg::retire_id_t lsu_owner_id,
    input pipeline_pkg::redirect_t wb_redirect,
    input logic public_commit,
    input logic d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_ready, d_rsp_error
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import pipeline_pkg::*;

    typedef struct packed {
        retire_id_t id;
        retire_alloc_t meta;
        logic done;
        retire_result_t result;
        logic request_seen, response_seen, response_error;
    } model_entry_t;
    model_entry_t model[$];
    model_entry_t discarded;
    retire_id_t cancelled_ids[$];
    int outstanding;
    retire_id_t bus_owner;
    int strict_head_requests = 0, full_frontend_stalls = 0, flushes = 0;
    int retired_events = 0, maximum_occupancy = 0;
    int completed_events = 0, bypass_retirements = 0, buffered_retirements = 0;
    int younger_completions = 0, alu_during_mdu = 0, rejected_events = 0;
    int completion_index, response_index;
    logic expected_reject, head_was_done, known_cancelled;
    logic prior_flush;

    // 软件队列只由真实分配/完成/退休握手更新，不读取 DUT 槽状态或用 DUT 指针判断年龄。
    // 同沿完成先写参考结果，再校验退休，最后处理取消和新分配，覆盖队头完成旁路。
    // 在途总线计数仅为 TB 证据，RTL 由 LSU 描述符与唯一响应槽持有事务。
    always @(posedge clk) begin
        if (rst) begin
            model.delete();
            cancelled_ids.delete();
            outstanding = 0;
            bus_owner = '0;
            prior_flush = 1'b0;
        end else begin
            assert (int'(occupancy) == model.size() && model.size() <= RETIRE_ENTRIES)
                else $fatal(1, "Retire queue ownership mismatch queue=%0d model=%0d", occupancy, model.size());
            if (model.size() > maximum_occupancy) maximum_occupancy = model.size();
            assert (head_valid == (model.size() != 0)) else $fatal(1, "Retire head valid mismatch");
            if (model.size() != 0) begin
                assert (head_id == model[0].id && head_meta == model[0].meta)
                    else $fatal(1, "Retire head does not match oldest allocation");
            end

            // 完整 ID 查找；代次不同不能匹配同一物理槽，年轻完成不获得退休资格。
            head_was_done = 1'b0;
            if (model.size() != 0) head_was_done = model[0].done;
            completion_index = -1;
            for (int i = 0; i < model.size(); i++)
                if (model[i].id == completion.id) completion_index = i;
            if (complete_valid && complete_ready) begin
                expected_reject = completion_index < 0;
                if (completion_index >= 0)
                    expected_reject = model[completion_index].done ||
                        (wb_redirect.valid && !(completion_index == 0 && retire_fire));
                assert (complete_reject == expected_reject)
                    else $fatal(1, "Completion rejection differs from independent age/ID model");
                if (expected_reject) begin
                    // 只允许取消边界或已取消 owner 的迟到完成；正常重复完成仍是协议错误。
                    known_cancelled = 1'b0;
                    foreach (cancelled_ids[i])
                        if (cancelled_ids[i] == completion.id) known_cancelled = 1'b1;
                    if (completion_index >= 0)
                        assert (wb_redirect.valid && !model[completion_index].done)
                            else $fatal(1, "Live instruction completed twice or was rejected without flush");
                    else
                        assert (recovering && known_cancelled)
                            else $fatal(1, "Completion carries an unallocated or already-drained ID");
                    rejected_events++;
                end else begin
                    if (model[completion_index].meta.kind inside {RET_LOAD, RET_STORE}) begin
                        if (model[completion_index].request_seen) begin
                            assert (model[completion_index].response_seen &&
                                    completion.result.exc.valid == model[completion_index].response_error)
                                else $fatal(1, "LSU completed without its prior response or lost bus error");
                        end else
                            assert (completion.result.exc.valid)
                                else $fatal(1, "LSU completed successfully without any request");
                    end
                    model[completion_index].done = 1'b1;
                    model[completion_index].result = completion.result;
                    if (model[completion_index].meta.kind != RET_BRANCH)
                        model[completion_index].result.next_pc = model[completion_index].meta.seq_pc;
                    completed_events++;
                    if (completion_index > 0) begin
                        younger_completions++;
                        if (!model[0].done && model[0].meta.kind == RET_MDU &&
                            model[completion_index].meta.kind == RET_EXEC)
                            alu_during_mdu++;
                    end
                end
            end else
                assert (!complete_reject) else $fatal(1, "Completion rejected without handshake");

            assert (public_commit == retire_fire) else $fatal(1, "Public commit differs from queue retirement");
            if (model.size() != 0)
                assert (head_complete == model[0].done) else $fatal(1, "Head done differs from completed reference");
            else
                assert (!head_complete) else $fatal(1, "Empty queue reports completed head");
            if (retire_fire) begin
                assert (model.size() != 0) else $fatal(1, "Retirement without allocated owner");
                assert (model[0].done && head_id == model[0].id && head_result == model[0].result)
                    else $fatal(1, "Retirement overtook an incomplete head or corrupted its result");
                retired_events++;
                if (head_was_done) buffered_retirements++;
                else bypass_retirements++;
            end
            assert ((dispatch_valid && dispatch_ready) ==
                    (actions.d2_ex == PIPE_ADVANCE && decode_valid))
                else $fatal(1, "Dispatch and EX acceptance differ");
            if (dispatch_valid && !dispatch_ready) begin
                full_frontend_stalls++;
                assert (actions.if_d1 == PIPE_HOLD && actions.d1_d2 == PIPE_HOLD)
                    else $fatal(1, "Capacity pressure lost an unallocated frontend packet");
            end
            assert (!(recovering && dispatch_valid && dispatch_ready))
                else $fatal(1, "Allocation occurred before recovery drain");

            // 首版严格检查沿前队头，不把本沿将退休的旧项从年龄模型中提前弹出。
            // 每个 Load/Store 最多发一次请求；MMIO 读也不能越过任何较老项。
            if (d_req_valid) begin
                assert (lsu_owner_valid && !wb_redirect.valid && model.size() != 0)
                    else $fatal(1, "LSU offered a request without a live head");
                assert (lsu_owner_id == model[0].id && !model[0].request_seen)
                    else $fatal(1, "LSU offered a non-head or already accepted request");
            end
            if (d_req_valid && d_req_ready) begin
                assert (lsu_owner_valid && !wb_redirect.valid && outstanding == 0 && model.size() != 0)
                    else $fatal(1, "LSU issued without sole live ownership");
                assert (lsu_owner_id == model[0].id && !retire_fire &&
                        !model[0].request_seen && model[0].meta.kind == (d_req_write ? RET_STORE : RET_LOAD))
                    else $fatal(1, "LSU request is not strict head, duplicated, or changed operation");
                model[0].request_seen = 1'b1;
                bus_owner = lsu_owner_id;
                strict_head_requests++;
            end
            // 响应登记放在 completion 检查之后，保留响应先寄存、后完成的边界要求。
            if (d_rsp_valid && d_rsp_ready) begin
                assert (outstanding == 1) else $fatal(1, "Unowned/duplicate bus response");
                assert (lsu_owner_valid && lsu_owner_id == bus_owner)
                    else $fatal(1, "LSU response changed its accepted owner");
                response_index = -1;
                for (int i = 0; i < model.size(); i++)
                    if (model[i].id == bus_owner) response_index = i;
                assert (response_index >= 0) else $fatal(1, "Bus response lost its allocated owner");
                assert (model[response_index].request_seen && !model[response_index].response_seen)
                    else $fatal(1, "Duplicate response or response without a request");
                model[response_index].response_seen = 1'b1;
                model[response_index].response_error = d_rsp_error;
            end

            if (wb_redirect.valid) begin
                assert (outstanding == 0 && !(d_req_valid && d_req_ready))
                    else $fatal(1, "Architectural flush crossed pending data transaction");
                flushes++;
            end
            if (prior_flush)
                assert (!ex_packet.valid && !mem_packet.valid && !wb_packet.valid &&
                        response_empty && outstanding == 0 && recovering)
                    else $fatal(1, "Global flush retained pipeline/data owner or skipped recovery");
            if (recovering && drain_complete) begin
                assert (outstanding == 0 && response_empty && mdu_idle && model.size() == 0)
                    else $fatal(1, "Recovery declared drain with a live owner");
                cancelled_ids.delete();
            end

            outstanding += int'(d_req_valid && d_req_ready) - int'(d_rsp_valid && d_rsp_ready);
            assert (outstanding >= 0 && outstanding <= 1) else $fatal(1, "Multiple LSU owners");
            if (wb_redirect.valid) begin
                cancelled_ids.delete();
                for (int i = (retire_fire ? 1 : 0); i < model.size(); i++)
                    if (!model[i].done) cancelled_ids.push_back(model[i].id);
                model.delete();
            end else begin
                if (retire_fire) discarded = model.pop_front();
                if (dispatch_valid && dispatch_ready) begin
                    for (int i = 0; i < model.size(); i++) begin
                        assert (model[i].id.slot != alloc_id.slot)
                            else $fatal(1, "Allocation reused a still-live physical slot");
                        // 独立年龄模型检查保守 WAW；本沿正常退休已先弹出，不借用 DUT hazard 输出。
                        assert (!(alloc_meta.gpr_write && alloc_meta.rd != '0 &&
                                  model[i].meta.gpr_write && model[i].meta.rd == alloc_meta.rd))
                            else $fatal(1, "Allocation introduced a second live writer to the same GPR");
                    end
                    model.push_back('{id:alloc_id, meta:alloc_meta, default:'0});
                end
            end
            prior_flush = wb_redirect.valid;
        end
    end
endmodule

// 所有定向 core 实例复用同一监视器；不进入综合源清单，也不改变 DUT 时序。
bind core retire_contract_monitor u_retire_contract_monitor (
    .clk, .rst, .decode_valid(d1_d2_q.valid), .dispatch_valid, .dispatch_ready, .alloc_id, .alloc_meta,
    .ex_packet(d2_ex_q), .mem_packet(ex_mem_q), .wb_packet(mem_wb_q), .actions(pipeline_actions),
    .complete_valid, .complete_ready, .complete_reject, .completion,
    .head_valid, .head_complete, .retire_fire(queue_retire_fire), .head_id, .head_meta, .head_result,
    .occupancy(retire_occupancy), .recovering(retire_recovering),
    .drain_complete(retire_drain_complete), .response_empty(!lsu_busy), .mdu_idle(mdu_req_ready),
    .lsu_owner_valid, .lsu_owner_id,
    .wb_redirect, .public_commit(commit_valid), .d_req_valid(dmem_req_valid), .d_req_ready(dmem_req_ready),
    .d_req_write(dmem_req_write), .d_rsp_valid(dmem_rsp_valid), .d_rsp_ready(dmem_rsp_ready),
    .d_rsp_error(dmem_rsp_error)
);
