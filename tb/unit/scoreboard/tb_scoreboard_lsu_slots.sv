// Module: tb_scoreboard_lsu_slots
// Description: Checks fixed-slot completions with central arbitration, recovery, faults and stale responses.
module tb_scoreboard_lsu_slots;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    localparam int ENTRIES = LOAD_QUEUE_ENTRIES + STORE_QUEUE_ENTRIES;
    localparam int SOURCES = ENTRIES + 3;
    logic clk = 0, rst = 1, flush = 0, use_arbiter = 0;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic head_valid;
    retire_id_t head_id, store_owner_id;
    logic [1:0] offer_valid, issue_fire, issue_ready, mem_req_valid, mem_req_ready;
    logic [1:0] mem_rsp_valid, mem_rsp_ready, response_reject;
    logic [ENTRIES-1:0] complete_valid, complete_ready, manual_ready;
    lsu_descriptor_t descriptor [2];
    memory_request_t mem_request [2], held_request;
    memory_response_t mem_response [2];
    retire_completion_t completion [ENTRIES], held_completion;
    logic busy, draining, store_owner_valid;
    logic [2:0] synthetic_valid;
    retire_completion_t synthetic [3], source_completion [SOURCES], selected [2];
    logic [SOURCES-1:0] source_valid, source_accept, source_ready;
    logic [1:0] selected_valid, selected_accept;
    logic [2:0] accepted_synthetic;
    int order [7] = '{RETIRE_ENTRIES-2, RETIRE_ENTRIES-1, 0, 1, 2, 3, 4};
    int checked, dual_completions;
    always #5 clk = ~clk;
    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "fixed-slot test timeout");
    end
    retire_gpr_forward_t early_forward [2];
    retire_gpr_forward_t load_return [2], store_forward_hint [2];
    retire_gpr_forward_t store_slot_hint [LOAD_QUEUE_ENTRIES];
    load_store_queue #(.COMPLETION_PORTS(ENTRIES)) dut (.*);
    completion_select #(.SOURCES(SOURCES)) u_select (
        .rst, .head_slot, .source_valid, .source_accept, .source_ready, .source_completion,
        .complete_valid(selected_valid), .complete_accept(selected_accept), .source_live('0), .complete_live(), .completion(selected)
    );
    assign source_accept = source_valid;
    for (genvar slot = 0; slot < ENTRIES; slot++) begin : g_lsu_source
        assign source_valid[slot+3] = complete_valid[slot];
        assign source_completion[slot+3] = completion[slot];
        assign complete_ready[slot] = use_arbiter ? source_ready[slot+3] : manual_ready[slot];
    end
    for (genvar src = 0; src < 3; src++) begin : g_other_source
        assign source_valid[src] = synthetic_valid[src];
        assign source_completion[src] = synthetic[src];
    end
    function automatic retire_id_t tag(input int slot, input int generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic lsu_descriptor_t load(input int slot, address, input int generation = 1);
        return '{id:tag(slot,generation), address:xlen_t'(address), write:1'b0, size:MEM_WORD,
                 unsigned_load:1'b0, wdata:'0, wstrb:'0};
    endfunction
    function automatic lsu_descriptor_t store(input int slot, address, input xlen_t data,
                                              input logic [DBUS_BYTES-1:0] mask, input mem_size_e size);
        return '{id:tag(slot), address:xlen_t'(address), write:1'b1, size:size,
                 unsigned_load:1'b0, wdata:data, wstrb:mask};
    endfunction
    task automatic idle;
        offer_valid = 0; issue_fire = 0; mem_req_ready = 0; mem_rsp_valid = 0; manual_ready = 0;
        descriptor[0] = '0; descriptor[1] = '0; mem_response[0] = '0; mem_response[1] = '0;
        recovery = '0; flush = 0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic enqueue(input lsu_descriptor_t a, b, input bit second = 0);
        descriptor[0] = a; descriptor[1] = b; offer_valid = second ? 3 : 1;
        #1; assert (issue_ready[0] && (!second || issue_ready[1])) else $fatal(1, "unexpected LSQ full");
        issue_fire = offer_valid; tick();
    endtask
    task automatic reply(input int portno, input retire_id_t id, input xlen_t value, input bit error = 0);
        mem_rsp_valid[portno] = 1; mem_response[portno] = '{id:id, data:value, error:error};
    endtask
    initial begin
        head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-2); head_id = tag(RETIRE_ENTRIES-2); head_valid = 0;
        synthetic_valid = 0; checked = 0; dual_completions = 0;
        for (int src = 0; src < 3; src++) synthetic[src] = '0;
        idle(); tick(); rst = 0;
        // 四笔 Load 先全部外发，再让年轻响应跨口先到，结果保持在各自物理槽。
        enqueue(load(RETIRE_ENTRIES-2,256), load(RETIRE_ENTRIES-1,264), 1);
        enqueue(load(0,272), load(1,280), 1);
        mem_req_ready = 3; tick(); mem_req_ready = 3; tick();
        reply(1,tag(0),30); reply(0,tag(1),40); tick();
        #1; assert (complete_valid == ENTRIES'(12) && completion[2].id == tag(0) &&
                    completion[3].id == tag(1)) else $fatal(1, "fixed Load completion slots");
        held_completion = completion[2]; tick();
        reply(1,tag(RETIRE_ENTRIES-2),10); reply(0,tag(RETIRE_ENTRIES-1),20,1); tick();
        #1; assert (complete_valid == ENTRIES'(15) && completion[2] == held_completion &&
                    completion[0].result.gpr_data == 10 && completion[1].result.exc.valid &&
                    completion[1].result.exc.cause == EXC_LOAD_ACCESS_FAULT &&
                    completion[1].result.exc.tval == 264) else $fatal(1, "held result or precise Load fault");
        // 与两个 ALU 和 MDU 同时竞争，跨 ROB 回卷的全局最老两项每拍接纳。
        for (int src = 0; src < 3; src++) begin
            synthetic[src].id = tag(src+2);
            synthetic[src].result.gpr_data = xlen_t'(100+src);
        end
        synthetic_valid = 7; use_arbiter = 1;
        while (checked < 7) begin
            #1; accepted_synthetic = source_ready[2:0];
            if (selected_valid == 3) dual_completions++;
            for (int lane = 0; lane < 2; lane++)
                if (selected_valid[lane]) begin
                    assert (selected[lane].id == tag(order[checked])) else $fatal(1, "global oldest completion");
                    checked++;
                end
            tick(); synthetic_valid &= ~accepted_synthetic;
        end
        use_arbiter = 0;
        #1; assert (!busy && synthetic_valid == 0 && dual_completions == 3) else $fatal(1, "global drain");

        // 四个 Store 槽分别完成，必须保持队头许可、返回错误和固定槽号。
        head_slot = 0;
        enqueue(store(0,512,1,DBUS_BYTES'(15),MEM_WORD), store(1,520,2,DBUS_BYTES'(15),MEM_WORD),1);
        enqueue(store(2,528,3,DBUS_BYTES'(15),MEM_WORD), store(3,536,4,DBUS_BYTES'(15),MEM_WORD),1);
        head_valid = 1;
        for (int number = 0; number < 4; number++) begin
            head_id = tag(number); #1;
            assert (mem_req_valid == 1 && mem_request[0].write && mem_request[0].id == tag(number))
                else $fatal(1, "Store head authorization");
            mem_req_ready = 1; tick();
            reply(1,tag(number),0,number==2); tick();
            #1; assert (complete_valid == (ENTRIES'(1) << (LOAD_QUEUE_ENTRIES+number)) &&
                        completion[LOAD_QUEUE_ENTRIES+number].id == tag(number) &&
                        completion[LOAD_QUEUE_ENTRIES+number].result.exc.valid == (number==2))
                else $fatal(1, "fixed Store slot or fault");
            if (number == 2)
                assert (completion[LOAD_QUEUE_ENTRIES+number].result.exc.cause == EXC_STORE_ACCESS_FAULT)
                    else $fatal(1, "Store fault cause");
            manual_ready = '1; tick();
        end
        head_valid = 0; #1; assert (!busy) else $fatal(1, "Store drain");

        // 已转发但被反压的 Load 与年轻 Store 同拍取消，不影响更老的 Store。
        head_slot = 2;
        enqueue(store(2,256,xlen_t'(32'h11223344),DBUS_BYTES'(15),MEM_WORD),
                store(3,257,xlen_t'(32'h0000aa00),DBUS_BYTES'(2),MEM_BYTE),1);
        enqueue(store(4,512,0,DBUS_BYTES'(15),MEM_WORD), store(5,520,0,DBUS_BYTES'(15),MEM_WORD),1);
        enqueue(load(6,256),'0); tick();
        #1; assert (complete_valid == 1 && completion[0].result.gpr_data == xlen_t'(32'h1122aa44))
            else $fatal(1, "fixed-slot forwarding");
        recovery = '{valid:1, id:tag(3), pc:'0}; manual_ready = 1; tick();
        #1; assert (complete_valid == 0 && busy && !draining) else $fatal(1, "same-cycle cancel/complete");
        flush = 1; tick();
        #1; assert (!busy) else $fatal(1, "older Store flush");

        // 取消反压请求必须先接纳再排空；复用物理槽后拒绝旧代次，真实响应仍可完成。
        head_slot = 0;
        enqueue(load(7,288),'0); #1; held_request = mem_request[0]; tick();
        recovery = '{valid:1, id:tag(6), pc:'0}; tick();
        #1; assert (draining && mem_req_valid[0] && mem_request[0] == held_request)
            else $fatal(1, "canceled held request");
        mem_req_ready = 3; tick(); reply(1,tag(7),77); #1;
        assert (response_reject[1]) else $fatal(1, "canceled response");
        tick(); #1; assert (!busy && complete_valid == 0) else $fatal(1, "cancel drain completion");
        enqueue(load(7,296,2),'0); mem_req_ready = 3; tick();
        reply(0,tag(7),88); #1; assert (response_reject[0]) else $fatal(1, "stale generation accepted");
        tick(); reply(1,tag(7,2),99); tick();
        held_completion = completion[0];
        repeat (4) begin
            #1; assert (complete_valid == 1 && completion[0] == held_completion &&
                        completion[0].id == tag(7,2) && completion[0].result.gpr_data == 99)
                else $fatal(1, "fixed-slot backpressure");
            tick();
        end
        manual_ready = '1; tick();
        #1; assert (!busy) else $fatal(1, "final fixed-slot drain");
        $display("PASS tb_scoreboard_lsu_slots XLEN=%0d sources=%0d global_checked=%0d dual=%0d stores=4 faults forwarding cancel reuse held",
                 XLEN,SOURCES,checked,dual_completions);
        $finish;
    end
endmodule
