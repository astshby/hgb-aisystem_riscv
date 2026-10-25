// Module: tb_scoreboard_completion_cancel
// Description: Compares accepted completions with cancellation before versus after age selection.
module tb_scoreboard_completion_cancel;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    localparam int SOURCES = 11;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    logic [RETIRE_IDX_W-1:0] head_slot;
    branch_recovery_t recovery;
    logic [SOURCES-1:0] occupied, surviving, acceptable, stale, selected, old_selected;
    retire_completion_t source [SOURCES], result [2], old_result [2];
    logic [1:0] result_valid, result_accept, old_valid, old_accept;
    int checks = 0, accepted = 0, rejected_cancelled = 0, mixed = 0;
    int unsigned random_state = 32'hca11ce11;

    // 原路径在年龄选择前删除年轻项；候选路径在选择后用 ROB 接受位拒绝它们。
    // 另注入旧代次，保证已有的无效 ID 排空顺序没有改变。
    always_comb begin
        for (int src = 0; src < SOURCES; src++) begin
            surviving[src] = occupied[src] &&
                !(recovery.valid && younger_than(source[src].id, recovery.id, head_slot));
            acceptable[src] = !stale[src] &&
                !(recovery.valid && younger_than(source[src].id, recovery.id, head_slot));
        end
    end
    completion_select #(.SOURCES(SOURCES)) u_candidate (
        .rst, .head_slot, .source_valid(occupied), .source_accept(acceptable),
        .source_ready(selected), .source_completion(source), .complete_valid(result_valid),
        .complete_accept(result_accept), .completion(result)
    );
    completion_select #(.SOURCES(SOURCES)) u_previous (
        .rst, .head_slot, .source_valid(surviving), .source_accept(acceptable),
        .source_ready(old_selected), .source_completion(source), .complete_valid(old_valid),
        .complete_accept(old_accept), .completion(old_result)
    );

    initial begin
        head_slot = '0; recovery = '0; occupied = '0; stale = '0;
        for (int src = 0; src < SOURCES; src++) source[src] = '0;
        repeat (2) @(negedge clk);
        rst = 0;
        for (int head = 0; head < RETIRE_ENTRIES; head++) begin
            for (int mask = 0; mask < (1 << SOURCES); mask++) begin
                for (int sample_no = 0; sample_no < 4; sample_no++) begin
                    @(negedge clk);
                    head_slot = RETIRE_IDX_W'(head);
                    occupied = SOURCES'(mask);
                    recovery.valid = sample_no != 0;
                    recovery.id.slot = RETIRE_IDX_W'(head + (mask % RETIRE_ENTRIES));
                    for (int src = 0; src < SOURCES; src++) begin
                        random_state = random_state * 32'd1664525 + 32'd1013904223;
                        source[src].id = '{slot:RETIRE_IDX_W'(random_state >> 16),
                            generation:RETIRE_GEN_W'(random_state >> 8)};
                        source[src].result.gpr_data = xlen_t'(random_state);
                        source[src].result.exc.valid = random_state[2];
                        stale[src] = random_state[23] && sample_no == 3;
                    end
                    #1;
                    assert ((result_valid & result_accept) == (old_valid & old_accept))
                        else $fatal(1, "cancellation changed accepted completion lanes");
                    for (int lane = 0; lane < 2; lane++) begin
                        if (result_valid[lane] && result_accept[lane]) begin
                            assert (result[lane] == old_result[lane])
                                else $fatal(1, "cancellation changed accepted completion payload");
                            accepted++;
                        end
                    end
                    assert ((selected & surviving) == old_selected)
                        else $fatal(1, "cancelled candidate displaced a surviving source");
                    rejected_cancelled += $countones(selected & occupied & ~surviving);
                    if ((|surviving) && (|(occupied & ~surviving))) mixed++;
                    checks++;
                end
            end
        end
        assert (accepted > 1000 && rejected_cancelled > 1000 && mixed > 1000)
            else $fatal(1, "insufficient cancellation/age-wrap coverage");
        $display("PASS tb_scoreboard_completion_cancel RV%0d checks=%0d accepted=%0d cancelled=%0d mixed=%0d",
                 XLEN, checks, accepted, rejected_cancelled, mixed);
        $finish;
    end
endmodule
