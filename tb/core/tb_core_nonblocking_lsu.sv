// Module: tb_core_nonblocking_lsu
// Description: Checks independent ordinary execution behind a strict-head single-owner LSU.
module tb_core_nonblocking_lsu;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import rv_asm_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 0, rst = 1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    logic imem_rsp_error = 0;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    logic dmem_rsp_valid, dmem_rsp_ready, dmem_rsp_error;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic [31:0] code[128];
    xlen_t values[128];
    logic writes[128];
    int scenario, cycle, retired, requests, responses, stores, reads, traps;
    int early_done, blocked_done, maximum_occupancy, full_cycles, second_wait;
    int d1_early, ex_early, collision, load_forward, simultaneous_fault;
    int rsp_cycle, completion_delay, expected_pc, terminal_pc, first_request_cycle;
    int prep_done, triple_collision, mdu_wb_collision, mdu_wait_cycles, mdu_max_wait, lsu_wait_cycles, lsu_max_wait;
    int ordinary_during_second;
    retire_id_t waiting_mdu_id, waiting_lsu_id;
    int total_collision = 0, total_forward = 0, total_d1 = 0, total_ex = 0;
    int total_fault = 0, total_second = 0;
    logic pending, responded, done, fault_mode, branch_mode;
    logic request_held;
    logic [1+3+2*XLEN+DBUS_BYTES-1:0] request_snapshot;
    retire_id_t owner_id;
    int response_due;
    typedef struct packed {retire_id_t id; retire_alloc_t meta; logic completed;} entry_t;
    entry_t age[$];
    entry_t discarded;
    int found;

    always #5 clk = ~clk;
    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    // 分支场景延迟该指令的取指接受，确保控制流事件发生在老 Load 已接受、尚未响应的窗口。
    assign imem_req_ready = (!imem_rsp_valid || imem_rsp_ready) &&
                           !(branch_mode && imem_req_addr == 16 && requests == 0);
    assign dmem_req_ready = !pending && !dmem_rsp_valid && (scenario != 0 || cycle >= 60);

    // 总线模型只在请求接受后回应；动态触发仅用来制造真实 WB/响应或分支/故障碰撞。
    // 不改 DUT ready/valid，不强制内部状态，不读取退休队列槽或指针。
    always @(negedge clk) begin
        if (rst) begin
            imem_rsp_valid = 0; dmem_rsp_valid = 0; dmem_rsp_error = 0;
        end else begin
            if (pending && !responded && !dmem_rsp_valid) begin
                if ((scenario == 2 && dut.ex_mem_q.valid && dut.ex_mem_q.pc == 4) ||
                    (scenario == 6 && dut.d2_ex_q.valid && dut.d2_ex_q.pc == 16 &&
                     !dut.u_ex_stage.u_branch_result_register.valid_q) ||
                    (scenario == 10 && dut.mdu_req_valid && dut.mdu_req_ready) ||
                    (!(scenario inside {2,6,10}) && cycle >= response_due)) begin
                    dmem_rsp_valid = 1;
                    dmem_rsp_error = fault_mode && requests == 1;
                    dmem_rsp_rdata = xlen_t'(41);
                end
            end
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            cycle = 0; retired = 0; requests = 0; responses = 0; stores = 0; reads = 0; traps = 0;
            early_done = 0; blocked_done = 0; maximum_occupancy = 0; full_cycles = 0; second_wait = 0;
            d1_early = 0; ex_early = 0; collision = 0; load_forward = 0; simultaneous_fault = 0;
            rsp_cycle = -1; completion_delay = -1; first_request_cycle = -1;
            prep_done = 0; triple_collision = 0; mdu_wb_collision = 0;
            ordinary_during_second = 0;
            mdu_wait_cycles = 0; mdu_max_wait = 0; lsu_wait_cycles = 0; lsu_max_wait = 0;
            waiting_mdu_id = '0; waiting_lsu_id = '0;
            pending = 0; responded = 0; done = 0; request_held = 0; expected_pc = 0;
            age.delete();
        end else if (!done) begin
            cycle++;
            if (age.size() > maximum_occupancy) maximum_occupancy = age.size();
            if (age.size() == RETIRE_ENTRIES && !responded) full_cycles++;
            if (request_held)
                assert (dmem_req_valid && {dmem_req_write,3'(dmem_req_size),dmem_req_addr,dmem_req_wdata,dmem_req_wstrb} == request_snapshot)
                    else $fatal(1, "blocked request payload/valid changed");
            request_held = dmem_req_valid && !dmem_req_ready;
            request_snapshot = {dmem_req_write,3'(dmem_req_size),dmem_req_addr,dmem_req_wdata,dmem_req_wstrb};
            if (dmem_req_valid) begin
                assert (age.size() > 0 && dut.lsu_owner_id == age[0].id && !dut.wb_redirect.valid)
                    else $fatal(1, "LSU offered non-head or cancelled side effect");
            end
            if (dmem_req_valid && dmem_req_ready) begin
                assert (!pending && !responded) else $fatal(1, "second external owner before old retirement");
                if (fault_mode) assert (requests == 0) else $fatal(1, "younger Store/MMIO read escaped old fault");
                requests++; pending = 1; owner_id = dut.lsu_owner_id;
                if (first_request_cycle < 0) first_request_cycle = cycle;
                response_due = cycle + (requests > 1 ? 2 : (scenario == 0 ? 2 : 60));
                if (dmem_req_write) begin
                    stores++;
                    assert (dmem_req_wdata[31:0] == 9 && dmem_req_wstrb == DBUS_BYTES'(15))
                        else $fatal(1, "Store data/strobe side effect incorrect");
                end else reads++;
            end
            // 同沿完成先更新参考，再核对退休；完整 ID 映射来自分配事件，而非 DUT queue 内容。
            if (dut.complete_valid && dut.complete_ready && !dut.complete_reject) begin
                found = -1;
                for (int i = 0; i < age.size(); i++) if (age[i].id == dut.completion.id) found = i;
                assert (found >= 0 && !age[found].completed) else $fatal(1, "unowned or duplicate completion");
                age[found].completed = 1;
                if (scenario == 11 && age[found].meta.pc == 4 && dut.d2_ex_q.valid && dut.d2_ex_q.pc == 8)
                    ordinary_during_second++;
                if (scenario == 9 && requests == 0 && age[found].meta.kind == RET_EXEC &&
                    age[found].meta.pc >= 16 && dut.lsu_request_pending) prep_done++;
                if (found > 0 && !responded && age[0].meta.kind == RET_LOAD) begin
                    early_done++;
                    if (requests == 0) blocked_done++;
                end
            end
            if (dut.lsu_complete_valid && dut.wb_complete_valid) begin
                collision++;
                assert (!dut.lsu_complete_ready && dut.wb_complete_ready)
                    else $fatal(1, "WB priority changed without a preexisting locked grant");
                if (dut.d2_ex_q.valid && dut.d2_ex_q.pc == 8 && dut.mdu_operands_ready) begin
                    load_forward++;
                    assert (dut.ex_rs1_value == 41 && dut.tagged_lsu_forward.valid)
                        else $fatal(1, "registered Load forward hidden by WB winner");
                end
            end
            // 服务界限只从连续 valid 开始，按完整 ID 计时，不混入执行/总线等待。
            // sink 常 ready、无取消且容量有限是此 Core 场景的前提，不宣称固定优先仲裁器通用公平。
            if (dut.mdu_complete_valid && !dut.execution_cancel) begin
                if (mdu_wait_cycles == 0) waiting_mdu_id = dut.mdu_completion.id;
                assert (waiting_mdu_id == dut.mdu_completion.id) else $fatal(1, "blocked MDU ID changed");
                mdu_wait_cycles++;
                assert (mdu_wait_cycles <= 2*RETIRE_ENTRIES-1) else $fatal(1, "MDU service bound");
                if (dut.wb_complete_valid) mdu_wb_collision++;
                if (dut.wb_complete_valid && dut.lsu_complete_valid) triple_collision++;
                if (dut.mdu_complete_ready) begin
                    if (mdu_wait_cycles > mdu_max_wait) mdu_max_wait = mdu_wait_cycles;
                    mdu_wait_cycles = 0;
                end
            end else mdu_wait_cycles = 0;
            if (dut.lsu_complete_valid && !dut.execution_cancel) begin
                if (lsu_wait_cycles == 0) waiting_lsu_id = dut.lsu_completion.id;
                assert (waiting_lsu_id == dut.lsu_completion.id) else $fatal(1, "blocked LSU ID changed");
                lsu_wait_cycles++;
                assert (lsu_wait_cycles <= RETIRE_ENTRIES) else $fatal(1, "head LSU service bound");
                if (dut.lsu_complete_ready) begin
                    if (lsu_wait_cycles > lsu_max_wait) lsu_max_wait = lsu_wait_cycles;
                    lsu_wait_cycles = 0;
                end
            end else lsu_wait_cycles = 0;
            if (dut.execution_cancel)
                assert (!dut.lsu_issue_valid && !dut.lsu_issue_ready)
                    else $fatal(1, "old fault accepted younger LSU refill");
            if (dut.d2_ex_q.valid && ((scenario == 3 && dut.d2_ex_q.pc == 4) ||
                (scenario == 11 && dut.d2_ex_q.pc == 8)) && pending && !responded && requests == 1) begin
                second_wait++;
                assert (!dut.lsu_issue_valid && !dut.lsu_issue_ready && dut.execution_stall)
                    else $fatal(1, "second LSU did not remain in EX");
                for (int i = 0; i < age.size(); i++)
                    assert (age[i].meta.pc <= (scenario == 3 ? 4 : 8)) else $fatal(1, "younger ALU bypassed waiting second LSU");
            end
            if (branch_mode && pending && !responded) begin
                // 解析可以早于老 LSU 响应；预测表训练必须继续等待正常退休。
                if (dut.d1_packet.valid && dut.d1_packet.pc == 16 &&
                    dut.d1_packet.uop.branch_op == BR_JAL &&
                    dut.pipeline_actions.d1_d2 == PIPE_ADVANCE) d1_early++;
                if (dut.ex_stage_advance && dut.d2_ex_q.pc == 16 &&
                    dut.u_ex_stage.branch_valid) ex_early++;
                if (dut.selected_redirect.valid && !dut.wb_redirect.valid)
                    assert (!dut.execution_cancel && dut.lsu_owner_id == owner_id)
                        else $fatal(1, "frontend redirect cancelled older LSU owner");
            end
            // 同沿老故障会组合屏蔽 EX redirect，因此观察已寄存的年轻 taken 快照，
            // 不能错误地要求被优先级逻辑取消后的 ex_redirect.valid 仍为一。
            if (scenario == 6 && dut.wb_redirect.valid && dut.d2_ex_q.valid &&
                dut.d2_ex_q.pc == 16 && dut.u_ex_stage.u_branch_result_register.valid_q) begin
                simultaneous_fault++;
                assert (dut.selected_redirect == dut.wb_redirect && !dut.ex_stage_advance &&
                        dut.u_ex_stage.branch_taken && dut.u_ex_stage.branch_target == 24)
                    else $fatal(1, "young branch won over same-cycle old fault");
            end
            if (commit_valid) begin
                assert (age.size() > 0 && age[0].completed && dut.head_id == age[0].id)
                    else $fatal(1, "retirement bypassed incomplete reference head");
                assert (commit_pc == xlen_t'(expected_pc) && commit_inst == code[expected_pc/4])
                    else $fatal(1, "architectural trace order pc=%h expected=%h scenario=%0d", commit_pc, expected_pc, scenario);
                if (commit_exception) begin
                    assert (fault_mode && expected_pc == 12 && responded && dut.head_result.exc.cause == 5 &&
                            dut.head_result.exc.tval == 0) else $fatal(1, "imprecise LSU fault");
                    traps++; expected_pc = 256;
                end else begin
                    assert (commit_rd_we == writes[expected_pc/4]) else $fatal(1, "unexpected GPR effect");
                    if (commit_rd_we)
                        assert (commit_rd == code[expected_pc/4][11:7] && commit_rd_data == values[expected_pc/4])
                            else $fatal(1, "incorrect architectural GPR result pc=%h", commit_pc);
                    expected_pc = (branch_mode && expected_pc == 16) ? 24 : expected_pc + 4;
                end
                if (age[0].meta.kind inside {RET_LOAD,RET_STORE}) begin
                    assert (responded && dut.head_id == owner_id) else $fatal(1, "memory retired without its response");
                    completion_delay = cycle - rsp_cycle;
                    assert (completion_delay >= 1 && completion_delay <= RETIRE_ENTRIES + 4)
                        else $fatal(1, "head LSU service bound violated: %0d", completion_delay);
                    pending = 0; responded = 0;
                end
                retired++;
                discarded = age.pop_front();
                if (commit_pc == xlen_t'(terminal_pc)) done = 1;
            end
            if (dut.wb_redirect.valid) age.delete();
            else if (dut.dispatch_valid && dut.dispatch_ready)
                age.push_back('{id:dut.alloc_id, meta:dut.alloc_meta, completed:0});
            if (dmem_rsp_valid && dmem_rsp_ready) begin
                assert (pending && !responded && dut.lsu_owner_id == owner_id)
                    else $fatal(1, "response owner was lost or duplicated");
                responded = 1; responses++; rsp_cycle = cycle;
            end
        end
    end
    // 延后修改已握手通道，避免与 DUT 的同沿采样竞争。
    always @(posedge clk) begin
        if (!rst) begin
            if (imem_rsp_valid && imem_rsp_ready) imem_rsp_valid <= 0;
            if (imem_req_valid && imem_req_ready) begin
                imem_rsp_valid <= 1;
                imem_rsp_data <= code[int'(imem_req_addr >> 2) & 127];
            end
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 0;
        end
    end

    task automatic put(input int pc, input logic [31:0] inst, input logic we, input xlen_t value);
        code[pc/4] = inst; writes[pc/4] = we; values[pc/4] = value;
    endtask
    initial begin
        for (scenario = 0; scenario < 12; scenario++) begin
            rst = 1;
            fault_mode = scenario inside {4,5,6}; branch_mode = scenario inside {[4:8]};
            for (int i = 0; i < 128; i++) begin code[i] = enc_jal(0,0); writes[i] = 0; values[i] = 0; end
            if (scenario == 9) begin
                put(0,enc_addi(10,0,84),1,84); put(4,enc_addi(11,0,7),1,7);
                put(8,enc_div(20,10,11),1,12); put(12,enc_lw(1,0,0),1,41);
                for (int i = 0; i < 8; i++) put(16+4*i,enc_addi(5'(i+2),0,i+1),1,xlen_t'(32'(i+1)));
                terminal_pc = 44;
            end else if (scenario == 10) begin
                if (RETIRE_ENTRIES > 2) begin
                    put(0,enc_lw(1,0,0),1,41); put(4,enc_addi(2,0,7),1,7);
                    put(8,enc_div(3,0,0),1,'1); terminal_pc = 8;
                end else begin
                    // 两槽无法同时容纳三源；仍用相邻普通 ALU/除零证明 WB 与 MDU 的竞争。
                    put(0,enc_addi(2,0,7),1,7); put(4,enc_div(3,0,0),1,'1); terminal_pc = 4;
                end
            end else if (scenario == 11) begin
                put(0,enc_lw(1,0,0),1,41); put(4,enc_addi(2,0,7),1,7);
                put(8,enc_lw(3,0,8),1,41); put(12,enc_addi(4,0,9),1,9); terminal_pc = 12;
            end else if (!branch_mode) begin
                put(0,enc_lw(1,0,0),1,41);
                if (scenario < 2) begin
                    for (int i = 1; i <= 12; i++) put(i*4,enc_addi(5'(i+1),0,i),1,xlen_t'(i));
                    terminal_pc = 48;
                end else if (scenario == 2) begin
                    put(4,enc_addi(2,0,7),1,7); put(8,enc_addi(3,1,1),1,42); terminal_pc = 8;
                end else begin
                    put(4,enc_lw(2,0,8),1,41); put(8,enc_addi(3,0,9),1,9); terminal_pc = 8;
                end
            end else begin
                put(0,enc_addi(10,0,256),1,256); put(4,enc_csrrw(0,CSR_MTVEC,10),0,0);
                put(8,enc_addi(11,0,9),1,9); put(12,enc_lw(1,0,0),1,41);
                put(16,(scenario inside {4,7}) ? enc_jal(0,8) : enc_beq(0,0,8),0,0);
                put(20,enc_sw(11,0,16),0,0);
                put(24,enc_addi(2,0,7),1,7);
                if (scenario == 5) put(28,enc_lw(3,0,24),1,41);
                else put(28,enc_sw(11,0,16),0,0);
                put(32,enc_lw(4,0,24),1,41); put(36,enc_addi(5,0,3),1,3);
                put(256,enc_addi(6,0,13),1,13);
                terminal_pc = fault_mode ? 256 : 36;
            end
            repeat (4) @(negedge clk);
            rst = 0;
            for (int timeout = 0; timeout < 1500 && !done; timeout++) @(negedge clk);
            assert (done && !pending && !responded && responses == requests)
                else $fatal(1, "LSU progress/owner timeout scenario=%0d requests=%0d",scenario,requests);
            if (scenario < 2)
                assert (early_done >= RETIRE_ENTRIES-1 && maximum_occupancy == RETIRE_ENTRIES && full_cycles > 0 &&
                        (scenario != 0 || blocked_done > 0))
                    else $fatal(1, "nonblocking/full coverage vacuous early=%0d max=%0d blocked=%0d",early_done,maximum_occupancy,blocked_done);
            if (scenario == 2)
                assert (collision > 0 && (RETIRE_ENTRIES == 2 || load_forward > 0))
                    else $fatal(1, "WB/LSU collision or independent forward not covered");
            if (scenario == 3) assert (second_wait > 0 && requests == 2) else $fatal(1, "second LSU coverage");
            if (fault_mode) assert (traps == 1 && requests == 1 && stores == 0) else $fatal(1, "fault side effect coverage");
            if (scenario inside {4,5}) assert (early_done > 0) else $fatal(1, "old fault did not cancel young done result");
            if (scenario inside {4,7}) assert (d1_early == 1) else $fatal(1, "D1 JAL event lost or not early");
            if (scenario inside {5,8}) assert (ex_early == 1) else $fatal(1, "EX branch event lost or not early");
            if (scenario == 6) assert (simultaneous_fault == 1) else $fatal(1, "same-cycle fault/branch not covered");
            if (scenario == 9 && RETIRE_ENTRIES > 2)
                assert (prep_done > 0) else $fatal(1, "ALU did not complete behind LSU PREP/older MDU");
            if (scenario == 10)
                assert (mdu_wb_collision > 0 && (RETIRE_ENTRIES == 2 || triple_collision > 0))
                    else $fatal(1, "three-source/MDU-WB collision missing");
            if (scenario == 11 && RETIRE_ENTRIES > 2)
                assert (ordinary_during_second == 1 && second_wait > 0 && requests == 2)
                    else $fatal(1, "ordinary MEM failed to drain exactly once while second LSU held EX");
            total_collision += collision; total_forward += load_forward; total_d1 += d1_early;
            total_ex += ex_early; total_fault += simultaneous_fault; total_second += second_wait;
            $display("NBLSU RV%0d n=%0d scenario=%0d cycles=%0d early=%0d blocked=%0d max=%0d full=%0d collision=%0d forward=%0d d1=%0d ex=%0d simultaneous_fault=%0d second=%0d req=%0d",
                XLEN,RETIRE_ENTRIES,scenario,cycle,early_done,blocked_done,maximum_occupancy,full_cycles,collision,load_forward,d1_early,ex_early,simultaneous_fault,second_wait,requests);
            $display("NBLSU_SERVICE scenario=%0d prep_alu=%0d triple=%0d mdu_wb=%0d mdu_max=%0d lsu_max=%0d mem_drain=%0d",scenario,prep_done,triple_collision,mdu_wb_collision,mdu_max_wait,lsu_max_wait,ordinary_during_second);
            @(negedge clk);
        end
        $display("PASS tb_core_nonblocking_lsu RV%0d entries=%0d scenarios=12 collision=%0d forward=%0d d1=%0d ex=%0d fault_priority=%0d second_wait=%0d",
            XLEN,RETIRE_ENTRIES,total_collision,total_forward,total_d1,total_ex,total_fault,total_second);
        $finish;
    end
endmodule
