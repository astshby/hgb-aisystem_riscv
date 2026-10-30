// Module: tb_completion_payload_miter
// Description: Compares fixed completion payload writes with the immutable FIFO under cancellation and backpressure.
module tb_completion_payload_miter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    always #5 clk = !clk;
    branch_recovery_t recovery = '0;
    logic [RETIRE_IDX_W-1:0] head_slot = '0;
    logic input_valid = 0, input_ready, output_valid, output_ready = 0, output_preview_valid, busy;
    logic ref_ready, ref_valid, ref_preview, ref_busy;
    retire_completion_t input_completion = '0, output_completion, ref_completion;
    int unsigned random_state = 32'hc0ffee71;
    int checks = 0, transfer = 0, recoveries = 0, full = 0;
    completion_queue dut (.*);
    completion_queue_reference previous (
        .clk, .rst, .flush, .recovery, .head_slot, .input_valid, .input_ready(ref_ready),
        .input_completion, .output_valid(ref_valid), .output_preview_valid(ref_preview),
        .output_ready, .output_completion(ref_completion), .busy(ref_busy)
    );
    task automatic check_cycle;
        #1;
        assert ({input_ready, output_valid, output_preview_valid, busy} ==
                {ref_ready, ref_valid, ref_preview, ref_busy})
            else $fatal(1, "completion ownership/timing differs");
        if (output_preview_valid) begin
            assert (output_completion == ref_completion) else $fatal(1, "completion full payload differs");
            if (!input_ready) full++;
        end
        transfer += int'(input_valid && input_ready);
        recoveries += int'(recovery.valid);
        checks++;
        @(posedge clk); @(negedge clk);
    endtask
    initial begin
        @(negedge clk); check_cycle(); rst = 0;
        for (int cycle = 0; cycle < 12000; cycle++) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            output_ready = random_state[3] || random_state[4];
            flush = cycle % 113 == 112;
            recovery.valid = cycle % 17 == 0;
            recovery.id.slot = RETIRE_IDX_W'(random_state >> 12);
            head_slot = RETIRE_IDX_W'(random_state >> 20);
            if (!input_valid || input_ready || flush || recovery.valid) begin
                input_valid = !random_state[2] || random_state[1];
                input_completion = '0;
                input_completion.id = '{slot:RETIRE_IDX_W'(random_state >> 8),
                    generation:RETIRE_GEN_W'(random_state >> 28)};
                input_completion.result.gpr_data = xlen_t'(random_state) << (XLEN/2);
                input_completion.result.next_pc = xlen_t'(~random_state);
                input_completion.result.csr_data = xlen_t'(random_state ^ 32'h12345678);
                input_completion.result.csr_write = random_state[9];
                input_completion.result.branch.taken = random_state[10];
                input_completion.result.branch.target = xlen_t'(random_state >> 4);
                input_completion.result.exc.valid = random_state[11];
                input_completion.result.exc.tval = xlen_t'(random_state ^ 32'hcafef00d);
            end
            check_cycle();
        end
        assert (transfer > 4000 && recoveries > 600 && full > 1000) else $fatal(1, "CMP coverage");
        $display("PASS tb_completion_payload_miter RV%0d checks=%0d inputs=%0d recovery=%0d full=%0d",
                 XLEN, checks, transfer, recoveries, full);
        $finish;
    end
endmodule
