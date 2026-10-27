// Module: tb_scoreboard_request_queue
// Description: Checks both request queues against ordered references under sustained traffic, backpressure and reset.
module tb_scoreboard_request_queue;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1;
    logic [1:0] in_valid, in_ready, out_valid, out_ready, stalled, previous_ready;
    logic [1:0] previous_output_stall;
    memory_request_t in_request [2], out_request [2], expected [2][$], discarded;
    memory_request_t previous_output [2];
    int accepted [2], returned [2], dropped [2], blocked [2];
    logic [RETIRE_ENTRIES-1:0] seen_slots [2];
    logic [(1<<RETIRE_GEN_W)-1:0] seen_generations [2];
    int streak, longest, dual_returns;
    int unsigned random_state = 32'hc0de4096;
    always #5 clk = ~clk;
    for (genvar portno = 0; portno < 2; portno++) begin : g_port
        tagged_request_queue dut (
            .clk, .rst, .in_valid(in_valid[portno]), .in_ready(in_ready[portno]),
            .in_request(in_request[portno]), .out_valid(out_valid[portno]),
            .out_ready(out_ready[portno]), .out_request(out_request[portno])
        );
    end
    function automatic memory_request_t packet(input int portno, serial);
        memory_request_t value;
        value = '0;
        value.id = '{slot:RETIRE_IDX_W'(serial), generation:RETIRE_GEN_W'(serial / RETIRE_ENTRIES)};
        value.address = xlen_t'(64'h1234_abcd_0110_0000 ^ (64'(serial) << 4) ^ 64'(portno*8));
        value.write = portno == 0 && serial[3];
        value.size = mem_size_e'(serial % 4);
        value.wdata = xlen_t'(64'hfedc_ba98_7654_3210 ^ 64'(serial*37+portno));
        value.wstrb = DBUS_BYTES'(serial ^ 8'h96);
        return value;
    endfunction
    // 软件 FIFO 只在握手沿改变，比较完整标签及每个请求字段；输入和输出可同时前进。
    always @(posedge clk) begin
        stalled = in_valid & ~in_ready;
        if (rst) begin
            previous_output_stall = 0;
            assert (in_ready == 0 && out_valid == 0) else $fatal(1, "queue active during reset");
            for (int p = 0; p < 2; p++) begin
                dropped[p] += expected[p].size();
                expected[p].delete();
            end
            streak = 0;
        end else begin
            if ((out_valid & out_ready) == 3) begin
                dual_returns++; streak++;
                if (streak > longest) longest = streak;
            end else streak = 0;
            for (int p = 0; p < 2; p++) begin
                if (previous_output_stall[p])
                    assert (out_valid[p] && out_request[p] == previous_output[p])
                        else $fatal(1, "queued request changed while stalled port=%0d", p);
                previous_output_stall[p] = out_valid[p] && !out_ready[p];
                previous_output[p] = out_request[p];
                assert (in_ready[p] == (expected[p].size() < 2) &&
                        out_valid[p] == (expected[p].size() != 0))
                    else $fatal(1, "queue capacity or registered latency port=%0d", p);
                if (out_valid[p]) begin
                    assert (out_request[p] == expected[p][0])
                        else $fatal(1, "request replaced/reordered port=%0d count=%0d", p, returned[p]);
                    if (out_ready[p]) begin
                        seen_slots[p][out_request[p].id.slot] = 1;
                        seen_generations[p][out_request[p].id.generation] = 1;
                        discarded = expected[p].pop_front(); returned[p]++;
                    end
                end
                if (in_valid[p] && in_ready[p]) begin
                    expected[p].push_back(in_request[p]); accepted[p]++;
                end
                if (in_valid[p] && !in_ready[p]) blocked[p]++;
            end
        end
    end
    initial begin
        in_valid = 0; out_ready = 0; stalled = 0;
        for (int p = 0; p < 2; p++) begin
            in_request[p] = '0; accepted[p] = 0; returned[p] = 0; dropped[p] = 0; blocked[p] = 0;
            seen_slots[p] = 0; seen_generations[p] = 0;
        end
        streak = 0; longest = 0; dual_returns = 0;
        repeat (2) @(negedge clk);
        rst = 0;
        for (int cycle = 0; cycle < 2400; cycle++) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            if (cycle == 1200) begin
                rst = 1; in_valid = 0; out_ready = 0;
            end else begin
                rst = 0;
                for (int p = 0; p < 2; p++) begin
                    if (!stalled[p] || cycle == 1201) begin
                        in_valid[p] = cycle < 96 || |random_state[4*p +: 2];
                        in_request[p] = packet(p, accepted[p]);
                    end
                end
                // 改变下游 ready 不得组合改变上游容量许可。
                #1; previous_ready = in_ready;
                out_ready = cycle < 96 ? 2'b11 :
                    {(|random_state[12 +: 2]), (|random_state[8 +: 2])};
                #1; assert (in_ready == previous_ready) else $fatal(1, "downstream ready bypass");
            end
            @(negedge clk);
        end
        in_valid = 0; out_ready = 3;
        repeat (4) @(negedge clk);
        for (int p = 0; p < 2; p++) begin
            assert (expected[p].size() == 0 && returned[p] + dropped[p] == accepted[p] &&
                    returned[p] > 1000 && blocked[p] > 100)
                else $fatal(1, "queue balance or backpressure coverage port=%0d", p);
            // 完整槽号与代次都经真实输出握手检查；ROB32 必须覆盖高半区及槽31。
            assert (&seen_slots[p] && &seen_generations[p])
                else $fatal(1, "incomplete slot/generation coverage port=%0d", p);
        end
        assert (longest >= 80 && dual_returns > 500) else $fatal(1, "dual sustained throughput");
        $display("PASS tb_scoreboard_request_queue XLEN=%0d ROB=%0d tag_bits=%0d slots=%h/%h generations=%h/%h returned=%0d/%0d reset_drop=%0d/%0d dual=%0d streak=%0d",
                 XLEN, RETIRE_ENTRIES, $bits(retire_id_t), seen_slots[0], seen_slots[1],
                 seen_generations[0], seen_generations[1], returned[0], returned[1],
                 dropped[0], dropped[1], dual_returns, longest);
        $finish;
    end
    initial begin #100000; $fatal(1, "request queue timeout"); end
endmodule
