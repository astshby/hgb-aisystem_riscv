// Module: load_queue
// Description: Owns Load allocation, Store forwarding, request state, tagged responses and completion slots.
module load_queue (
    input logic clk, rst, flush,
    input scoreboard_pkg::branch_recovery_t recovery,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input scoreboard_pkg::lsu_age_matrix_t age_order,
    input logic head_valid,
    input pipeline_pkg::retire_id_t head_id,
    input logic [1:0] offer_valid, issue_fire,
    input pipeline_pkg::lsu_descriptor_t descriptor [2],
    output logic [1:0] issue_ready,
    input logic [1:0] admission_request_fire,
    output logic [$clog2(core_config_pkg::LOAD_QUEUE_ENTRIES)-1:0] allocation_slot [2],
    input scoreboard_pkg::lsu_entry_view_t stores [core_config_pkg::STORE_QUEUE_ENTRIES],
    output scoreboard_pkg::lsu_entry_view_t view [core_config_pkg::LOAD_QUEUE_ENTRIES],
    output logic [core_config_pkg::LOAD_QUEUE_ENTRIES-1:0] eligible, forwarded, done, kill_now,
    output core_types_pkg::xlen_t forwarded_data [core_config_pkg::LOAD_QUEUE_ENTRIES],
    input logic [core_config_pkg::LOAD_QUEUE_ENTRIES-1:0] presented, request_fire, forward_fire, complete_ready,
    input logic [1:0] response_valid,
    input scoreboard_pkg::memory_response_t response [2],
    output logic [1:0] response_match, response_reject,
    output pipeline_pkg::retire_gpr_forward_t response_forward [2],
    output pipeline_pkg::retire_completion_t completion [core_config_pkg::LOAD_QUEUE_ENTRIES],
    output logic busy, draining
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    localparam int LQ = LOAD_QUEUE_ENTRIES;
    localparam int SQ = STORE_QUEUE_ENTRIES;
    typedef enum logic [1:0] {QUEUED, WAIT_RESPONSE, DONE} state_e;
    logic [LQ-1:0] valid_q, killed_q, available;
    state_e state_q [LQ];
    lsu_descriptor_t descriptor_q [LQ];
    retire_result_t result_q [LQ];
    integer alloc_slot [2], response_slot [2];
    logic [DBUS_BYTES-1:0] read_mask [LQ], covered [LQ];
    logic [SQ-1:0] forward_candidates [LQ][DBUS_BYTES], forward_select [LQ][DBUS_BYTES];
    logic [SQ-1:0] newer [SQ];
    logic older_ordered [LQ], partial_overlap [LQ];
    xlen_t forwarded_word [LQ], returned_data [2];
    lsu_descriptor_t response_descriptor [2];

    function automatic logic [DBUS_BYTES-1:0] access_mask(input lsu_descriptor_t item);
        logic [DBUS_BYTES-1:0] mask;
        unique case (item.size)
            MEM_BYTE: mask = DBUS_BYTES'(1);
            MEM_HALF: mask = DBUS_BYTES'(3);
            MEM_WORD: mask = DBUS_BYTES'(15);
            default: mask = '1;
        endcase
        return mask << item.address[$clog2(DBUS_BYTES)-1:0];
    endfunction
    assign busy = |valid_q;
    assign draining = |(valid_q & killed_q);
    // 未知地址的老 Store 尚在顺序 IQ 队首，消费者不能越过它进入 LQ。
    // 两条分配只竞争 LQ 空槽；Store 的 offer 不消耗 LQ 容量。
    always_comb begin
        available = ~valid_q;
        issue_ready = '0;
        for (int lane = 0; lane < 2; lane++) begin
            alloc_slot[lane] = -1;
            for (int slot = 0; slot < LQ; slot++)
                if (available[slot] && alloc_slot[lane] < 0) alloc_slot[lane] = slot;
            if (!descriptor[lane].write && alloc_slot[lane] >= 0 && !rst && !flush && !recovery.valid) begin
                issue_ready[lane] = 1;
                if (offer_valid[lane]) available[alloc_slot[lane]] = 0;
            end
        end
    end
    for (genvar lane = 0; lane < 2; lane++) begin : g_allocation_view
        assign allocation_slot[lane] = $clog2(LQ)'(alloc_slot[lane]);
    end
    for (genvar slot = 0; slot < LQ; slot++) begin : g_slot
        assign view[slot] = '{valid:valid_q[slot], killed:killed_q[slot], descriptor:descriptor_q[slot]};
        assign kill_now[slot] = valid_q[slot] && (flush ||
            (recovery.valid && younger_than(descriptor_q[slot].id, recovery.id, head_slot)));
        assign done[slot] = valid_q[slot] && !killed_q[slot] && state_q[slot] == DONE;
        assign completion[slot] = '{id:descriptor_q[slot].id, result:result_q[slot]};
        for (genvar byte_no = 0; byte_no < DBUS_BYTES; byte_no++) begin : g_forward_byte
            for (genvar store = 0; store < SQ; store++) begin : g_store
                assign forward_candidates[slot][byte_no][store] = stores[store].valid && !stores[store].killed &&
                    age_order[slot][LQ+store] &&
                    (stores[store].descriptor.address >> $clog2(DBUS_BYTES)) ==
                    (descriptor_q[slot].address >> $clog2(DBUS_BYTES)) && stores[store].descriptor.wstrb[byte_no];
                assign forward_select[slot][byte_no][store] = forward_candidates[slot][byte_no][store] &&
                    !(|(forward_candidates[slot][byte_no] & newer[store]));
            end
        end
        // 各 Load 槽按寄存地址/类型并行格式化，晚到的请求选择只经过结果多路器。
        load_unit u_format (.bus_data(forwarded_word[slot]), .address(descriptor_q[slot].address),
            .size(descriptor_q[slot].size), .unsigned_load(descriptor_q[slot].unsigned_load),
            .load_data(forwarded_data[slot]));
    end
    for (genvar store = 0; store < SQ; store++) begin : g_age
        for (genvar other = 0; other < SQ; other++) begin : g_compare
            assign newer[store][other] = age_order[LQ+other][LQ+store];
        end
    end
    // Load 逐字节选择最新的更老 Store。部分覆盖时等待 Store 成功，不能混入旧 RAM 字节。
    always_comb begin
        eligible = '0;
        forwarded = '0;
        for (int slot = 0; slot < LQ; slot++) begin
            read_mask[slot] = access_mask(descriptor_q[slot]);
            covered[slot] = '0;
            forwarded_word[slot] = '0;
            older_ordered[slot] = 0;
            for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++) begin
                covered[slot][byte_no] = |forward_candidates[slot][byte_no];
                for (int store = 0; store < SQ; store++)
                    forwarded_word[slot][8*byte_no +: 8] |= stores[store].descriptor.wdata[8*byte_no +: 8] &
                        {8{forward_select[slot][byte_no][store]}};
            end
            for (int prior = 0; prior < LQ; prior++)
                if (valid_q[prior] && !killed_q[prior] &&
                    age_order[slot][prior] &&
                    !speculative_ram(descriptor_q[prior].address)) older_ordered[slot] = 1;
            for (int prior = 0; prior < SQ; prior++)
                if (stores[prior].valid && !stores[prior].killed &&
                    age_order[slot][LQ+prior] &&
                    !speculative_ram(stores[prior].descriptor.address)) older_ordered[slot] = 1;
            partial_overlap[slot] = |(covered[slot] & read_mask[slot]);
            forwarded[slot] = partial_overlap[slot] && (covered[slot] & read_mask[slot]) == read_mask[slot] &&
                speculative_ram(descriptor_q[slot].address);
            if (valid_q[slot] && !killed_q[slot] && state_q[slot] == QUEUED && !older_ordered[slot]) begin
                if (!speculative_ram(descriptor_q[slot].address))
                    eligible[slot] = head_valid && head_id == descriptor_q[slot].id;
                else eligible[slot] = !partial_overlap[slot] || forwarded[slot];
            end
        end
    end
    // 两个返回口按完整标签查找，允许跨口乱序返回；错误或取消的响应不提供提前转发。
    always_comb begin
        response_match = '0;
        response_reject = '0;
        for (int portno = 0; portno < 2; portno++) begin
            response_slot[portno] = -1;
            response_descriptor[portno] = '0;
            for (int slot = 0; slot < LQ; slot++)
                if (valid_q[slot] && state_q[slot] == WAIT_RESPONSE &&
                    descriptor_q[slot].id == response[portno].id) response_slot[portno] = slot;
            if (response_slot[portno] >= 0) begin
                response_match[portno] = 1;
                response_descriptor[portno] = descriptor_q[response_slot[portno]];
                response_reject[portno] = response_valid[portno] &&
                    (killed_q[response_slot[portno]] || kill_now[response_slot[portno]]);
            end
        end
    end
    for (genvar portno = 0; portno < 2; portno++) begin : g_return
        load_unit u_format (.bus_data(response[portno].data), .address(response_descriptor[portno].address),
            .size(response_descriptor[portno].size), .unsigned_load(response_descriptor[portno].unsigned_load),
            .load_data(returned_data[portno]));
        assign response_forward[portno] = '{valid:response_valid[portno] && response_match[portno] &&
            !response_reject[portno] && !response[portno].error, id:response[portno].id, data:returned_data[portno]};
    end
    // LQ 独占描述符、请求状态和完成数据；已展示的取消读保持 valid，接受后排空返回。
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= '0;
            killed_q <= '0;
        end else begin
            for (int slot = 0; slot < LQ; slot++) begin
                if (request_fire[slot]) state_q[slot] <= WAIT_RESPONSE;
                if (forward_fire[slot]) begin
                    state_q[slot] <= DONE;
                    result_q[slot] <= '0;
                    result_q[slot].gpr_data <= forwarded_data[slot];
                end
                for (int portno = 0; portno < 2; portno++) begin
                    if (response_valid[portno] && response_slot[portno] == slot) begin
                        if (killed_q[slot] || kill_now[slot]) valid_q[slot] <= 0;
                        else begin
                            state_q[slot] <= DONE;
                            result_q[slot] <= '0;
                            result_q[slot].gpr_data <= returned_data[portno];
                            if (response[portno].error) begin
                                result_q[slot].exc.valid <= 1;
                                result_q[slot].exc.cause <= EXC_LOAD_ACCESS_FAULT;
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
                    if (issue_fire[lane] && !descriptor[lane].write && alloc_slot[lane] == slot) begin
                        valid_q[slot] <= 1;
                        killed_q[slot] <= 0;
                        // 预发与分配同沿接纳时直接等待返回，未接纳则由此槽继续持有请求。
                        state_q[slot] <= admission_request_fire[lane] ? WAIT_RESPONSE : QUEUED;
                        descriptor_q[slot] <= descriptor[lane];
                        descriptor_q[slot].write <= 0;
                        descriptor_q[slot].wdata <= 0;
                        descriptor_q[slot].wstrb <= 0;
                    end
                end
            end
        end
    end
endmodule
