// Module: ras
// Description: Bounded speculative return stack with full-content committed-state recovery.
module ras #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned REPLAY_SLOTS = 8
) (
    input logic clk, rst, clear,
    input logic fetch_fire,
    input predictor_types_pkg::ras_event_t fetch_event,
    input logic commit_valid,
    input predictor_types_pkg::ras_event_t commit_event,
    input logic commit_valid_1,
    input predictor_types_pkg::ras_event_t commit_event_1,
    input logic recover,
    input logic [REPLAY_SLOTS-1:0] replay_valid,
    input predictor_types_pkg::ras_event_t replay [REPLAY_SLOTS],
    output logic top_valid,
    output core_types_pkg::xlen_t top_addr,
    input logic fetch_second,
    input predictor_types_pkg::ras_event_t fetch_event_1
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import predictor_types_pkg::*;
    localparam int unsigned COUNT_W = $clog2(DEPTH + 1);
    typedef struct packed {
        logic [COUNT_W-1:0] count;
        logic [DEPTH-1:0][XLEN-1:0] entries;
    } stack_t;
    stack_t committed_q, committed_next;
    stack_t speculative_q, speculative_next;
    localparam int unsigned INDEX_W = DEPTH > 1 ? $clog2(DEPTH) : 1;
    localparam int unsigned REPLAY_LEAVES = 2 ** $clog2(REPLAY_SLOTS);
    typedef logic [COUNT_W-1:0] count_t;
    typedef struct packed {
        count_t prefix_count;
        count_t skip_count;
        count_t keep_count;
        logic [DEPTH-1:0][XLEN-1:0] prefix;
    } replay_transform_t;
    replay_transform_t replay_tree [2*REPLAY_LEAVES];
    stack_t recovered;
    count_t recovered_keep;

    // 栈顶固定在 entries[0]；查询只读寄存状态，提交/恢复不组合旁路到目标地址。
    assign top_valid = speculative_q.count != '0;
    assign top_addr = speculative_q.entries[0];

    // 满栈丢最老项，空栈 pop 无副作用；pop/push 在空栈上等价于 push。
    function automatic stack_t apply_event(input stack_t old, input ras_event_t event_in);
        stack_t next_state;
        next_state = old;
        unique case (event_in.op)
            RAS_PUSH: begin
                for (int i = DEPTH-1; i > 0; i--)
                    next_state.entries[i] = old.entries[i-1];
                next_state.entries[0] = event_in.addr;
                if (old.count < COUNT_W'(DEPTH)) next_state.count = old.count + 1'b1;
            end
            RAS_POP: if (old.count != '0) begin
                for (int i = 1; i < int'(DEPTH); i++)
                    next_state.entries[i-1] = old.entries[i];
                next_state.entries[DEPTH-1] = '0;
                next_state.count = old.count - 1'b1;
            end
            RAS_POP_PUSH: begin
                next_state.entries[0] = event_in.addr;
                if (old.count == '0) next_state.count = COUNT_W'(1);
            end
            default: ;
        endcase
        return next_state;
    endfunction

    // committed 只接无异常退休事件，fetch_fire 只接实际被接受的取指事件。
    // 两者的资格由上层提供；本单元不猜测流水级或复制退休队列的所有权。
    always_comb begin
        committed_next = committed_q;
        if (commit_valid) committed_next = apply_event(committed_q, commit_event);
        // 两个真实退休事件先老后年轻应用，恢复基底也必须包含第二条。
        if (commit_valid_1) committed_next = apply_event(committed_next, commit_event_1);
        speculative_next = speculative_q;
        if (fetch_fire) speculative_next = apply_event(speculative_q, fetch_event);
        if (fetch_fire && fetch_second)
            speculative_next = apply_event(speculative_next, fetch_event_1);
    end

    // 任意事件段都等价于：固定新前缀 ++ 输入栈的连续切片。
    // skip/keep 同时记录顶部弹出与底部溢出丢弃，不能只计算 push-pop 的净数量。
    function automatic replay_transform_t identity_transform();
        replay_transform_t transform;
        transform = '0;
        transform.keep_count = count_t'(DEPTH);
        return transform;
    endfunction

    function automatic replay_transform_t event_transform(input ras_event_t event_in);
        replay_transform_t transform;
        transform = identity_transform();
        unique case (event_in.op)
            RAS_PUSH: begin
                transform.prefix_count = count_t'(1);
                transform.keep_count = count_t'(DEPTH-1);
                transform.prefix[0] = event_in.addr;
            end
            RAS_POP: begin
                transform.skip_count = count_t'(1);
                transform.keep_count = count_t'(DEPTH-1);
            end
            RAS_POP_PUSH: begin
                transform.prefix_count = count_t'(1);
                transform.skip_count = count_t'(1);
                transform.keep_count = count_t'(DEPTH-1);
                transform.prefix[0] = event_in.addr;
            end
            default: ;
        endcase
        return transform;
    endfunction

    // younger 的输入切片先经过 older 的固定前缀，再进入 older 保留下来的原始切片。
    // 只合并有界计数和至多 DEPTH 个地址；组合满足结合律，树形合并保留先老后年轻顺序。
    function automatic replay_transform_t compose_transform(
        input replay_transform_t older,
        input replay_transform_t younger
    );
        replay_transform_t combined;
        count_t prefix_keep, suffix_skip, suffix_keep, suffix_room;
        logic [COUNT_W:0] skip_sum;
        combined = '0;
        prefix_keep = older.prefix_count > younger.skip_count ?
            older.prefix_count - younger.skip_count : '0;
        if (prefix_keep > younger.keep_count) prefix_keep = younger.keep_count;
        suffix_skip = younger.skip_count > older.prefix_count ?
            younger.skip_count - older.prefix_count : '0;
        suffix_keep = older.keep_count > suffix_skip ? older.keep_count - suffix_skip : '0;
        suffix_room = younger.keep_count - prefix_keep;
        combined.prefix_count = younger.prefix_count + prefix_keep;
        skip_sum = {1'b0, older.skip_count} + {1'b0, suffix_skip};
        combined.skip_count = skip_sum > (COUNT_W+1)'(DEPTH) ?
            count_t'(DEPTH) : skip_sum[COUNT_W-1:0];
        combined.keep_count = suffix_keep < suffix_room ? suffix_keep : suffix_room;
        for (int i = 0; i < DEPTH; i++) begin
            if (count_t'(i) < younger.prefix_count)
                combined.prefix[i] = younger.prefix[i];
            else if (count_t'(i) < combined.prefix_count)
                combined.prefix[i] = older.prefix[INDEX_W'(
                    count_t'(i) - younger.prefix_count + younger.skip_count)];
        end
        return combined;
    endfunction

    // 恢复基底包含本拍两个真实退休事件；上层排除退休、取消和重复项。
    // 无效槽和补齐叶子均为空变换，34 项恢复只经过 6 层合并，不增加流水拍数。
    assign replay_tree[0] = identity_transform();
    for (genvar slot = 0; slot < REPLAY_LEAVES; slot++) begin : g_replay_leaf
        if (slot < REPLAY_SLOTS) begin : g_event
            assign replay_tree[REPLAY_LEAVES+slot] = replay_valid[slot] ?
                event_transform(replay[slot]) : identity_transform();
        end else begin : g_padding
            assign replay_tree[REPLAY_LEAVES+slot] = identity_transform();
        end
    end
    for (genvar node = 1; node < REPLAY_LEAVES; node++) begin : g_replay_merge
        assign replay_tree[node] = compose_transform(replay_tree[2*node], replay_tree[2*node+1]);
    end

    // 只有树根读取 committed 内容；无效项保持为零，查询仍只读取 speculative 寄存器。
    always_comb begin
        recovered = '0;
        recovered_keep = committed_next.count > replay_tree[1].skip_count ?
            committed_next.count - replay_tree[1].skip_count : '0;
        if (recovered_keep > replay_tree[1].keep_count)
            recovered_keep = replay_tree[1].keep_count;
        recovered.count = replay_tree[1].prefix_count + recovered_keep;
        for (int i = 0; i < DEPTH; i++) begin
            if (count_t'(i) < replay_tree[1].prefix_count)
                recovered.entries[i] = replay_tree[1].prefix[i];
            else if (count_t'(i) < recovered.count)
                recovered.entries[i] = committed_next.entries[INDEX_W'(
                    count_t'(i) - replay_tree[1].prefix_count + replay_tree[1].skip_count)];
        end
    end

    // clear/reset 清两套状态；恢复优先于同拍预测事件，正常提交仍计入恢复基底。
    always_ff @(posedge clk) begin
        if (rst || clear) begin
            committed_q <= '0;
            speculative_q <= '0;
        end else begin
            committed_q <= committed_next;
            speculative_q <= recover ? recovered : speculative_next;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (DEPTH >= 1 && REPLAY_SLOTS >= 1)
            else $fatal(1, "RAS requires positive DEPTH and REPLAY_SLOTS");
    end
`endif
endmodule
