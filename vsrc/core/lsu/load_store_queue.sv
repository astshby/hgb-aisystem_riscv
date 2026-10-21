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
    import riscv_priv_pkg::*;
    localparam int LQ = LOAD_QUEUE_ENTRIES;
    localparam int SQ = STORE_QUEUE_ENTRIES;
    localparam int ENTRIES = LQ + SQ;
    localparam int IDX_W = $clog2(ENTRIES);
    typedef enum logic [1:0] {QUEUED, WAIT_RESPONSE, DONE} state_e;
    logic [ENTRIES-1:0] valid_q, killed_q, kill_now, eligible, forwarded, done_candidates;
    lsu_descriptor_t descriptor_q [ENTRIES], entry_q [ENTRIES];
    state_e state_q [ENTRIES];
    retire_result_t result_q [ENTRIES];
    logic [ENTRIES-1:0] wrapped;
    logic [DBUS_BYTES-1:0] read_mask [ENTRIES], covered [ENTRIES];
    xlen_t forwarded_word [ENTRIES];
    xlen_t formatted_forward [LQ];
    logic [ENTRIES-1:0] available, request_candidates, completed_slots;
    logic [ENTRIES-1:0] older [ENTRIES], newer [ENTRIES], strictly_older [ENTRIES];
    logic [ENTRIES-1:0] request_select [2];
    logic [ENTRIES-1:0] request_first, request_second, load_candidates;
    logic [ENTRIES-1:0] request_preceding [ENTRIES], load_preceding [ENTRIES];
    logic [ENTRIES-1:0] forward_candidates [ENTRIES][DBUS_BYTES];
    logic [ENTRIES-1:0] forward_select [ENTRIES][DBUS_BYTES];
    logic [1:0] request_locked_q;
    logic [IDX_W-1:0] request_owner_q [2];
    logic [IDX_W-1:0] selected [2];
    integer alloc_slot [2], response_slot [2];
    logic [1:0] request_fire, response_fire, forward_fire;
    logic [COMPLETION_PORTS-1:0] result_fire;
    xlen_t returned_data [2], forwarded_data [2];
    lsu_descriptor_t response_descriptor [2], selected_descriptor [2];
    logic [1:0] response_found;
    logic older_ordered [ENTRIES], partial_overlap [ENTRIES];
    logic store_state_valid;
    retire_id_t store_state_id;

    // 仅无副作用的物理内存允许提前读。其他窗口（含 MMIO 和高位地址）须成为 ROB 队头。
    // 未知地址的老 Store 尚在顺序 IQ 队首，消费者不能越过它进入本 LSQ。
    function automatic logic speculative_ram(input xlen_t address);
        return address < xlen_t'(soc_addr_pkg::MTIME_BASE) ||
               ((address >> 31) == xlen_t'(1));
    endfunction
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
    assign mem_rsp_ready = {2{!rst}};
    assign request_fire = mem_req_valid & mem_req_ready;
    assign result_fire = complete_valid & complete_ready;
    assign store_owner_valid = store_state_valid || (mem_req_valid[0] && mem_request[0].write);
    assign store_owner_id = (mem_req_valid[0] && mem_request[0].write) ? mem_request[0].id : store_state_id;

    // 两条分配分别使用 LQ/SQ 空槽；第二条预留第一条的候选槽，实际更新仍只看 issue_fire。
    always_comb begin
        available = ~valid_q;
        issue_ready = '0;
        for (int lane = 0; lane < 2; lane++) begin
            alloc_slot[lane] = -1;
            for (int slot = 0; slot < ENTRIES; slot++) begin
                if (available[slot] && (descriptor[lane].write == (slot >= LQ)) && alloc_slot[lane] < 0)
                    alloc_slot[lane] = slot;
            end
            if (alloc_slot[lane] >= 0 && !rst && !flush && !recovery.valid) begin
                issue_ready[lane] = 1;
                if (offer_valid[lane]) available[alloc_slot[lane]] = 0;
            end
        end
    end
    for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_age
        // 分配器已保证前 LQ 槽只接收 Load、后 SQ 槽只接收 Store。
        // 类型由物理槽决定，避免综合保留 Store 槽上的 Load 转发/读口候选逻辑。
        always_comb begin
            entry_q[slot] = descriptor_q[slot];
            entry_q[slot].write = slot >= LQ;
        end
        assign wrapped[slot] = entry_q[slot].id.slot < head_slot;
        assign kill_now[slot] = valid_q[slot] && (flush ||
            (recovery.valid && younger_than(entry_q[slot].id, recovery.id, head_slot)));
        for (genvar other = 0; other < ENTRIES; other++) begin : g_compare
            assign strictly_older[slot][other] = (wrapped[other] != wrapped[slot]) ?
                wrapped[slot] : entry_q[other].id.slot < entry_q[slot].id.slot;
            assign older[slot][other] = strictly_older[slot][other] ||
                ((entry_q[other].id.slot == entry_q[slot].id.slot) && other < slot);
            assign newer[slot][other] = (wrapped[other] != wrapped[slot]) ? wrapped[other] :
                ((entry_q[other].id.slot > entry_q[slot].id.slot) ||
                 ((entry_q[other].id.slot == entry_q[slot].id.slot) && other < slot));
        end
        for (genvar byte_no = 0; byte_no < DBUS_BYTES; byte_no++) begin : g_forward_byte
            for (genvar store = 0; store < ENTRIES; store++) begin : g_store
                assign forward_candidates[slot][byte_no][store] = store >= LQ &&
                    valid_q[store] && !killed_q[store] && strictly_older[slot][store] &&
                    (entry_q[store].address >> $clog2(DBUS_BYTES)) ==
                    (entry_q[slot].address >> $clog2(DBUS_BYTES)) &&
                    entry_q[store].wstrb[byte_no];
                assign forward_select[slot][byte_no][store] =
                    forward_candidates[slot][byte_no][store] &&
                    !(|(forward_candidates[slot][byte_no] & newer[store]));
            end
        end
    end

    // Load 逐字节选择最新的更老 Store。部分覆盖时等待 Store 成功，不能混入旧 RAM 字节。
    always_comb begin
        eligible = '0; forwarded = '0; done_candidates = '0;
        store_state_valid = 0; store_state_id = '0;
        for (int slot = 0; slot < ENTRIES; slot++) begin
            read_mask[slot] = access_mask(entry_q[slot]);
            covered[slot] = '0; forwarded_word[slot] = '0;
            older_ordered[slot] = 0; partial_overlap[slot] = 0;
            for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++) begin
                covered[slot][byte_no] = |forward_candidates[slot][byte_no];
                for (int store = LQ; store < ENTRIES; store++)
                    forwarded_word[slot][8*byte_no +: 8] |=
                        entry_q[store].wdata[8*byte_no +: 8] &
                        {8{forward_select[slot][byte_no][store]}};
            end
            for (int prior = 0; prior < ENTRIES; prior++) begin
                if (valid_q[prior] && !killed_q[prior] && strictly_older[slot][prior] &&
                    !speculative_ram(entry_q[prior].address))
                    older_ordered[slot] = 1;
            end
            partial_overlap[slot] = |(covered[slot] & read_mask[slot]);
            forwarded[slot] = partial_overlap[slot] &&
                              (covered[slot] & read_mask[slot]) == read_mask[slot] &&
                              speculative_ram(entry_q[slot].address) && !entry_q[slot].write;
            if (valid_q[slot] && !killed_q[slot]) begin
                done_candidates[slot] = state_q[slot] == DONE;
                if (state_q[slot] == QUEUED && !older_ordered[slot]) begin
                    if (entry_q[slot].write || !speculative_ram(entry_q[slot].address))
                        eligible[slot] = head_valid && head_id == entry_q[slot].id;
                    else eligible[slot] = !partial_overlap[slot] || forwarded[slot];
                end
                // 外部 Store 始终按队头授权，只会有一个已展示/已接受的 Store owner。
                if (entry_q[slot].write && (state_q[slot] != QUEUED ||
                    (request_locked_q[0] && request_owner_q[0] == IDX_W'(slot)))) begin
                    store_state_valid = 1; store_state_id = entry_q[slot].id;
                end
            end
        end
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

    // 两个返回口按完整标签查找，允许跨口乱序返回；重复/失效响应接收并拒绝。
    always_comb begin
        response_found = 0; response_reject = 0; response_fire = mem_rsp_valid & mem_rsp_ready;
        for (int portno = 0; portno < 2; portno++) begin
            response_slot[portno] = -1;
            response_descriptor[portno] = '0;
            for (int slot = 0; slot < ENTRIES; slot++) begin
                if (valid_q[slot] && state_q[slot] == WAIT_RESPONSE && entry_q[slot].id == mem_response[portno].id)
                    response_slot[portno] = slot;
            end
            if (portno == 1 && response_fire[0] && mem_response[0].id == mem_response[1].id)
                response_slot[portno] = -1;
            if (response_slot[portno] >= 0) begin
                response_found[portno] = 1;
                response_descriptor[portno] = entry_q[response_slot[portno]];
            end
            response_reject[portno] = response_fire[portno] &&
                (!response_found[portno] || killed_q[response_slot[portno]] || kill_now[response_slot[portno]]);
        end
    end

    if (COMPLETION_PORTS == ENTRIES) begin : g_slot_completion
        // 每个完成口固定对应物理槽，DONE 内容保持到接纳或取消。
        // 中央仲裁直接选择全部候选，去掉本地先选两项再中央重选的串行路径。
        for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_result
            assign complete_valid[slot] = !rst && done_candidates[slot];
            assign completion[slot] = '{id:entry_q[slot].id, result:result_q[slot]};
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
                    completion[portno] |= retire_completion_t'({entry_q[slot].id, result_q[slot]}) &
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
    // 各 Load 槽按寄存地址/类型并行完成字节选取与扩展，晚到的请求选择只经过结果多路器。
    // 格式化不改变转发资格；完整覆盖、年龄、取消和端口锁定仍由原选择规则决定。
    for (genvar slot = 0; slot < LQ; slot++) begin : g_forward_format
        load_unit u_format (.bus_data(forwarded_word[slot]), .address(entry_q[slot].address),
            .size(entry_q[slot].size), .unsigned_load(entry_q[slot].unsigned_load),
            .load_data(formatted_forward[slot]));
    end
    for (genvar portno = 0; portno < 2; portno++) begin : g_load_format
        always_comb begin
            forwarded_data[portno] = '0;
            for (int slot = 0; slot < LQ; slot++)
                forwarded_data[portno] |= formatted_forward[slot] & {XLEN{request_select[portno][slot]}};
        end
        load_unit u_return (.bus_data(mem_response[portno].data), .address(response_descriptor[portno].address),
            .size(response_descriptor[portno].size), .unsigned_load(response_descriptor[portno].unsigned_load),
            .load_data(returned_data[portno]));
    end

    // 已核对 owner 的返回可提前供依赖者捕获；ROB 完成仍等 result_q、CMP 与中央接纳。
    // 同口返回优先于 Store 转发；未广播的转发值仍经正常完成口交付，不丢失结果。
    for (genvar portno = 0; portno < 2; portno++) begin : g_early_forward
        always_comb begin
            // 无有效提示时载荷无需清零，forward_fire 只决定是否允许捕获。
            // 已验证返回仍优先；错误/旧响应不能遮住同拍合法的 Store 转发。
            early_forward[portno] = '{valid:forward_fire[portno], id:selected_descriptor[portno].id,
                data:forwarded_data[portno]};
            if (response_fire[portno] && response_found[portno] && !response_reject[portno] &&
                !mem_response[portno].error && !response_descriptor[portno].write) begin
                early_forward[portno] = '{valid:1'b1, id:mem_response[portno].id,
                    data:returned_data[portno]};
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_q <= 0; killed_q <= 0; request_locked_q <= 0;
        end else begin
            for (int portno = 0; portno < 2; portno++) begin
                request_locked_q[portno] <= mem_req_valid[portno] && !mem_req_ready[portno];
                if (mem_req_valid[portno] && !mem_req_ready[portno])
                    request_owner_q[portno] <= IDX_W'(selected[portno]);
            end
            for (int slot = 0; slot < ENTRIES; slot++) begin
                for (int portno = 0; portno < 2; portno++) begin
                    if (request_fire[portno] && selected[portno] == slot) state_q[slot] <= WAIT_RESPONSE;
                    if (forward_fire[portno] && selected[portno] == slot) begin
                        state_q[slot] <= DONE;
                        result_q[slot] <= '0;
                        result_q[slot].gpr_data <= forwarded_data[portno];
                    end
                    if (response_fire[portno] && response_slot[portno] == slot) begin
                        if (killed_q[slot] || kill_now[slot]) valid_q[slot] <= 0;
                        else begin
                            state_q[slot] <= DONE;
                            result_q[slot] <= '0;
                            result_q[slot].gpr_data <= entry_q[slot].write ? '0 : returned_data[portno];
                            if (mem_response[portno].error) begin
                                result_q[slot].exc.valid <= 1;
                                result_q[slot].exc.cause <= entry_q[slot].write ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT;
                                result_q[slot].exc.tval <= entry_q[slot].address;
                            end
                        end
                    end
                end
                if (completed_slots[slot]) valid_q[slot] <= 0;
                if (kill_now[slot]) begin
                    killed_q[slot] <= 1;
                    if (state_q[slot] != WAIT_RESPONSE &&
                        !(request_locked_q[0] && request_owner_q[0] == IDX_W'(slot)) &&
                        !(request_locked_q[1] && request_owner_q[1] == IDX_W'(slot)) &&
                        !(request_fire[0] && selected[0] == slot) &&
                        !(request_fire[1] && selected[1] == slot))
                        valid_q[slot] <= 0;
                end
                for (int lane = 0; lane < 2; lane++) begin
                    if (issue_fire[lane] && alloc_slot[lane] == slot) begin
                        valid_q[slot] <= 1; killed_q[slot] <= 0; state_q[slot] <= QUEUED;
                        descriptor_q[slot] <= descriptor[lane];
                    end
                end
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
