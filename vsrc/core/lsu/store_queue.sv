// Module: store_queue
// Description: Owns Store allocation, head-authorized side effects, tagged responses and completion slots.
module store_queue (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input scoreboard_pkg::lsu_age_matrix_t age_order,
    input logic head_valid,
    input pipeline_pkg::retire_id_t head_id,
    input logic [1:0] offer_valid, issue_fire,
    input pipeline_pkg::lsu_descriptor_t descriptor [2],
    output logic [1:0] issue_ready,
    output logic [$clog2(core_config_pkg::STORE_QUEUE_ENTRIES)-1:0] allocation_slot [2],
    input scoreboard_pkg::lsu_entry_view_t loads [core_config_pkg::LOAD_QUEUE_ENTRIES],
    output scoreboard_pkg::lsu_entry_view_t view [core_config_pkg::STORE_QUEUE_ENTRIES],
    output logic [core_config_pkg::STORE_QUEUE_ENTRIES-1:0] eligible, done, kill_now,
    input logic [core_config_pkg::STORE_QUEUE_ENTRIES-1:0] presented, request_fire, complete_ready,
    input logic [1:0] response_valid,
    input scoreboard_pkg::memory_response_t response [2],
    output logic [1:0] response_match, response_reject,
    output pipeline_pkg::retire_completion_t completion [core_config_pkg::STORE_QUEUE_ENTRIES],
    output logic busy, draining, owner_valid,
    output pipeline_pkg::retire_id_t owner_id
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    localparam int SQ = STORE_QUEUE_ENTRIES;
    typedef enum logic [1:0] {QUEUED, WAIT_RESPONSE, DONE} state_e;
    logic [SQ-1:0] valid_q, killed_q, available;
    state_e state_q [SQ];
    lsu_descriptor_t descriptor_q [SQ];
    retire_result_t result_q [SQ];
    integer alloc_slot [2], response_slot [2];
    logic older_ordered [SQ];

    assign busy = |valid_q;
    assign draining = |(valid_q & killed_q);
    // 两条分配只竞争 SQ 空槽；Load 的 offer 不消耗 SQ 容量。
    always_comb begin
        available = ~valid_q;
        issue_ready = '0;
        for (int lane = 0; lane < 2; lane++) begin
            alloc_slot[lane] = -1;
            for (int slot = 0; slot < SQ; slot++)
                if (available[slot] && alloc_slot[lane] < 0) alloc_slot[lane] = slot;
            if (descriptor[lane].write && alloc_slot[lane] >= 0 && !rst && !flush && !recovery.valid) begin
                issue_ready[lane] = 1;
                if (offer_valid[lane]) available[alloc_slot[lane]] = 0;
            end
        end
    end
    for (genvar lane = 0; lane < 2; lane++) begin : g_allocation_view
        assign allocation_slot[lane] = $clog2(SQ)'(alloc_slot[lane]);
    end
    for (genvar slot = 0; slot < SQ; slot++) begin : g_slot
        assign view[slot] = '{valid:valid_q[slot], killed:killed_q[slot], descriptor:descriptor_q[slot]};
        assign kill_now[slot] = valid_q[slot] && (flush ||
            (recovery.valid && younger_than(descriptor_q[slot].id, recovery.id, head_slot)));
        assign done[slot] = valid_q[slot] && !killed_q[slot] && state_q[slot] == DONE;
        assign completion[slot] = '{id:descriptor_q[slot].id, result:result_q[slot]};
    end
    // 外部 Store 始终按队头授权，只会有一个已展示/已接受的 Store owner。
    always_comb begin
        eligible = '0;
        owner_valid = 0;
        owner_id = '0;
        for (int slot = 0; slot < SQ; slot++) begin
            older_ordered[slot] = 0;
            for (int prior = 0; prior < LOAD_QUEUE_ENTRIES; prior++)
                if (loads[prior].valid && !loads[prior].killed &&
                    age_order[LOAD_QUEUE_ENTRIES+slot][prior] &&
                    !speculative_ram(loads[prior].descriptor.address)) older_ordered[slot] = 1;
            for (int prior = 0; prior < SQ; prior++)
                if (valid_q[prior] && !killed_q[prior] &&
                    age_order[LOAD_QUEUE_ENTRIES+slot][LOAD_QUEUE_ENTRIES+prior] &&
                    !speculative_ram(descriptor_q[prior].address)) older_ordered[slot] = 1;
            if (valid_q[slot] && !killed_q[slot]) begin
                eligible[slot] = state_q[slot] == QUEUED && !older_ordered[slot] &&
                    head_valid && head_id == descriptor_q[slot].id;
                if (state_q[slot] != QUEUED || presented[slot]) begin
                    owner_valid = 1;
                    owner_id = descriptor_q[slot].id;
                end
            end
        end
    end
    // 返回匹配使用完整标签；两个端口重复同一 ID 的屏蔽由外部路由统一处理。
    always_comb begin
        response_match = '0;
        response_reject = '0;
        for (int portno = 0; portno < 2; portno++) begin
            response_slot[portno] = -1;
            for (int slot = 0; slot < SQ; slot++)
                if (valid_q[slot] && state_q[slot] == WAIT_RESPONSE &&
                    descriptor_q[slot].id == response[portno].id) response_slot[portno] = slot;
            if (response_slot[portno] >= 0) begin
                response_match[portno] = 1;
                response_reject[portno] = response_valid[portno] &&
                    (killed_q[response_slot[portno]] || kill_now[response_slot[portno]]);
            end
        end
    end
    // SQ 独占描述符、请求状态和完成数据；取消后已展示/接受的事务须排空返回。
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= '0;
            killed_q <= '0;
        end else begin
            for (int slot = 0; slot < SQ; slot++) begin
                if (request_fire[slot]) state_q[slot] <= WAIT_RESPONSE;
                for (int portno = 0; portno < 2; portno++) begin
                    if (response_valid[portno] && response_slot[portno] == slot) begin
                        if (killed_q[slot] || kill_now[slot]) valid_q[slot] <= 0;
                        else begin
                            state_q[slot] <= DONE;
                            result_q[slot] <= '0;
                            if (response[portno].error) begin
                                result_q[slot].exc.valid <= 1;
                                result_q[slot].exc.cause <= EXC_STORE_ACCESS_FAULT;
                                result_q[slot].exc.tval <= descriptor_q[slot].address;
                            end
                        end
                    end
                end
                if (complete_ready[slot]) valid_q[slot] <= 0;
                if (kill_now[slot]) begin
                    killed_q[slot] <= 1;
                    if (state_q[slot] != WAIT_RESPONSE && !presented[slot] && !request_fire[slot])
                        valid_q[slot] <= 0;
                end
                for (int lane = 0; lane < 2; lane++) begin
                    if (issue_fire[lane] && descriptor[lane].write && alloc_slot[lane] == slot) begin
                        valid_q[slot] <= 1;
                        killed_q[slot] <= 0;
                        state_q[slot] <= QUEUED;
                        descriptor_q[slot] <= descriptor[lane];
                    end
                end
            end
        end
    end
endmodule
