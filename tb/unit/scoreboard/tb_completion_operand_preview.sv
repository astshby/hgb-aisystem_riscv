// Module: tb_completion_operand_preview
// Description: Exercises registered ROB ownership previews through real IQ and ISS cancellation boundaries.
module tb_completion_operand_preview;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    import riscv_priv_pkg::*;
    logic clk = 0, rst = 1, flush_all = 0, drain_complete = 1;
    always #5 clk = !clk;
    logic alloc_valid = 0, alloc_ready, alloc_valid_1 = 0, alloc_ready_1;
    retire_alloc_t alloc_meta = '0, alloc_meta_1 = '0;
    retire_id_t alloc_id, alloc_id_1, ids [8];
    logic [RETIRE_IDX_W-1:0] head_slot;
    branch_recovery_t recovery = '0;
    retire_gpr_entry_t producers [RETIRE_ENTRIES];
    retire_id_t probe_id [2];
    logic [1:0] probe_accept, probe_live, source_valid = 0, source_ready;
    logic [1:0] selected_valid, selected_accept, selected_live, complete_valid, complete_ready, reject;
    logic [1:0] preview_valid;
    retire_completion_t source_completion [2], completed [2];
    retire_gpr_forward_t broadcast [2];
    logic [1:0] iq_push_count = 0, iq_capacity, iq_ready, iq_pop_count;
    d2_ex_t iq_push [2], iq_issue [2], iss_packet [2], raw_packet [2];
    logic [2:0] iq_occupancy;
    logic [1:0] iss_capacity, iss_present, iss_occupancy;
    branch_result_t no_branch [2], issue_branch [2];
    logic iss_busy;
    int checks = 0, recovered_preview = 0, stale_checks = 0, faults = 0, age_cases = 0;

    retire_queue #(.RENAMED(1), .REGISTER_RETIRE(1), .PROBE_PORTS(2)) rob (
        .clk, .rst, .flush_all, .drain_complete, .alloc_valid, .alloc_ready, .alloc_meta, .alloc_id,
        .alloc_valid_1, .alloc_ready_1, .alloc_meta_1, .alloc_id_1,
        .complete_valid(complete_valid[0]), .complete_ready(complete_ready[0]), .completion(completed[0]),
        .complete_reject(reject[0]), .complete_valid_1(complete_valid[1]),
        .complete_ready_1(complete_ready[1]), .completion_1(completed[1]), .complete_reject_1(reject[1]),
        .query('0), .query_result(), .query_1('0), .query_result_1(),
        .head_valid(), .head_complete(), .head_id(), .head_meta(), .head_result(),
        .retire_ready(1'b0), .retire_fire(), .occupancy(), .recovering(),
        .head_valid_1(), .head_complete_1(), .head_id_1(), .head_meta_1(), .head_result_1(),
        .retire_ready_1(1'b0), .retire_fire_1(), .branch_recovery(recovery),
        .producer_entries(producers), .ras_entries(), .ras_head_slot(head_slot),
        .probe_id, .probe_accept, .probe_live
    );
    for (genvar src = 0; src < 2; src++) begin : g_source
        assign probe_id[src] = source_completion[src].id;
    end
    completion_select #(.SOURCES(2)) select_result (
        .rst, .head_slot, .source_valid, .source_accept(probe_accept), .source_live(probe_live),
        .source_ready, .source_completion, .complete_valid(selected_valid),
        .complete_accept(selected_accept), .complete_live(selected_live), .completion(completed)
    );
    assign complete_valid[0] = selected_valid[0] && selected_accept[0] && !flush_all;
    assign complete_valid[1] = selected_valid[1] && selected_accept[1] && !flush_all &&
        !(complete_valid[0] && completed[0].id == completed[1].id);
    assign preview_valid[0] = selected_valid[0] && selected_live[0] && !flush_all;
    assign preview_valid[1] = selected_valid[1] && selected_live[1] && !flush_all &&
        !(preview_valid[0] && completed[0].id == completed[1].id);
    for (genvar lane = 0; lane < 2; lane++) begin : g_preview
        assign broadcast[lane] = '{valid:preview_valid[lane] && !completed[lane].result.exc.valid,
            id:completed[lane].id, data:completed[lane].result.gpr_data};
        assign no_branch[lane] = '0;
    end
    scoreboard_queue #(.DEPTH(4), .BROADCAST_PORTS(2), .ISSUE_BYPASS(1)) iq (
        .clk, .rst, .flush(flush_all), .recovery, .head_slot, .push_count(iq_push_count),
        .push_packet(iq_push), .push_capacity(iq_capacity), .producers, .broadcast,
        .issue_packet(iq_issue), .operands_ready(iq_ready), .pop_count(iq_pop_count), .occupancy(iq_occupancy)
    );
    assign iq_pop_count = iq_ready[0] && iss_capacity != 0 ?
        ((iq_ready[1] && iss_capacity == 2) ? 2'd2 : 2'd1) : 2'd0;
    issue_queue #(.STATIC_SELECT(1)) iss (
        .clk, .rst, .flush(flush_all), .recovery, .head_slot, .push_count(iq_pop_count),
        .push_packet(iq_issue), .push_branch(no_branch), .mark_reported(2'b0),
        .push_capacity(iss_capacity), .pop_count(2'b0), .issue_packet(iss_packet), .raw_packet,
        .issue_branch, .present(iss_present), .occupancy(iss_occupancy), .busy(iss_busy)
    );

    task automatic tick;
        #1;
        assert (!(|(reject & complete_valid))) else $fatal(1, "preview changed ROB completion acceptance");
        if (recovery.valid) begin
            assert (iq_pop_count == 0 && iq_ready == 0 && !iss_packet[0].valid && !iss_packet[1].valid)
                else $fatal(1, "operand preview executed through recovery");
            recovered_preview += int'(broadcast[0].valid) + int'(broadcast[1].valid);
        end
        checks++;
        @(posedge clk); @(negedge clk);
    endtask
    task automatic idle;
        alloc_valid = 0; alloc_valid_1 = 0; iq_push_count = 0;
        source_valid = 0; recovery = '0; flush_all = 0;
    endtask
    task automatic restart;
        idle(); rst = 1; tick(); rst = 0; tick();
        for (int pair = 0; pair < 4; pair++) begin
            alloc_valid = 1; alloc_valid_1 = 1;
            alloc_meta = '0; alloc_meta_1 = '0;
            alloc_meta.gpr_write = 1; alloc_meta_1.gpr_write = 1;
            alloc_meta.kind = RET_EXEC; alloc_meta_1.kind = pair == 2 ? RET_BRANCH : RET_EXEC;
            alloc_meta.rd = gpr_addr_t'(pair*2+1); alloc_meta_1.rd = gpr_addr_t'(pair*2+2);
            #1; assert (alloc_ready && alloc_ready_1) else $fatal(1, "ROB test allocation");
            ids[pair*2] = alloc_id; ids[pair*2+1] = alloc_id_1; tick();
        end
        alloc_valid = 0; alloc_valid_1 = 0;
    endtask
    task automatic source(input int lane, input retire_id_t id, input int value, input bit fault);
        source_completion[lane] = '0;
        source_completion[lane].id = id;
        source_completion[lane].result.gpr_data = xlen_t'(value);
        source_completion[lane].result.exc.valid = fault;
    endtask
    task automatic consumer(input int lane, input retire_id_t id, dependency);
        iq_push[lane] = '0;
        iq_push[lane].valid = 1;
        iq_push[lane].retire_id = id;
        iq_push[lane].rs1_dependency = '{pending:1'b1, id:dependency};
        iq_push[lane].rs1_data = xlen_t'(-1);
    endtask

    initial begin
        source_completion[0] = '0; source_completion[1] = '0;
        iq_push[0] = '0; iq_push[1] = '0;
        @(negedge clk); restart();
        consumer(0, ids[4], ids[1]); consumer(1, ids[7], ids[6]); iq_push_count = 2; tick();
        iq_push_count = 0; source(0, ids[1], 111, 0); source(1, ids[6], 666, 0); source_valid = 3;
        recovery = '{valid:1'b1, id:ids[5], pc:'0};
        #1;
        assert (probe_live == 3 && probe_accept == 1 && broadcast[0].valid && broadcast[1].valid)
            else $fatal(1, "registered preview still waits for branch cancellation");
        tick(); idle();
        #1; assert (iq_occupancy == 1 && iq_issue[0].retire_id == ids[4] && iq_ready[0] &&
                    iq_issue[0].rs1_data == 111 && !producers[ids[6].slot].valid)
            else $fatal(1, "survivor/cancelled operand ownership");
        tick();
        #1; assert (iss_occupancy == 1 && iss_packet[0].valid && iss_packet[0].retire_id == ids[4] &&
                    iss_packet[0].rs1_data == 111)
            else $fatal(1, "survivor failed to reach registered ISS");
        source(0, ids[6], 999, 0); source_valid = 1;
        #1; assert (!broadcast[0].valid && !probe_live[0]) else $fatal(1, "late cancelled producer forwarded");
        stale_checks++; tick();

        restart();
        source(0, '{slot:ids[1].slot, generation:ids[1].generation + RETIRE_GEN_W'(1)}, 999, 0);
        source(1, ids[1], 123, 0); source_valid = 3;
        #1; assert (!probe_live[0] && probe_live[1] && !broadcast[0].valid && broadcast[1].valid)
            else $fatal(1, "generation mismatch consumed as operand");
        stale_checks++; tick();
        // 已完成项再次返回不能覆盖先前值，故障结果同样不能前递。
        #1; assert (probe_live == 0 && !broadcast[0].valid && !broadcast[1].valid)
            else $fatal(1, "duplicate done producer forwarded");
        stale_checks++; tick();
        restart(); source(0, ids[1], 321, 0); source(1, ids[1], 777, 0); source_valid = 3;
        #1; assert (broadcast[0].valid && !broadcast[1].valid && complete_valid == 1)
            else $fatal(1, "dual duplicate ID preview");
        tick(); restart(); source(0, ids[1], 999, 1); source_valid = 1;
        #1; assert (probe_live[0] && !broadcast[0].valid) else $fatal(1, "fault operand forwarded");
        faults++; tick();
        restart(); source(0, ids[1], 999, 0); source_valid = 1; flush_all = 1;
        #1; assert (!broadcast[0].valid && complete_valid == 0) else $fatal(1, "flush preview");
        tick(); idle(); source_valid = 1;
        #1; assert (probe_live == 0 && !broadcast[0].valid) else $fatal(1, "flush owner retained");
        stale_checks++; tick(); idle();

        // 独立年龄整数枚举：更老依赖与存活 consumer 的组合不会跨越取消边界。
        for (int head = 0; head < RETIRE_ENTRIES; head++)
            for (int boundary = 0; boundary < RETIRE_ENTRIES; boundary++)
                for (int consumer_age = 0; consumer_age <= boundary; consumer_age++)
                    for (int producer_age = 0; producer_age < consumer_age; producer_age++) begin
                        assert (!younger_than('{slot:RETIRE_IDX_W'(head+producer_age),generation:'0},
                            '{slot:RETIRE_IDX_W'(head+boundary),generation:'0}, RETIRE_IDX_W'(head)))
                            else $fatal(1, "surviving consumer depends on cancelled producer");
                        age_cases++;
                    end
        assert (recovered_preview == 2 && stale_checks >= 4 && faults == 1 && age_cases > 1000)
            else $fatal(1, "operand preview coverage");
        $display("PASS tb_completion_operand_preview RV%0d checks=%0d recovery_capture=%0d stale=%0d faults=%0d age_cases=%0d",
                 XLEN, checks, recovered_preview, stale_checks, faults, age_cases);
        $finish;
    end
endmodule
