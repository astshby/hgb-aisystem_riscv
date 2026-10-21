// Module: tb_scoreboard_lsu
// Description: Checks dual tagged traffic, byte forwarding, ordering, cancellation and held owners.
module tb_scoreboard_lsu;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot;
    logic head_valid;
    retire_id_t head_id;
    logic [1:0] offer_valid, issue_fire, issue_ready, mem_req_valid, mem_req_ready;
    logic [1:0] mem_rsp_valid, mem_rsp_ready, response_reject, complete_valid, complete_ready;
    lsu_descriptor_t descriptor [2];
    memory_request_t mem_request [2], held_request;
    memory_response_t mem_response [2];
    retire_completion_t completion [2], held_completion;
    logic busy, draining, store_owner_valid;
    retire_id_t store_owner_id;
    int completions, dual_requests, rejects;
    retire_gpr_forward_t early_forward [2];
    load_store_queue dut (.*);
    always #5 clk = ~clk;
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
        offer_valid = 0; issue_fire = 0; mem_req_ready = 0; mem_rsp_valid = 0; complete_ready = 0;
        descriptor[0] = '0; descriptor[1] = '0; mem_response[0] = '0; mem_response[1] = '0;
        recovery = '0; flush = 0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic enqueue(input lsu_descriptor_t a, b, input bit second = 0);
        descriptor[0] = a; descriptor[1] = b; offer_valid = second ? 3 : 1;
        #1; assert (issue_ready[0] && (!second || issue_ready[1])) else $fatal(1, "unexpected queue full");
        issue_fire = offer_valid; tick();
    endtask
    task automatic reply(input int portno, input retire_id_t id, input xlen_t value, input bit error = 0);
        mem_rsp_valid[portno] = 1; mem_response[portno] = '{id:id, data:value, error:error};
    endtask
    task automatic clear_queue;
        flush = 1; tick();
        #1; assert (!busy && !draining) else $fatal(1, "flush did not clear unissued/done entries");
    endtask
    always @(posedge clk) if (!rst) begin
        if ((mem_req_valid & mem_req_ready) == 3) dual_requests++;
        for (int portno = 0; portno < 2; portno++) begin
            if (complete_valid[portno] && complete_ready[portno]) completions++;
            if (response_reject[portno]) rejects++;
        end
    end
    initial begin
        head_slot = 0; head_id = tag(0); head_valid = 0; completions = 0; dual_requests = 0; rejects = 0;
        idle(); tick(); rst = 0;
        // 两笔普通 Load 不等队头，可同时外发；年轻结果先到，反压时不能被老结果覆盖。
        enqueue(load(0,256), load(1,264), 1);
        #1; assert (mem_req_valid == 3) else $fatal(1, "two independent load ports missing");
        mem_req_ready = 3; tick();
        reply(0,tag(1),xlen_t'(22)); tick();
        #1; assert (complete_valid[0] && completion[0].id == tag(1)) else $fatal;
        held_completion = completion[0]; tick();
        reply(1,tag(0),xlen_t'(11)); tick();
        #1; assert (complete_valid == 3 && completion[0] == held_completion &&
                    completion[1].id == tag(0) && completion[1].result.gpr_data == 11) else $fatal(1, "completion owner changed");
        complete_ready = 3; tick();
        #1; assert (!busy) else $fatal;

        // 同地址按字节选择最新的更老 Store；Store 未到队头时只转发，不对外写。
        enqueue(store(2,256,xlen_t'(32'h11223344),DBUS_BYTES'(15),MEM_WORD),
                store(3,257,xlen_t'(32'h0000aa00),DBUS_BYTES'(2),MEM_BYTE),1);
        enqueue(load(4,256),'0);
        #1; assert (mem_req_valid == 0) else $fatal(1, "unauthorized Store or redundant forwarded load request");
        tick();
        #1; assert (complete_valid[0] && completion[0].id == tag(4) &&
                    completion[0].result.gpr_data == xlen_t'(32'h1122aa44)) else $fatal(1, "byte forwarding youngest writer");
        complete_ready = 1; tick(); clear_queue();

        // 只有部分字节被覆盖时等待；Store 响应成功后才让 Load 读取完整 RAM 数据。
        enqueue(store(0,256,xlen_t'(8'h88),DBUS_BYTES'(1),MEM_BYTE),load(1,256),1);
        #1; assert (!(|mem_req_valid) && !(|complete_valid)) else $fatal(1, "partial forwarding escaped");
        head_valid = 1; head_id = tag(0); #1;
        assert (mem_req_valid == 1 && mem_request[0].write) else $fatal;
        held_request = mem_request[0]; tick();
        #1; assert (mem_request[0] == held_request && mem_req_valid == 1) else $fatal;
        mem_req_ready = 1; tick();
        reply(1,tag(0),'0); tick();
        #1; assert (complete_valid[0] && completion[0].id == tag(0)) else $fatal;
        complete_ready = 1; tick();
        head_id = tag(1); #1; assert (|mem_req_valid) else $fatal(1, "partial load did not unblock");
        mem_req_ready = 3; tick();
        reply(0,tag(1),xlen_t'(32'h55667788)); tick();
        #1; assert (completion[0].result.gpr_data == xlen_t'(32'h55667788)) else $fatal;
        complete_ready = 3; tick(); head_valid = 0;

        // 已展示但未接受的读遇取消仍保持请求；接纳后的返回只排空，不完成被杀指令。
        enqueue(load(2,272),'0); #1; held_request = mem_request[0]; tick();
        recovery = '{valid:1, id:tag(1), pc:'0};
        #1; assert (mem_req_valid[0] && mem_request[0] == held_request) else $fatal(1, "canceled held request withdrawn");
        tick();
        #1; assert (busy && draining && mem_req_valid[0] && mem_request[0] == held_request) else $fatal;
        mem_req_ready = 1; tick();
        reply(1,tag(2),xlen_t'(99)); #1; assert (response_reject[1]) else $fatal;
        tick();
        #1; assert (!busy && !(|complete_valid)) else $fatal(1, "canceled read wrote completion");
        reply(0,tag(2),xlen_t'(99)); #1; assert (response_reject[0]) else $fatal; tick();

        // 物理槽重用后的旧代次响应不能完成新 Load；正确响应仍可携带 precise fault。
        enqueue(load(2,280,2),'0); mem_req_ready = 3; tick();
        reply(0,tag(2,1),xlen_t'(123)); #1; assert (response_reject[0]) else $fatal; tick();
        #1; assert (busy && !(|complete_valid)) else $fatal;
        reply(1,tag(2,2),xlen_t'(456),1); tick();
        #1; assert (complete_valid[0] && completion[0].id == tag(2,2) &&
                    completion[0].result.exc.valid && completion[0].result.exc.cause == EXC_LOAD_ACCESS_FAULT &&
                    completion[0].result.exc.tval == 280) else $fatal;
        complete_ready = 3; tick();

        // MMIO 前后序列化：未获队头许可时年轻普通内存 Load 也不能越过它。
        enqueue(load(0,32'h10000000),load(1,288),1);
        #1; assert (!(|mem_req_valid)) else $fatal(1, "MMIO or younger load speculated");
        head_valid = 1; head_id = tag(0);
        #1; assert (mem_req_valid == 1 && mem_request[0].id == tag(0)) else $fatal;
        mem_req_ready = 3; tick();
        reply(0,tag(0),xlen_t'(5)); tick(); complete_ready = 1; tick();
        #1; assert (mem_req_valid[0] && mem_request[0].id == tag(1)) else $fatal;
        mem_req_ready = 3; tick(); reply(0,tag(1),xlen_t'(6)); tick(); complete_ready = 3; tick();
        #1; assert (!busy && dual_requests >= 1 && rejects >= 3 && completions == 8)
            else $fatal(1, "LSQ coverage/balance complete=%0d dual=%0d reject=%0d busy=%0d", completions, dual_requests, rejects, busy);
        // LQ/SQ 分别耗尽；部分覆盖阻止这些 Load 外发，恢复可一次释放全部未展示项。
        head_valid = 0;
        enqueue(store(0,256,1,DBUS_BYTES'(1),MEM_BYTE),store(1,256,2,DBUS_BYTES'(1),MEM_BYTE),1);
        enqueue(store(2,256,3,DBUS_BYTES'(1),MEM_BYTE),store(3,256,4,DBUS_BYTES'(1),MEM_BYTE),1);
        // SQ 满时仍可独立接纳 Load，同拍 Store 只对自己的队列反压。
        descriptor[0] = load(4,256); descriptor[1] = store(8,256,5,DBUS_BYTES'(1),MEM_BYTE);
        offer_valid = 3;
        #1; assert (issue_ready == 1) else $fatal(1, "full SQ blocked independent LQ capacity");
        idle();
        enqueue(load(4,256),load(5,256),1);
        enqueue(load(6,256),load(7,256),1);
        descriptor[0] = load(8,256); descriptor[1] = store(9,256,5,DBUS_BYTES'(1),MEM_BYTE);
        offer_valid = 3;
        #1; assert (issue_ready == 0 && mem_req_valid == 0) else $fatal(1, "LQ/SQ full backpressure");
        idle(); clear_queue();
        // MMIO Load 等待队头授权，LQ 满时 SQ 的两个分配口仍保留容量。
        enqueue(load(0,int'(soc_addr_pkg::MTIME_BASE)),load(1,int'(soc_addr_pkg::MTIME_BASE)),1);
        enqueue(load(2,int'(soc_addr_pkg::MTIME_BASE)),load(3,int'(soc_addr_pkg::MTIME_BASE)),1);
        descriptor[0] = load(4,256); descriptor[1] = store(5,256,5,DBUS_BYTES'(1),MEM_BYTE);
        offer_valid = 3;
        #1; assert (issue_ready == 2 && mem_req_valid == 0)
            else $fatal(1, "full LQ blocked independent SQ capacity or MMIO authorization");
        idle(); clear_queue();
        // ROB 跨尾部回绕后，末槽 Store 比倒数第二槽新，又比 slot 0 的 Load 老。
        head_slot = RETIRE_IDX_W'(RETIRE_ENTRIES-2);
        enqueue(store(RETIRE_ENTRIES-2,256,xlen_t'(32'h11223344),DBUS_BYTES'(15),MEM_WORD),
                store(RETIRE_ENTRIES-1,257,xlen_t'(32'h00005500),DBUS_BYTES'(2),MEM_BYTE),1);
        enqueue(load(0,256),'0); tick();
        #1; assert (complete_valid[0] && completion[0].result.gpr_data == xlen_t'(32'h11225544))
            else $fatal(1, "wrapped Store age forwarding");
        complete_ready = 1; tick(); clear_queue();
        $display("PASS tb_scoreboard_lsu XLEN=%0d completions=%0d dual_requests=%0d rejected=%0d forwarding ordering cancel", XLEN, completions, dual_requests, rejects);
        $finish;
    end
endmodule
