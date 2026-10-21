// Module: tb_scoreboard_lsu_forward
// Description: Checks early load operands against tagged, formatted and canceled memory responses.
module tb_scoreboard_lsu_forward;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    branch_recovery_t recovery;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic head_valid = 0;
    retire_id_t head_id;
    logic [1:0] offer_valid, issue_fire, issue_ready, mem_req_valid, mem_req_ready;
    logic [1:0] mem_rsp_valid, mem_rsp_ready, response_reject, complete_valid, complete_ready;
    lsu_descriptor_t descriptor [2];
    memory_request_t mem_request [2];
    memory_response_t mem_response [2];
    retire_completion_t completion [2], held;
    retire_gpr_forward_t early_forward [2];
    logic busy, draining, store_owner_valid;
    retire_id_t store_owner_id;
    int cases = 0;
    load_store_queue dut (
        .clk, .rst, .flush, .recovery, .head_slot, .head_valid, .head_id,
        .offer_valid, .issue_fire, .descriptor, .issue_ready,
        .mem_req_valid, .mem_req_ready, .mem_request,
        .mem_rsp_valid, .mem_rsp_ready, .mem_response, .response_reject,
        .complete_valid, .complete_ready, .completion, .early_forward,
        .busy, .draining, .store_owner_valid, .store_owner_id
    );
    always #5 clk = ~clk;
    function automatic retire_id_t tag(input int slot, generation = 1);
        return '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(generation)};
    endfunction
    function automatic lsu_descriptor_t load(input int slot, address,
                                             input mem_size_e size = MEM_WORD,
                                             input bit unsign = 0, input int generation = 1);
        return '{id:tag(slot,generation), address:xlen_t'(address), write:1'b0,
                 size:size, unsigned_load:unsign, wdata:'0, wstrb:'0};
    endfunction
    task automatic idle;
        offer_valid = 0; issue_fire = 0; mem_req_ready = 0; mem_rsp_valid = 0; complete_ready = 0;
        descriptor[0] = '0; descriptor[1] = '0; mem_response[0] = '0; mem_response[1] = '0;
        recovery = '0; flush = 0;
    endtask
    task automatic tick;
        @(posedge clk); #1; @(negedge clk); idle();
    endtask
    task automatic enqueue(input lsu_descriptor_t a, b = '0, input bit second = 0);
        descriptor[0] = a; descriptor[1] = b; offer_valid = second ? 3 : 1;
        #1; assert ((issue_ready & offer_valid) == offer_valid) else $fatal(1,"queue full");
        issue_fire = offer_valid; tick();
    endtask
    task automatic reply(input int portno, input retire_id_t id, input xlen_t data, input bit error = 0);
        mem_rsp_valid[portno] = 1; mem_response[portno] = '{id:id, data:data, error:error};
    endtask
    task automatic expect_early(input int portno, input retire_id_t id, input xlen_t data);
        #1; assert (early_forward[portno].valid && early_forward[portno].id == id &&
                    early_forward[portno].data == data)
            else $fatal(1,"early operand port=%0d actual=%h expected=%h",portno,early_forward[portno],data);
    endtask
    task automatic expect_none;
        #1; assert (!early_forward[0].valid && !early_forward[1].valid)
            else $fatal(1,"invalid early operand");
    endtask
    task automatic consume;
        complete_ready = 3; tick(); #1;
        assert (!busy) else $fatal(1,"completion did not release owner");
    endtask
    task automatic format_case(input mem_size_e size, input bit unsign,
                               input int offset, input xlen_t expected);
        enqueue(load(0,256+offset,size,unsign)); mem_req_ready = 3; tick();
        reply(1,tag(0),xlen_t'(64'hfedcba98876580ff));
        expect_early(1,tag(0),expected);
        assert (complete_valid == 0) else $fatal(1,"early operand completed ROB path");
        tick(); expect_none();
        assert (complete_valid[0] && completion[0].result.gpr_data == expected &&
                !completion[0].result.exc.valid) else $fatal(1,"formatted completion mismatch");
        held = completion[0]; repeat (3) begin
            tick(); assert (complete_valid[0] && completion[0] == held) else $fatal(1,"held result changed");
        end
        consume(); cases++;
    endtask
    // 同一个 Store 同拍供给不同偏移/类型的两个 Load；旧错误响应不能遮住合法转发。
    task automatic forward_pair(input mem_size_e size_a, input bit unsign_a, input int offset_a,
                                input xlen_t expected_a, input mem_size_e size_b,
                                input bit unsign_b, input int offset_b, input xlen_t expected_b);
        enqueue('{id:tag(0), address:xlen_t'(256), write:1'b1,
                  size:(XLEN == 64 ? MEM_DWORD : MEM_WORD), unsigned_load:1'b0,
                  wdata:xlen_t'(64'hfedcba98876580ff), wstrb:'1});
        enqueue(load(1,256+offset_a,size_a,unsign_a),load(2,256+offset_b,size_b,unsign_b),1);
        reply(0,tag(8,3),xlen_t'(32'hbad0bad0),1);
        expect_early(0,tag(1),expected_a); expect_early(1,tag(2),expected_b);
        assert (mem_req_valid == 0 && response_reject[0])
            else $fatal(1,"forwarding used memory or accepted stale response");
        tick();
        assert (complete_valid == 3 && completion[0].id == tag(1) &&
                completion[0].result.gpr_data == expected_a && !completion[0].result.exc.valid &&
                completion[1].id == tag(2) && completion[1].result.gpr_data == expected_b &&
                !completion[1].result.exc.valid)
            else $fatal(1,"parallel formatted forwarding mismatch");
        complete_ready = 3; tick(); flush = 1; tick();
        assert (!busy) else $fatal(1,"forwarding owners survived flush");
        cases++;
    endtask
    initial begin
        idle(); head_id = tag(0); tick(); rst = 0;
        format_case(MEM_BYTE,0,1,xlen_t'(-128));
        format_case(MEM_BYTE,1,1,xlen_t'(128));
        format_case(MEM_HALF,0,0,xlen_t'(-32513));
        format_case(MEM_HALF,1,0,xlen_t'(16'h80ff));
        format_case(MEM_WORD,0,0,{{(XLEN-32){1'b1}},32'h876580ff});
        format_case(MEM_WORD,1,0,xlen_t'(32'h876580ff));
        if (XLEN == 64) format_case(MEM_DWORD,0,0,xlen_t'(64'hfedcba98876580ff));

        forward_pair(MEM_BYTE,0,1,xlen_t'(-128),MEM_HALF,1,2,xlen_t'(16'h8765));
        forward_pair(MEM_HALF,0,0,xlen_t'(-32513),MEM_BYTE,1,3,xlen_t'(8'h87));
        forward_pair(MEM_WORD,0,0,{{(XLEN-32){1'b1}},32'h876580ff},
                     MEM_WORD,1,0,xlen_t'(32'h876580ff));
        if (XLEN == 64) begin
            forward_pair(MEM_WORD,0,4,xlen_t'(64'hfffffffffedcba98),
                         MEM_DWORD,0,0,xlen_t'(64'hfedcba98876580ff));
            forward_pair(MEM_BYTE,0,7,xlen_t'(-2),MEM_HALF,1,6,xlen_t'(16'hfedc));
        end

        // 返回口不绑定请求口；完整 ID 决定操作数归属。
        enqueue(load(0,256),load(1,264),1); mem_req_ready = 3; tick();
        reply(0,tag(1),22); reply(1,tag(0),11);
        expect_early(0,tag(1),22); expect_early(1,tag(0),11);
        tick(); assert (complete_valid == 3) else $fatal; consume(); cases++;

        enqueue(load(0,256)); mem_req_ready = 1; tick();
        reply(0,tag(0),33); reply(1,tag(0),99);
        expect_early(0,tag(0),33);
        assert (!early_forward[1].valid && response_reject[1]) else $fatal(1,"duplicate response forwarded");
        tick(); assert (complete_valid == 1 && completion[0].result.gpr_data == 33) else $fatal;
        consume(); cases++;

        // 错误、旧代次、恢复当拍和已杀 owner 都不能唤醒消费者。
        enqueue(load(0,256,MEM_WORD,0,2)); mem_req_ready = 1; tick();
        reply(0,tag(0,1),44); expect_none(); assert (response_reject[0]) else $fatal; tick();
        reply(1,tag(0,2),55,1); expect_none(); tick();
        assert (complete_valid[0] && completion[0].result.exc.valid &&
                completion[0].result.exc.cause == EXC_LOAD_ACCESS_FAULT) else $fatal;
        consume(); cases++;

        enqueue(load(2,256)); mem_req_ready = 1; tick();
        recovery = '{valid:1'b1,id:tag(1),pc:'0}; reply(0,tag(2),66);
        expect_none(); tick(); assert (!busy && complete_valid == 0) else $fatal; cases++;
        enqueue(load(2,256)); mem_req_ready = 1; tick(); flush = 1; tick();
        assert (busy && draining) else $fatal;
        reply(1,tag(2),77); expect_none(); tick(); assert (!busy && complete_valid == 0) else $fatal; cases++;

        // 同拍内存返回与 Store 转发竞争同一提示口；正常完成必须保存两者。
        enqueue(load(0,272)); mem_req_ready = 1; tick();
        enqueue('{id:tag(1),address:xlen_t'(256),write:1'b1,size:MEM_WORD,
                  unsigned_load:1'b0,wdata:xlen_t'(123),wstrb:DBUS_BYTES'(15)},load(2,256),1);
        reply(0,tag(0),88); expect_early(0,tag(0),88);
        tick(); assert (complete_valid == 3 && completion[0].id == tag(0) &&
                       completion[0].result.gpr_data == 88 && completion[1].id == tag(2) &&
                       completion[1].result.gpr_data == 123) else $fatal(1,"competing result lost");
        complete_ready = 3; tick(); flush = 1; tick(); assert (!busy) else $fatal; cases++;

        enqueue('{id:tag(0),address:xlen_t'(256),write:1'b1,size:MEM_WORD,
                  unsigned_load:1'b0,wdata:xlen_t'(456),wstrb:DBUS_BYTES'(15)},load(1,256),1);
        expect_early(0,tag(1),456); tick(); complete_ready = 1; tick();
        // Store 的成功响应不包含可广播的 GPR 值。
        head_valid = 1; head_id = tag(0); mem_req_ready = 1; tick();
        reply(1,tag(0),'0); expect_none(); tick(); consume(); cases++;
        $display("PASS tb_scoreboard_lsu_forward XLEN=%0d cases=%0d formatted tagged duplicate error cancel backpressure",XLEN,cases);
        $finish;
    end
endmodule
