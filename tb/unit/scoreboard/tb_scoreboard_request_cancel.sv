// Module: tb_scoreboard_request_cancel
// Description: Checks LSQ ownership while canceled loads remain in registered SoC request queues.
module tb_scoreboard_request_cancel;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, flush;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic head_valid;
    retire_id_t head_id;
    logic [1:0] offer_valid, issue_fire, issue_ready, mem_req_valid, mem_req_ready;
    logic [1:0] mem_rsp_valid, mem_rsp_ready, response_reject, complete_valid, complete_ready;
    lsu_descriptor_t descriptor [2];
    memory_request_t mem_request [2], external_request [2], held [2];
    memory_response_t mem_response [2];
    retire_completion_t completion [2];
    logic [1:0] external_valid, external_ready;
    logic [1:0] queue_input_ready, request_accept_enable;
    logic [1:0] previous_request_stall;
    memory_request_t previous_request [2];
    logic busy, draining, store_owner_valid;
    retire_id_t store_owner_id;
    int accepted, rejected, completed;
    always #5 clk = ~clk;
    load_store_queue u_lsu (
        .clk, .rst, .flush, .recovery, .head_slot, .head_valid, .head_id,
        .offer_valid, .issue_fire, .descriptor, .issue_ready,
        .mem_req_valid, .mem_req_ready, .mem_request, .mem_rsp_valid, .mem_rsp_ready, .mem_response,
        .response_reject, .complete_valid, .complete_ready, .completion, .early_forward(),
        .load_return(), .store_forward_hint(), .store_slot_hint(),
        .busy, .draining, .store_owner_valid, .store_owner_id
    );
    assign mem_req_ready = queue_input_ready & request_accept_enable;
    for (genvar p = 0; p < 2; p++) begin : g_port
        tagged_request_queue u_queue (
            .clk, .rst, .in_valid(mem_req_valid[p] && request_accept_enable[p]), .in_ready(queue_input_ready[p]),
            .in_request(mem_request[p]), .out_valid(external_valid[p]),
            .out_ready(external_ready[p]), .out_request(external_request[p])
        );
    end
    function automatic retire_id_t tag(input int slot, generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic lsu_descriptor_t load(input int slot, generation = 1);
        return '{id:tag(slot,generation), address:xlen_t'(256+slot*8), write:1'b0,
                 size:MEM_WORD, unsigned_load:1'b0, wdata:'0, wstrb:'0};
    endfunction
    task automatic idle;
        flush = 0; recovery = '0; offer_valid = 0; issue_fire = 0; external_ready = 0;
        request_accept_enable = 3;
        mem_rsp_valid = 0; complete_ready = 0;
        for (int p = 0; p < 2; p++) begin descriptor[p] = '0; mem_response[p] = '0; end
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic reply(input int portno, input retire_id_t id, input xlen_t data, input bit error = 0);
        mem_rsp_valid[portno] = 1; mem_response[portno] = '{id:id, data:data, error:error};
    endtask
    always @(posedge clk) begin
        if (rst) previous_request_stall = 0;
        else begin
            for (int p = 0; p < 2; p++) begin
                if (previous_request_stall[p])
                    assert (mem_req_valid[p] && mem_request[p] == previous_request[p])
                        else $fatal(1, "LSQ request changed while stalled port=%0d", p);
                previous_request_stall[p] = mem_req_valid[p] && !mem_req_ready[p];
                previous_request[p] = mem_request[p];
                if (external_valid[p] && external_ready[p]) accepted++;
                if (response_reject[p]) rejected++;
                if (complete_valid[p] && complete_ready[p]) completed++;
            end
        end
    end
    initial begin
        head_slot = 0; head_valid = 0; head_id = '0; accepted = 0; rejected = 0; completed = 0;
        idle(); tick(); rst = 0; tick();
        descriptor[0] = load(0); descriptor[1] = load(1); offer_valid = 3;
        #1; assert (issue_ready == 3) else $fatal(1, "dual LSQ capacity");
        issue_fire = 3; tick();
        #1; assert (mem_req_valid == 3 && external_valid == 0) else $fatal(1, "request boundary bypassed");
        tick();
        #1; assert (external_valid == 3 && busy && !draining) else $fatal(1, "queues lost accepted loads");
        held[0] = external_request[0]; held[1] = external_request[1];
        // 取消发生在 Core 已交付、SoC 尚未外发的区间，所有权仍须保留到真实返回。
        flush = 1; tick();
        #1; assert (busy && draining && external_valid == 3 && complete_valid == 0 &&
                    external_request[0] == held[0] && external_request[1] == held[1])
            else $fatal(1, "canceled queued load withdrawn or ownership released early");
        external_ready = 1; tick();
        reply(1, tag(0), xlen_t'(11));
        #1; assert (response_reject[1]) else $fatal(1, "canceled response accepted"); tick();
        #1; assert (busy && draining && external_valid == 2 && external_request[1] == held[1])
            else $fatal(1, "second canceled owner changed");
        external_ready = 2; tick();
        reply(0, tag(1), xlen_t'(22), 1);
        #1; assert (response_reject[0]) else $fatal(1, "canceled fault escaped"); tick();
        #1; assert (!busy && !draining && complete_valid == 0 && external_valid == 0)
            else $fatal(1, "canceled queues failed to drain");
        reply(0, tag(0), xlen_t'(33)); tick();

        descriptor[0] = load(0, 2); offer_valid = 1; issue_fire = 1; tick(); tick();
        #1; assert (external_valid == 1 && external_request[0].id == tag(0, 2))
            else $fatal(1, "new owner did not reach queue");
        external_ready = 1; tick();
        reply(1, tag(0), xlen_t'(44));
        #1; assert (response_reject[1]) else $fatal(1, "old generation completed new owner"); tick();
        #1; assert (busy && complete_valid == 0) else $fatal(1, "old response cleared live load");
        reply(0, tag(0, 2), xlen_t'(77)); tick();
        #1; assert (complete_valid == 1 && completion[0].id == tag(0, 2) &&
                    completion[0].result.gpr_data == 77 && !completion[0].result.exc.valid)
            else $fatal(1, "new response lost");
        complete_ready = 3; tick();
        #1; assert (!busy && accepted == 3 && rejected == 4 && completed == 1)
            else $fatal(1, "request cancellation balance");
        if (RETIRE_ENTRIES == 32) begin
            // 分支恢复只取消槽31；已经展示但尚未接受的两包都必须稳定并继续排空。
            head_slot = RETIRE_IDX_W'(16);
            descriptor[0] = load(16, 3); descriptor[1] = load(31, 3);
            offer_valid = 3; issue_fire = 3; request_accept_enable = 0; tick();
            request_accept_enable = 0;
            #1; assert (mem_req_valid == 3 && external_valid == 0) else $fatal(1, "high-slot request missing");
            held[0] = mem_request[0]; held[1] = mem_request[1];
            assert (held[0].id == tag(16, 3) && held[1].id == tag(31, 3))
                else $fatal(1, "ROB32 high tag truncated before queue");
            repeat (3) begin
                tick(); request_accept_enable = 0;
                #1; assert (mem_req_valid == 3 && mem_request[0] == held[0] && mem_request[1] == held[1])
                    else $fatal(1, "backpressured high-slot request changed");
            end
            recovery = '{valid:1'b1, id:tag(16, 3), pc:'0}; tick();
            request_accept_enable = 0;
            #1; assert (busy && draining && complete_valid == 0 && mem_req_valid == 3 &&
                        mem_request[0] == held[0] && mem_request[1] == held[1])
                else $fatal(1, "selective recovery withdrew a presented request");
            request_accept_enable = 3; tick();
            #1; assert (external_valid == 3 && external_request[0] == held[0] && external_request[1] == held[1])
                else $fatal(1, "queued high-slot tags changed");
            external_ready = 3; tick();
            reply(0, tag(15, 3), xlen_t'(55));
            #1; assert (response_reject[0]) else $fatal(1, "low-slot alias matched slot31"); tick();
            reply(0, tag(31, 2), xlen_t'(66));
            #1; assert (response_reject[0]) else $fatal(1, "old high-slot generation matched"); tick();
            // 返回端口与请求端口交换，同拍取消错误返回不能污染合法读结果。
            reply(0, tag(31, 3), xlen_t'(88), 1); reply(1, tag(16, 3), xlen_t'(99));
            #1; assert (response_reject == 1) else $fatal(1, "cross-port cancellation match"); tick();
            #1; assert (complete_valid == 1 && completion[0].id == tag(16, 3) &&
                        completion[0].result.gpr_data == 99 && !completion[0].result.exc.valid)
                else $fatal(1, "cross-port legal high-slot result lost");
            complete_ready = 3; tick();
            #1; assert (!busy && !draining) else $fatal(1, "selective recovery did not drain");

            // 旧事务排空后才复用槽31，并检查代次3到0回卷时迟到旧响应不会完成新项。
            head_slot = RETIRE_IDX_W'(31);
            descriptor[0] = load(31, 0); offer_valid = 1; issue_fire = 1; tick(); tick();
            #1; assert (external_valid == 1 && external_request[0].id == tag(31, 0))
                else $fatal(1, "wrapped high-slot owner missing");
            external_ready = 1; tick();
            reply(1, tag(31, 3), xlen_t'(111));
            #1; assert (response_reject[1]) else $fatal(1, "wrapped old generation matched"); tick();
            #1; assert (busy && complete_valid == 0) else $fatal(1, "old response cleared wrapped owner");
            reply(1, tag(31, 0), xlen_t'(123)); tick();
            #1; assert (complete_valid == 1 && completion[0].id == tag(31, 0) &&
                        completion[0].result.gpr_data == 123 && !completion[0].result.exc.valid)
                else $fatal(1, "wrapped high-slot result lost");
            complete_ready = 3; tick();
            #1; assert (!busy && !draining && accepted == 6 && rejected == 8 && completed == 3)
                else $fatal(1, "ROB32 cancellation transaction balance");

            // 高槽 Store 取得队头许可后才发出，完整标签同时用于 owner 和错误完成。
            descriptor[0] = load(31, 1); descriptor[0].write = 1;
            descriptor[0].wdata = xlen_t'(32'hcafe1234); descriptor[0].wstrb = DBUS_BYTES'(15);
            offer_valid = 1; issue_fire = 1; tick(); tick();
            #1; assert (mem_req_valid == 0 && external_valid == 0 && busy)
                else $fatal(1, "high-slot store escaped head authorization");
            head_valid = 1; head_id = tag(31, 1); tick();
            #1; assert (external_valid == 1 && external_request[0].write &&
                        external_request[0].id == tag(31, 1) && store_owner_valid && store_owner_id == tag(31, 1))
                else $fatal(1, "high-slot store owner/tag missing");
            external_ready = 1; tick();
            reply(1, tag(31, 0), xlen_t'(0));
            #1; assert (response_reject[1]) else $fatal(1, "old store generation matched"); tick();
            #1; assert (complete_valid == 0 && store_owner_valid && store_owner_id == tag(31, 1))
                else $fatal(1, "old store response released current owner");
            reply(1, tag(31, 1), xlen_t'(0), 1); tick();
            #1; assert (complete_valid == 1 && completion[0].id == tag(31, 1) &&
                        completion[0].result.exc.valid && completion[0].result.exc.cause == EXC_STORE_ACCESS_FAULT &&
                        completion[0].result.exc.tval == xlen_t'(256+31*8))
                else $fatal(1, "high-slot store fault completion changed");
            complete_ready = 3; tick();
            #1; assert (!busy && !draining && !store_owner_valid && accepted == 7 && rejected == 9 && completed == 4)
                else $fatal(1, "ROB32 load/store transaction balance");
        end
        $display("PASS tb_scoreboard_request_cancel XLEN=%0d ROB=%0d tag_bits=%0d external=%0d rejected=%0d completed=%0d high_slots=%0d",
                 XLEN, RETIRE_ENTRIES, $bits(retire_id_t), accepted, rejected, completed, RETIRE_ENTRIES == 32);
        $finish;
    end
    initial begin #10000; $fatal(1, "request cancellation timeout"); end
endmodule
