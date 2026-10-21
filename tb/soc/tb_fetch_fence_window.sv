// Module: tb_fetch_fence_window
// Description: Connected pair-fetch/FENCE.I boundary checks using real caches and a shared AXI block backend.
module tb_fetch_fence_window #(
    parameter int unsigned LINE_BYTES = 64
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    import cache_pkg::*;
    localparam int BYTES = 4096;
    localparam xlen_t BASE = xlen_t'(soc_addr_pkg::DDR_BASE);
    localparam xlen_t OLD_PC = BASE + xlen_t'(128);
    localparam xlen_t NEW_PC = BASE + xlen_t'(1024);
    localparam logic [31:0] NEW_LOW = 32'h01a00513, NEW_HIGH = 32'h02b00593;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic fetch_request_enable = 0, flush = 0, fence_i_commit = 0;
    redirect_t redirect = '0;
    pred_info_t prediction = '0, prediction_1 = '0;
    xlen_t lookup_pc, lookup_pc_1, pair_addr, word_addr;
    if_d1_t out_packet, out_packet_1;
    logic [1:0] pop_count = 0;
    logic fetch_fire, fetch_second, busy;
    logic pair_req_valid, pair_req_ready, adapter_req_ready;
    logic pair_rsp_valid, pair_rsp_ready, pair_error, pair_error_1;
    logic [63:0] pair_data;
    logic word_req_valid, word_req_ready, word_rsp_valid, word_rsp_ready, word_error;
    logic icache_req_ready;
    logic [31:0] word_data;
    logic [$clog2(DBUS_BYTES)-1:0] fetch_lane_q;
    bus_req_t fetch_request, data_request = '0;
    bus_rsp_t fetch_response, data_response;
    logic data_req_valid = 0, data_req_ready, data_rsp_valid, data_rsp_ready = 0;
    logic [1:0] legacy_req_valid, legacy_req_ready, legacy_rsp_valid, legacy_rsp_ready;
    bus_req_t legacy_request [2];
    bus_rsp_t legacy_response [2];
    logic command_ready, maint_busy, fetch_block, fatal;
    cache_maint_error_e controller_error, maint_error, cache_fault_code;
    xlen_t controller_fault_addr, maint_fault_addr, cache_fault_addr;
    logic maint_req_valid, maint_req_ready, maint_rsp_valid, maint_rsp_ready, cache_fault_valid;
    cache_maint_op_e maint_op;
    logic [1:0] cache_rd_cmd_valid, cache_rd_cmd_ready, cache_rd_valid, cache_rd_ready;
    logic [1:0] cache_wr_cmd_valid, cache_wr_cmd_ready, cache_wr_valid, cache_wr_ready;
    logic [1:0] cache_wr_rsp_valid, cache_wr_rsp_ready;
    block_cmd_t cache_rd_cmd [2], cache_wr_cmd [2];
    block_r_t cache_rd_data [2];
    block_w_t cache_wr_data [2];
    block_b_t cache_wr_rsp [2];
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic awvalid, awready, awid, awlock, wvalid, wready, wlast, bvalid, bready, bid;
    logic arvalid, arready, arid, arlock, rvalid, rready, rid, rlast;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize, awprot, arprot;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic [3:0] awcache, awqos, awregion, arcache, arqos, arregion;
    logic [255:0] wdata, rdata;
    logic [31:0] wstrb;
    logic [31:0] fault_read_addr = '1, fault_write_addr = '1;

    // FENCE.I由连接级TB注入，不冒充Core执行/退休。门控与soc_top一致，只阻止新请求。
    fetch_pair_stage u_fetch (
        .clk, .rst, .fetch_request_enable, .flush, .redirect, .prediction, .prediction_1,
        .lookup_pc, .lookup_pc_1, .fetch_fire, .fetch_second, .out_packet, .out_packet_1,
        .pop_count, .imem_req_valid(pair_req_valid), .imem_req_addr(pair_addr),
        .imem_req_ready(pair_req_ready), .imem_rsp_valid(pair_rsp_valid),
        .imem_rsp_data(pair_data), .imem_rsp_error(pair_error), .imem_rsp_error_1(pair_error_1),
        .imem_rsp_ready(pair_rsp_ready), .busy
    );
    fetch_width_adapter #(.DATA_W(64)) u_adapter (
        .clk, .rst, .s_req_valid(pair_req_valid && !fetch_block), .s_req_ready(adapter_req_ready),
        .s_req_addr(pair_addr), .s_rsp_valid(pair_rsp_valid), .s_rsp_ready(pair_rsp_ready),
        .s_rsp_data(pair_data), .s_rsp_error(pair_error), .s_rsp_error_1(pair_error_1),
        .m_req_valid(word_req_valid), .m_req_ready(word_req_ready), .m_req_addr(word_addr),
        .m_rsp_valid(word_rsp_valid), .m_rsp_ready(word_rsp_ready), .m_rsp_data(word_data),
        .m_rsp_error(word_error)
    );
    assign pair_req_ready = adapter_req_ready && !fetch_block;
    assign word_req_ready = icache_req_ready && !fetch_block;
    assign fetch_request = '{write:1'b0, execute:1'b1, size:MEM_WORD, addr:word_addr, wdata:'0, wstrb:'0};
    assign word_data = 32'(fetch_response.rdata >> (8 * fetch_lane_q));
    assign word_error = fetch_response.error != BUS_OK;
    always_ff @(posedge clk) begin
        if (rst) fetch_lane_q <= '0;
        else if (word_req_valid && word_req_ready) fetch_lane_q <= word_addr[$clog2(DBUS_BYTES)-1:0];
    end
    icache #(.CACHE_BYTES(4*LINE_BYTES), .LINE_BYTES(LINE_BYTES), .DDR_BYTES(BYTES), .BLOCK_ENABLE(1)) u_icache (
        .clk, .rst, .invalidate(fence_i_commit), .req_valid(word_req_valid && !fetch_block),
        .req_ready(icache_req_ready), .request(fetch_request), .rsp_valid(word_rsp_valid),
        .rsp_ready(word_rsp_ready), .response(fetch_response),
        .mem_req_valid(legacy_req_valid[0]), .mem_req_ready(legacy_req_ready[0]), .mem_request(legacy_request[0]),
        .mem_rsp_valid(legacy_rsp_valid[0]), .mem_rsp_ready(legacy_rsp_ready[0]), .mem_response(legacy_response[0]),
        .rd_cmd_valid(cache_rd_cmd_valid[0]), .rd_cmd_ready(cache_rd_cmd_ready[0]), .rd_cmd(cache_rd_cmd[0]),
        .rd_valid(cache_rd_valid[0]), .rd_ready(cache_rd_ready[0]), .rd_data(cache_rd_data[0])
    );
    assign cache_wr_cmd_valid[0] = 0;
    assign cache_wr_cmd[0] = '0;
    assign cache_wr_valid[0] = 0;
    assign cache_wr_data[0] = '0;
    assign cache_wr_rsp_ready[0] = 0;
    cache_maintenance_controller u_maintenance (
        .clk, .rst, .fence_i_commit, .command_valid(1'b0), .command_ready, .command(CACHE_NONE),
        .busy(maint_busy), .fetch_block, .fatal, .error(controller_error), .fault_addr(controller_fault_addr),
        .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready,
        .maint_error, .maint_fault_addr, .cache_fault_valid, .cache_fault_code, .cache_fault_addr
    );
    dcache #(.CACHE_BYTES(4*LINE_BYTES), .LINE_BYTES(LINE_BYTES), .DDR_BYTES(BYTES), .BLOCK_ENABLE(1)) u_dcache (
        .clk, .rst, .req_valid(data_req_valid), .req_ready(data_req_ready), .request(data_request),
        .rsp_valid(data_rsp_valid), .rsp_ready(data_rsp_ready), .response(data_response),
        .maint_req_valid, .maint_req_ready, .maint_op, .maint_rsp_valid, .maint_rsp_ready,
        .maint_error, .maint_fault_addr, .fault_valid(cache_fault_valid),
        .fault_code(cache_fault_code), .fault_addr(cache_fault_addr),
        .mem_req_valid(legacy_req_valid[1]), .mem_req_ready(legacy_req_ready[1]), .mem_request(legacy_request[1]),
        .mem_rsp_valid(legacy_rsp_valid[1]), .mem_rsp_ready(legacy_rsp_ready[1]), .mem_response(legacy_response[1]),
        .rd_cmd_valid(cache_rd_cmd_valid[1]), .rd_cmd_ready(cache_rd_cmd_ready[1]), .rd_cmd(cache_rd_cmd[1]),
        .rd_valid(cache_rd_valid[1]), .rd_ready(cache_rd_ready[1]), .rd_data(cache_rd_data[1]),
        .wr_cmd_valid(cache_wr_cmd_valid[1]), .wr_cmd_ready(cache_wr_cmd_ready[1]), .wr_cmd(cache_wr_cmd[1]),
        .wr_valid(cache_wr_valid[1]), .wr_ready(cache_wr_ready[1]), .wr_data(cache_wr_data[1]),
        .wr_rsp_valid(cache_wr_rsp_valid[1]), .wr_rsp_ready(cache_wr_rsp_ready[1]), .wr_rsp(cache_wr_rsp[1])
    );
    // 本专项只使用合法DDR缓存行，不注入fallback；若意外走标量口，断言立即失败而非悬空假通过。
    assign legacy_req_ready = '0;
    assign legacy_rsp_valid = '0;
    assign legacy_response[0] = '0;
    assign legacy_response[1] = '0;
    ddr_block_fabric #(.DDR_BYTES(BYTES)) u_fabric (
        .clk, .rst, .cpu_req_valid(1'b0), .cpu_req_ready(), .cpu_request('0),
        .cpu_rsp_valid(), .cpu_rsp_ready(1'b1), .cpu_response(),
        .dma_req_valid(1'b0), .dma_req_ready(), .dma_request('0),
        .dma_rsp_valid(), .dma_rsp_ready(1'b1), .dma_response(),
        .cache_rd_cmd_valid, .cache_rd_cmd_ready, .cache_rd_cmd, .cache_rd_valid, .cache_rd_ready, .cache_rd_data,
        .cache_wr_cmd_valid, .cache_wr_cmd_ready, .cache_wr_cmd, .cache_wr_valid, .cache_wr_ready, .cache_wr_data,
        .cache_wr_rsp_valid, .cache_wr_rsp_ready, .cache_wr_rsp,
        .dma_block_rd_cmd_valid(1'b0), .dma_block_rd_cmd_ready(), .dma_block_rd_cmd('0),
        .dma_block_rd_valid(), .dma_block_rd_ready(1'b0), .dma_block_rd_data(),
        .dma_block_wr_cmd_valid(1'b0), .dma_block_wr_cmd_ready(), .dma_block_wr_cmd('0),
        .dma_block_wr_valid(1'b0), .dma_block_wr_ready(), .dma_block_wr_data('0),
        .dma_block_wr_rsp_valid(), .dma_block_wr_rsp_ready(1'b0), .dma_block_wr_rsp(),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data,
        .wr_cmd_valid, .wr_cmd_ready, .wr_cmd, .wr_valid, .wr_ready, .wr_data,
        .wr_rsp_valid, .wr_rsp_ready, .wr_rsp
    );
    block_to_axi #(.DDR_BYTES(BYTES)) u_bridge (.*);
    axi_block_memory_model #(.BYTES(BYTES)) memory (
        .clk, .rst, .fault_read_addr, .fault_write_addr, .awvalid, .awready, .awid, .awaddr, .awlen, .awsize,
        .wvalid, .wready, .wdata, .wstrb, .wlast, .bvalid, .bready, .bid, .bresp,
        .arvalid, .arready, .arid, .araddr, .arlen, .arsize,
        .rvalid, .rready, .rid, .rdata, .rresp, .rlast
    );

    function automatic logic [31:0] original_word(input int offset);
        return 32'h00000013 | (32'((offset / 4) & 255) << 20);
    endfunction
    function automatic logic [31:0] expected_word(input xlen_t addr);
        if (addr == NEW_PC) return NEW_LOW;
        if (addr == NEW_PC + xlen_t'(4)) return NEW_HIGH;
        return original_word(int'(addr-BASE));
    endfunction
    int pair_accepts, pair_replies, word_accepts, word_replies, clean_requests, clean_replies;
    int write_addresses, blocked_cycles, blocked_old_replies, low_fence_same_edge;
    int child_index;
    xlen_t accepted_pair, accepted_word;
    logic after_kill = 0;
    // 参考只取接口握手，不读DUT state/owner。检查计数不反向驱动任何接口。
    always @(posedge clk) begin
        if (rst) begin
            pair_accepts = 0; pair_replies = 0; word_accepts = 0; word_replies = 0;
            clean_requests = 0; clean_replies = 0; write_addresses = 0;
            blocked_cycles = 0; blocked_old_replies = 0; low_fence_same_edge = 0;
            child_index = 0; accepted_pair = '0; accepted_word = '0;
        end else begin
            assert (legacy_req_valid == 0 && !fatal) else $fatal(1, "Unexpected fallback/fatal");
            if (fetch_block) begin
                blocked_cycles++;
                assert (!pair_req_ready && !word_req_ready) else $fatal(1, "FENCE allowed fetch acceptance");
                if (word_rsp_valid && word_rsp_ready) blocked_old_replies++;
            end
            if (pair_req_valid && pair_req_ready) begin
                assert (pair_accepts == pair_replies) else $fatal(1, "Second pair owner");
                accepted_pair = pair_addr; child_index = 0; pair_accepts++;
            end
            if (word_req_valid && word_req_ready) begin
                assert (word_addr == accepted_pair + xlen_t'(child_index*4) && child_index < 2)
                    else $fatal(1, "Subrequest address/order mismatch");
                accepted_word = word_addr; child_index++; word_accepts++;
            end
            if (word_rsp_valid && word_rsp_ready) begin
                assert (word_data == expected_word(accepted_word) && !word_error)
                    else $fatal(1, "Wrong word/lane addr=%h data=%h", accepted_word, word_data);
                if (fence_i_commit && word_replies == 0) low_fence_same_edge++;
                word_replies++;
            end
            if (pair_rsp_valid && pair_rsp_ready) begin
                assert (child_index == 2 && !pair_error && !pair_error_1 &&
                        pair_data == {expected_word(accepted_pair+xlen_t'(4)), expected_word(accepted_pair)})
                    else $fatal(1, "Pair owner/data corrupted during FENCE");
                pair_replies++;
            end
            if (maint_req_valid && maint_req_ready) begin
                assert (maint_op == CACHE_CLEAN) else $fatal(1, "FENCE did not request CLEAN");
                clean_requests++;
            end
            if (maint_rsp_valid && maint_rsp_ready) begin
                assert (maint_error == CACHE_OK) else $fatal(1, "CLEAN failed");
                clean_replies++;
            end
            if (awvalid && awready) begin
                assert (awaddr == 32'(NEW_PC) && awlen == 8'(LINE_BYTES/32-1) && awsize == 5)
                    else $fatal(1, "CLEAN did not use expected real AXI line");
                write_addresses++;
            end
            if (after_kill && out_packet.valid)
                assert (out_packet.pc == NEW_PC && out_packet.inst == NEW_LOW &&
                        out_packet_1.valid && out_packet_1.pc == NEW_PC+xlen_t'(4) && out_packet_1.inst == NEW_HIGH)
                    else $fatal(1, "Killed old pair escaped or refetch code stale");
        end
    end

    task automatic store_instruction(input xlen_t addr, input logic [31:0] instruction);
        @(negedge clk);
        data_request = '{write:1'b1, execute:1'b0, size:MEM_WORD, addr:addr,
            wdata:xlen_t'(instruction) << (8*int'(addr[$clog2(DBUS_BYTES)-1:0])),
            wstrb:DBUS_BYTES'(15) << int'(addr[$clog2(DBUS_BYTES)-1:0])};
        data_req_valid = 1;
        do @(posedge clk); while (!data_req_ready);
        @(negedge clk); data_req_valid = 0;
        while (!data_rsp_valid) @(negedge clk);
        assert (data_response.error == BUS_OK) else $fatal(1, "Code store failed");
        data_rsp_ready = 1;
        @(negedge clk); data_rsp_ready = 0;
    endtask
    task automatic reset_case;
        @(negedge clk);
        rst = 1; fetch_request_enable = 0; redirect = '0; pop_count = 0;
        fence_i_commit = 0; after_kill = 0; data_req_valid = 0; data_rsp_ready = 0;
        repeat (3) @(negedge clk);
        for (int offset = 0; offset < BYTES; offset += 4)
            for (int b = 0; b < 4; b++)
                memory.mem[(offset+b)/DBUS_BYTES][8*((offset+b)%DBUS_BYTES)+:8] = 8'(original_word(offset) >> (8*b));
        rst = 0;
        store_instruction(NEW_PC, NEW_LOW);
        store_instruction(NEW_PC+xlen_t'(4), NEW_HIGH);
        assert (write_addresses == 0 &&
                32'(memory.mem[1024/DBUS_BYTES]) == original_word(1024))
            else $fatal(1, "Preparation bypassed dirty D-cache");
        @(negedge clk); redirect.valid = 1; redirect.pc = OLD_PC;
        @(negedge clk); redirect = '0; fetch_request_enable = 1;
    endtask
    int phases = 0, full_hold_cycles = 0;
    int old_pairs, old_replies, wait_cycles;
    initial begin
        assert (ISSUE_WIDTH == 2) else $fatal(1, "Test requires actual pair-fetch configuration");
        for (int phase = 0; phase < 4; phase++) begin
            reset_case();
            unique case (phase)
                0: while (!(word_rsp_valid && word_rsp_ready && word_replies == 0)) @(negedge clk);
                1: while (!(word_replies == 1 && word_accepts == 1 && word_req_valid)) @(negedge clk);
                2: while (!(word_accepts == 2 && word_replies == 1)) @(negedge clk);
                3: begin
                    while (!(pair_rsp_valid && !pair_rsp_ready)) @(negedge clk);
                    assert (pair_replies == FETCH_QUEUE_DEPTH/2 && pair_accepts == pair_replies+1)
                        else $fatal(1, "Pair backpressure did not originate from real full fetch queue");
                    repeat (3) begin
                        @(negedge clk);
                        assert (pair_rsp_valid && !pair_rsp_ready) else $fatal(1, "Pair response not held");
                        full_hold_cycles++;
                    end
                end
                default: $fatal(1, "Unknown phase");
            endcase
            old_pairs = pair_accepts;
            old_replies = word_replies;
            fetch_request_enable = 0;
            fence_i_commit = 1; redirect.valid = 1; redirect.pc = NEW_PC; after_kill = 1;
            @(negedge clk);
            fence_i_commit = 0; redirect = '0;
            assert (!out_packet.valid && !out_packet_1.valid) else $fatal(1, "Redirect did not flush fetch queue");
            if (phase == 0) assert (low_fence_same_edge == 1) else $fatal(1, "Missing low-response/FENCE coincidence");
            if (phase == 0 || phase == 1) begin
                // 高子请求仍等待，而真实D$维护可以独立结束；不能等待旧整包而形成互等。
                while (clean_replies == 0) begin
                    assert (word_accepts == 1 && pair_replies == 0)
                        else $fatal(1, "High subrequest passed active FENCE or old pair completed early");
                    @(negedge clk);
                end
                assert (word_req_valid) else $fatal(1, "Pending high request was lost");
            end
            wait_cycles = 0;
            while (maint_busy || fetch_block || pair_replies != old_pairs) begin
                @(negedge clk); wait_cycles++;
                assert (wait_cycles < 3000) else $fatal(1, "Maintenance/old pair drain deadlocked");
            end
            assert (clean_requests == 1 && clean_replies == 1 && write_addresses == 1 && blocked_cycles > 0 &&
                    word_accepts == 2*old_pairs && word_replies == 2*old_pairs && pair_accepts == old_pairs)
                else $fatal(1, "Missing independent clean/drain or duplicate request");
            if (phase == 2) assert (blocked_old_replies > 0 && old_replies == 1)
                else $fatal(1, "High accepted response failed to drain while blocked");
            for (int b = 0; b < 8; b++)
                assert (memory.mem[(1024+b)/DBUS_BYTES][8*((1024+b)%DBUS_BYTES)+:8] ==
                    8'((b < 4 ? NEW_LOW : NEW_HIGH) >> (8*(b%4))))
                    else $fatal(1, "CLEAN did not publish new instruction bytes");
            assert (!out_packet.valid) else $fatal(1, "Killed pair was enqueued");
            fetch_request_enable = 1;
            while (pair_accepts == old_pairs) @(negedge clk);
            fetch_request_enable = 0;
            while (!out_packet.valid) @(negedge clk);
            assert (out_packet.pc == NEW_PC && out_packet.inst == NEW_LOW && out_packet_1.valid &&
                    out_packet_1.pc == NEW_PC+xlen_t'(4) && out_packet_1.inst == NEW_HIGH)
                else $fatal(1, "New PC refetch failed");
            phases++;
            $display("PHASE %0d PASS pair_owners=%0d old_word_replies=%0d clean=%0d blocked=%0d old_rsp_during_block=%0d",
                phase, old_pairs, 2*old_pairs, clean_replies, blocked_cycles, blocked_old_replies);
        end
        assert (phases == 4 && full_hold_cycles == 3) else $fatal(1, "Phase coverage incomplete");
        $display("PASS tb_fetch_fence_window RV%0d line=%0d phases=4 skips=0 injection=connection-level pair_queue=real backend=AXI", XLEN, LINE_BYTES);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Fetch/FENCE window timeout");
    end
endmodule
