// Module: load_store_queue
// Description: Dual-AGU load/store queue with tagged responses, byte forwarding and precise side effects.
module load_store_queue #(
    parameter int unsigned COMPLETION_PORTS = 2
) (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic head_valid,
    input pipeline_pkg::retire_id_t head_id,
    input logic [1:0] offer_valid, issue_fire,
    input pipeline_pkg::lsu_descriptor_t descriptor [2],
    output logic [1:0] issue_ready,
    output logic [1:0] mem_req_valid,
    input logic [1:0] mem_req_ready,
    output scoreboard_pkg::memory_request_t mem_request [2],
    input logic [1:0] mem_rsp_valid,
    output logic [1:0] mem_rsp_ready,
    input scoreboard_pkg::memory_response_t mem_response [2],
    output logic [1:0] response_reject,
    output logic [COMPLETION_PORTS-1:0] complete_valid,
    input logic [COMPLETION_PORTS-1:0] complete_ready,
    output pipeline_pkg::retire_completion_t completion [COMPLETION_PORTS],
    output pipeline_pkg::retire_gpr_forward_t early_forward [2],
    output logic busy, draining,
    output logic store_owner_valid,
    output pipeline_pkg::retire_id_t store_owner_id
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    localparam int LQ = LOAD_QUEUE_ENTRIES;
    localparam int SQ = STORE_QUEUE_ENTRIES;
    localparam int ENTRIES = LQ + SQ;
    localparam int IDX_W = $clog2(ENTRIES);
    lsu_entry_view_t loads [LQ], stores [SQ];
    lsu_descriptor_t entry_q [ENTRIES], selected_descriptor [2];
    retire_completion_t slot_completion [ENTRIES];
    retire_gpr_forward_t response_forward [2];
    logic [ENTRIES-1:0] valid_q, killed_q, kill_now, eligible, forwarded, done_candidates;
    logic [ENTRIES-1:0] request_candidates, completed_slots, presented, slot_request_fire, slot_forward_fire;
    logic [ENTRIES-1:0] older [ENTRIES], request_select [2], request_first, request_second, load_candidates;
    logic [ENTRIES-1:0] request_preceding [ENTRIES], load_preceding [ENTRIES];
    logic [1:0] load_ready, store_ready, load_match, store_match, load_reject, store_reject;
    logic [1:0] request_locked_q, request_fire, response_fire, routed_response_valid, forward_fire;
    logic [IDX_W-1:0] request_owner_q [2], selected [2];
    logic [COMPLETION_PORTS-1:0] result_fire;
    xlen_t formatted_forward [LQ], forwarded_data [2];
    logic load_busy, store_busy, load_draining, store_draining, store_state_valid;
    retire_id_t store_state_id;

    // LQ/SQ 分别拥有容量、描述符、请求状态、返回和完成；此层只路由外部端口与全局仲裁。
    load_queue u_load (
        .clk, .rst, .flush, .recovery, .head_slot, .head_valid, .head_id,
        .offer_valid, .issue_fire, .descriptor, .issue_ready(load_ready), .stores, .view(loads),
        .eligible(eligible[LQ-1:0]), .forwarded(forwarded[LQ-1:0]),
        .done(done_candidates[LQ-1:0]), .kill_now(kill_now[LQ-1:0]),
        .forwarded_data(formatted_forward), .presented(presented[LQ-1:0]),
        .request_fire(slot_request_fire[LQ-1:0]), .forward_fire(slot_forward_fire[LQ-1:0]),
        .complete_ready(completed_slots[LQ-1:0]), .response_valid(routed_response_valid),
        .response(mem_response), .response_match(load_match), .response_reject(load_reject),
        .response_forward, .completion(slot_completion[0:LQ-1]), .busy(load_busy), .draining(load_draining)
    );
    store_queue u_store (
        .clk, .rst, .flush, .recovery, .head_slot, .head_valid, .head_id,
        .offer_valid, .issue_fire, .descriptor, .issue_ready(store_ready), .loads, .view(stores),
        .eligible(eligible[ENTRIES-1:LQ]), .done(done_candidates[ENTRIES-1:LQ]),
        .kill_now(kill_now[ENTRIES-1:LQ]), .presented(presented[ENTRIES-1:LQ]),
        .request_fire(slot_request_fire[ENTRIES-1:LQ]), .complete_ready(completed_slots[ENTRIES-1:LQ]),
        .response_valid(routed_response_valid), .response(mem_response),
        .response_match(store_match), .response_reject(store_reject),
        .completion(slot_completion[LQ:ENTRIES-1]), .busy(store_busy), .draining(store_draining),
        .owner_valid(store_state_valid), .owner_id(store_state_id)
    );
    assign issue_ready = load_ready | store_ready;
    assign busy = load_busy || store_busy;
    assign draining = load_draining || store_draining;
    assign forwarded[ENTRIES-1:LQ] = '0;
    assign mem_rsp_ready = {2{!rst}};
    assign request_fire = mem_req_valid & mem_req_ready;
    assign response_fire = mem_rsp_valid & mem_rsp_ready;
    assign result_fire = complete_valid & complete_ready;
    assign store_owner_valid = store_state_valid || (mem_req_valid[0] && mem_request[0].write);
    assign store_owner_id = (mem_req_valid[0] && mem_request[0].write) ? mem_request[0].id : store_state_id;

    for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_view
        if (slot < LQ) begin : g_load
            assign valid_q[slot] = loads[slot].valid;
            assign killed_q[slot] = loads[slot].killed;
            assign entry_q[slot] = loads[slot].descriptor;
        end else begin : g_store
            assign valid_q[slot] = stores[slot-LQ].valid;
            assign killed_q[slot] = stores[slot-LQ].killed;
            assign entry_q[slot] = stores[slot-LQ].descriptor;
        end
        assign presented[slot] =
            (request_locked_q[0] && request_owner_q[0] == IDX_W'(slot)) ||
            (request_locked_q[1] && request_owner_q[1] == IDX_W'(slot));
        assign slot_request_fire[slot] =
            (request_fire[0] && request_select[0][slot]) || (request_fire[1] && request_select[1][slot]);
        assign slot_forward_fire[slot] =
            (forward_fire[0] && request_select[0][slot]) || (forward_fire[1] && request_select[1][slot]);
        // 统一年龄只用于两类候选的端口仲裁；各队列的读写状态不在此层更新。
        for (genvar other = 0; other < ENTRIES; other++) begin : g_age
            assign older[slot][other] = younger_than(entry_q[slot].id, entry_q[other].id, head_slot) ||
                (entry_q[other].id.slot == entry_q[slot].id.slot && other < slot);
        end
    end

    // 重复/失效响应接收并拒绝，两个队列都不重复更新同一个事务。
    always_comb begin
        routed_response_valid = response_fire;
        if (response_fire[0] && mem_response[0].id == mem_response[1].id)
            routed_response_valid[1] = 0;
        response_reject = response_fire & (~(load_match | store_match) | load_reject | store_reject);
        if (response_fire[1] && !routed_response_valid[1]) response_reject[1] = 1;
    end
    // 请求直接从寄存描述符选择；只在下游反压时锁定 owner，不为所有访问增加请求拍。
    // 已展示的取消读仍保留 valid/地址，接受后排空返回；Store/MMIO 的队头许可排除这种取消。
    always_comb begin
        request_candidates = eligible;
        for (int portno = 0; portno < 2; portno++)
            if (request_locked_q[portno]) request_candidates[request_owner_q[portno]] = 0;
    end
    // 固定槽并行比较年龄，选择向量直接驱动数据与状态更新。端口1排除端口0的唯一选择；
    // 已锁定 owner 从候选中剔除，保持展示期间的请求稳定。
    assign request_select[0] = request_first;
    assign request_select[1] = request_second;
    for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_selection
        assign request_preceding[slot] = older[slot] & request_candidates;
        assign load_candidates[slot] = request_candidates[slot] && !entry_q[slot].write;
        assign load_preceding[slot] = older[slot] & load_candidates;
        assign request_first[slot] = request_locked_q[0] ?
            request_owner_q[0] == IDX_W'(slot) :
            request_candidates[slot] && !(|request_preceding[slot]);
        assign request_second[slot] = request_locked_q[1] ?
            request_owner_q[1] == IDX_W'(slot) :
            load_candidates[slot] && !request_first[slot] &&
            !(|(load_preceding[slot] & ~request_first));
    end
    always_comb begin
        mem_req_valid = 0; forward_fire = 0;
        for (int portno = 0; portno < 2; portno++) begin
            selected[portno] = '0; selected_descriptor[portno] = '0;
            for (int slot = 0; slot < ENTRIES; slot++) begin
                selected[portno] |= IDX_W'(slot) & {IDX_W{request_select[portno][slot]}};
                selected_descriptor[portno] |= entry_q[slot] &
                    {$bits(lsu_descriptor_t){request_select[portno][slot]}};
            end
            mem_request[portno] = '{id:selected_descriptor[portno].id,
                address:selected_descriptor[portno].address, write:selected_descriptor[portno].write,
                size:selected_descriptor[portno].size, wdata:selected_descriptor[portno].wdata,
                wstrb:selected_descriptor[portno].wstrb};
            if ((|request_select[portno]) && (request_locked_q[portno] || (!flush && !recovery.valid))) begin
                if (!request_locked_q[portno] && (|(forwarded & request_select[portno])))
                    forward_fire[portno] = !rst;
                else mem_req_valid[portno] = !rst;
            end
        end
    end

    if (COMPLETION_PORTS == ENTRIES) begin : g_slot_completion
        // 每个完成口固定对应物理槽，DONE 内容保持到接纳或取消。
        // 中央仲裁直接选择全部候选，去掉本地先选两项再中央重选的串行路径。
        for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_result
            assign complete_valid[slot] = !rst && done_candidates[slot];
            assign completion[slot] = slot_completion[slot];
            assign completed_slots[slot] = result_fire[slot];
        end
    end else begin : g_pair_completion
        logic [ENTRIES-1:0] candidates, select [2], preceding [ENTRIES];
        logic [1:0] locked_q;
        logic [IDX_W-1:0] owner_q [2], selected_slot [2];
        // 兼容独立双完成口使用者：只锁定受反压的 owner，新到达的老完成
        // 不能覆盖已展示的包。取消后释放该 owner，外部访存响应仍照常排空。
        always_comb begin
            candidates = done_candidates;
            for (int portno = 0; portno < 2; portno++)
                if (locked_q[portno]) candidates[owner_q[portno]] = 0;
        end
        for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_rank
            assign preceding[slot] = older[slot] & candidates;
            assign select[0][slot] = locked_q[0] ? owner_q[0] == IDX_W'(slot) :
                candidates[slot] && !(|preceding[slot]);
            assign select[1][slot] = locked_q[1] ? owner_q[1] == IDX_W'(slot) :
                candidates[slot] && !select[0][slot] && !(|(preceding[slot] & ~select[0]));
            assign completed_slots[slot] =
                (result_fire[0] && select[0][slot]) || (result_fire[1] && select[1][slot]);
        end
        always_comb begin
            complete_valid = '0;
            for (int portno = 0; portno < 2; portno++) begin
                selected_slot[portno] = '0; completion[portno] = '0;
                complete_valid[portno] = !rst && (|(select[portno] & valid_q & ~killed_q));
                for (int slot = 0; slot < ENTRIES; slot++) begin
                    selected_slot[portno] |= IDX_W'(slot) & {IDX_W{select[portno][slot]}};
                    completion[portno] |= slot_completion[slot] &
                        {$bits(retire_completion_t){select[portno][slot]}};
                end
            end
        end
        always_ff @(posedge clk) begin
            if (rst) locked_q <= '0;
            else begin
                for (int portno = 0; portno < 2; portno++) begin
                    locked_q[portno] <= complete_valid[portno] && !complete_ready[portno] &&
                        !kill_now[selected_slot[portno]];
                    if (complete_valid[portno] && !complete_ready[portno])
                        owner_q[portno] <= selected_slot[portno];
                end
            end
        end
    end
    // 同口合法返回优先于 Store 转发；错误/旧响应不能遮住同拍合法转发。
    for (genvar portno = 0; portno < 2; portno++) begin : g_early_forward
        always_comb begin
            forwarded_data[portno] = '0;
            for (int slot = 0; slot < LQ; slot++)
                forwarded_data[portno] |= formatted_forward[slot] & {XLEN{request_select[portno][slot]}};
            // 无有效提示时保留载荷，forward_fire 只决定是否允许捕获。
            early_forward[portno] = '{valid:forward_fire[portno], id:selected_descriptor[portno].id,
                data:forwarded_data[portno]};
            if (response_forward[portno].valid) early_forward[portno] = response_forward[portno];
        end
    end
    // 请求包在外部反压期间锁定到原物理槽；取消读仍按原协议接受并排空。
    always_ff @(posedge clk) begin
        if (rst) request_locked_q <= '0;
        else begin
            for (int portno = 0; portno < 2; portno++) begin
                request_locked_q[portno] <= mem_req_valid[portno] && !mem_req_ready[portno];
                if (mem_req_valid[portno] && !mem_req_ready[portno])
                    request_owner_q[portno] <= selected[portno];
            end
        end
    end
`ifndef SYNTHESIS
    initial assert (LQ >= 2 && SQ >= 2) else $fatal(1, "dual LSU requires at least two slots of each kind");
    initial assert (COMPLETION_PORTS == 2 || COMPLETION_PORTS == ENTRIES)
        else $fatal(1, "LSQ completion ports must be two or one per physical slot");
    always_ff @(posedge clk) if (!rst) begin
        assert ((issue_fire & ~issue_ready) == 0 && (issue_fire & ~offer_valid) == 0)
            else $fatal(1, "LSQ issued without capacity or valid descriptor");
        assert (!(|issue_fire) || (!flush && !recovery.valid)) else $fatal(1, "LSQ issue during recovery");
        assert (!mem_req_valid[1] || !mem_request[1].write) else $fatal(1, "Store external ordering port");
        for (int portno = 0; portno < 2; portno++) begin
            if (mem_req_valid[portno] &&
                (mem_request[portno].write || !speculative_ram(mem_request[portno].address)))
                assert (head_valid && head_id == mem_request[portno].id && !flush)
                    else $fatal(1, "Store/MMIO without head permission");
        end
    end
`endif
endmodule
