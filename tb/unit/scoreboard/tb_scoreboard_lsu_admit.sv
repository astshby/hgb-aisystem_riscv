// Module: tb_scoreboard_lsu_admit
// Description: Checks allocation-edge Load requests, held payloads, cancellation and ordered accesses.
module tb_scoreboard_lsu_admit;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic head_valid;
    retire_id_t head_id;
    logic [1:0] offer_valid, issue_fire, issue_ready, mem_req_valid, mem_req_ready;
    logic [1:0] mem_rsp_valid, mem_rsp_ready, response_reject, complete_valid, complete_ready;
    lsu_descriptor_t descriptor [2];
    memory_request_t mem_request [2], held [2];
    memory_response_t mem_response [2];
    retire_completion_t completion [2];
    retire_gpr_forward_t early_forward [2], load_return [2], store_forward_hint [2];
    retire_gpr_forward_t store_slot_hint [LOAD_QUEUE_ENTRIES];
    logic busy, draining, store_owner_valid;
    retire_id_t store_owner_id;
    int accepted = 0, checks = 0;
    load_store_queue dut (.*);
    always #5 clk = ~clk;
    always @(posedge clk) if (!rst)
        accepted += int'(mem_req_valid[0] && mem_req_ready[0]) +
                    int'(mem_req_valid[1] && mem_req_ready[1]);
    function automatic retire_id_t tag(input int slot);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(1)};
    endfunction
    function automatic lsu_descriptor_t load(input int slot, address);
        return '{id:tag(slot), address:xlen_t'(address), write:1'b0, size:MEM_WORD,
                 unsigned_load:1'b0, wdata:'0, wstrb:'0};
    endfunction
    task automatic idle;
        offer_valid = 0; issue_fire = 0; mem_req_ready = 0; mem_rsp_valid = 0; complete_ready = 0;
        descriptor[0] = '0; descriptor[1] = '0; mem_response[0] = '0; mem_response[1] = '0;
        recovery = '0; flush = 0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic restart;
        rst = 1; tick(); rst = 0;
        head_valid = 0; head_id = tag(0); head_slot = 0; accepted = 0;
    endtask
    task automatic offer(input lsu_descriptor_t a, b, input logic [1:0] lanes);
        descriptor[0] = a; descriptor[1] = b; offer_valid = lanes;
        #1; assert ((issue_ready & lanes) == lanes) else $fatal(1, "unexpected allocation backpressure");
        issue_fire = lanes; #1;
    endtask
    task automatic reply(input int portno, slot, value);
        mem_rsp_valid[portno] = 1;
        mem_response[portno] = '{id:tag(slot), data:xlen_t'(value), error:1'b0};
    endtask
    initial begin
        idle(); restart();
        // 两个请求在分配沿握手，响应按完整 ID 跨端口返回；后续不得重复请求。
        offer(load(0,256),load(1,264),3); mem_req_ready = 3; #1;
        assert (mem_req_valid == 3 && mem_request[0].id == tag(0) && mem_request[1].id == tag(1))
            else $fatal(1, "allocation-edge dual request missing");
        tick(); #1;
        assert (accepted == 2 && mem_req_valid == 0) else $fatal(1, "accepted Load reissued");
        reply(0,1,22); reply(1,0,11); tick(); #1;
        assert (complete_valid == 3 && completion[0].result.gpr_data == 11 &&
                completion[1].result.gpr_data == 22) else $fatal(1, "cross-port response mismatch");
        complete_ready = 3; tick(); #1; assert (!busy) else $fatal; checks++;

        // 预发即受背压，刚分配的槽接手稳定载荷；恢复后仍排空已展示事务。
        restart(); offer(load(2,272),load(3,280),3); held = mem_request; tick();
        descriptor[0] = load(7,512); descriptor[1] = load(8,520);
        recovery = '{valid:1'b1,id:tag(1),pc:'0}; #1;
        assert (mem_req_valid == 3 && mem_request == held) else $fatal(1, "held admission changed on recovery");
        tick(); #1; assert (draining && mem_request == held) else $fatal;
        mem_req_ready = 3; tick(); reply(0,3,33); reply(1,2,22); #1;
        assert (response_reject == 3) else $fatal(1, "cancelled admission response accepted");
        tick(); #1; assert (!busy && complete_valid == 0 && accepted == 2) else $fatal; checks++;

        // 同拍老 Store 与同字 Load 走原有字节转发，不提前从 RAM 读旧数据。
        restart(); descriptor[0] = load(0,256); descriptor[0].write = 1;
        descriptor[0].wdata = xlen_t'(32'h12345678); descriptor[0].wstrb = DBUS_BYTES'(15);
        descriptor[1] = load(1,256); offer_valid = 3; #1; issue_fire = 3; mem_req_ready = 3; #1;
        assert (mem_req_valid == 0) else $fatal(1, "same-edge Store alias escaped");
        tick(); tick(); #1;
        assert (complete_valid[0] && completion[0].id == tag(1) &&
                completion[0].result.gpr_data == xlen_t'(32'h12345678) && accepted == 0)
            else $fatal(1, "same-edge Store forwarding lost"); checks++;

        // 同拍 MMIO 与普通 Load 均不能提前发出，既有 MMIO 也阻止下一拍新 Load。
        restart(); offer(load(0,32'h10000000),load(1,288),3); mem_req_ready = 3; #1;
        assert (mem_req_valid == 0) else $fatal(1, "same-edge MMIO ordering lost"); tick();
        offer(load(2,296),'0,1); mem_req_ready = 3; #1;
        assert (mem_req_valid == 0) else $fatal(1, "existing MMIO ordering lost"); tick(); checks++;

        // DDR 窗口上界之外不得投机读；MRET 后错误路径上的负指针由恢复取消。
        restart(); offer(load(0,int'(soc_addr_pkg::DDR_BASE+soc_config_pkg::DDR_WINDOW_BYTES)),
                         load(1,int'(32'hffffaaaa)),3); mem_req_ready = 3; #1;
        assert (mem_req_valid == 0) else $fatal(1, "unmapped address speculated on allocation");
        tick(); #1; assert (mem_req_valid == 0) else $fatal(1, "unmapped address speculated from queue");
        flush = 1; tick(); #1; assert (!busy && accepted == 0) else $fatal; checks++;
        assert (speculative_ram(xlen_t'(soc_addr_pkg::DDR_BASE)) &&
                speculative_ram(xlen_t'(soc_addr_pkg::DDR_BASE+soc_config_pkg::DDR_WINDOW_BYTES-1)) &&
                !speculative_ram(xlen_t'(soc_addr_pkg::DDR_BASE+soc_config_pkg::DDR_WINDOW_BYTES)))
            else $fatal(1, "DDR speculative range endpoints");
        if (XLEN == 64)
            assert (!speculative_ram(xlen_t'(64'h0000000180000000)))
                else $fatal(1, "RV64 high address truncated");

        // 部分实际发射保留 offer 预占的空槽，背压所有权必须指向 lane1 的实际分配槽。
        restart(); descriptor[0] = load(0,304); descriptor[1] = load(1,312); offer_valid = 3; #1;
        assert (issue_ready == 3) else $fatal; issue_fire = 2; #1; held[0] = mem_request[0];
        assert (mem_req_valid == 1 && mem_request[0].id == tag(1)) else $fatal; tick(); #1;
        assert (mem_req_valid == 1 && mem_request[0] == held[0]) else $fatal(1, "partial offer owner mismatch");
        mem_req_ready = 1; tick(); reply(1,1,44); tick(); #1;
        assert (complete_valid[0] && completion[0].id == tag(1) && completion[0].result.gpr_data == 44)
            else $fatal; complete_ready = 3; tick(); #1; assert (!busy && accepted == 1) else $fatal; checks++;

        // 旧端口所有者优先，新 Load 只占空闲口，旧请求不能被新分配覆盖。
        restart(); offer(load(0,320),'0,1); held[0] = mem_request[0]; tick();
        offer(load(1,328),'0,1); mem_req_ready = 3; #1;
        assert (mem_req_valid == 3 && mem_request[0] == held[0] && mem_request[1].id == tag(1))
            else $fatal(1, "old owner priority lost"); tick(); #1;
        assert (accepted == 2 && mem_req_valid == 0) else $fatal; checks++;
        $display("PASS tb_scoreboard_lsu_admit XLEN=%0d checks=%0d allocation held recovery alias MMIO partial priority",XLEN,checks);
        $finish;
    end
endmodule
