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
    stack_t recovered [REPLAY_SLOTS+1];

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

    // 恢复从本拍退休后的完整栈出发，按老到年轻重放所有存活事件。
    // 上层须排除本拍退休项、取消项和重复项，并包含已完成但尚未退休的项。
    // 保存全部内容，避免错误路径溢出覆盖后仅恢复指针而读到错误返回地址。
    // 恢复包含 REPLAY_SLOTS 级组合复演链；没有新增结果级，但尚未验证其实现时序。
    assign recovered[0] = committed_next;
    for (genvar slot = 0; slot < REPLAY_SLOTS; slot++) begin : g_replay
        assign recovered[slot+1] = replay_valid[slot] ?
            apply_event(recovered[slot], replay[slot]) : recovered[slot];
    end

    // clear/reset 清两套状态；恢复优先于同拍预测事件，正常提交仍计入恢复基底。
    always_ff @(posedge clk) begin
        if (rst || clear) begin
            committed_q <= '0;
            speculative_q <= '0;
        end else begin
            committed_q <= committed_next;
            speculative_q <= recover ? recovered[REPLAY_SLOTS] : speculative_next;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (DEPTH >= 1 && REPLAY_SLOTS >= 1)
            else $fatal(1, "RAS requires positive DEPTH and REPLAY_SLOTS");
    end
`endif
endmodule
