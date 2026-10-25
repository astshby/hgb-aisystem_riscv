// Module: tb_scoreboard_completion_queue
// Description: Checks held results, simultaneous transfer and selective recovery of completion buffers.
module tb_scoreboard_completion_queue;
    timeunit 1ns; timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import scoreboard_pkg::*;
    logic clk = 0, rst = 1, flush = 0;
    always #5 clk = !clk;
    branch_recovery_t recovery = '0;
    logic [RETIRE_IDX_W-1:0] head_slot = 0;
    logic input_valid = 0, input_ready, output_valid, output_ready = 0, busy;
    retire_completion_t input_completion = '0, output_completion;
    retire_completion_t expected[$];
    retire_completion_t item, discarded;
    int transfers = 0, cancellations = 0, checked = 0;
    logic take_in, take_out, output_preview_valid;
    int flushed_previews = 0, cancelled_previews = 0;
    completion_queue dut (.*);
    function automatic retire_completion_t packet(input int slot, value);
        retire_completion_t result;
        result = '0;
        result.id = '{slot:RETIRE_IDX_W'(slot), generation:RETIRE_GEN_W'(value >> 4)};
        result.result.gpr_data = xlen_t'(value);
        result.result.next_pc = xlen_t'(value * 4);
        result.result.csr_data = xlen_t'(~value);
        result.result.csr_write = value[0];
        result.result.branch.taken = value[1];
        result.result.branch.target = xlen_t'(value * 8);
        result.result.exc.valid = value[2];
        result.result.exc.tval = xlen_t'(value ^ 32'hcafef00d);
        return result;
    endfunction
    task automatic cycle;
        #1;
        if (!rst) begin
            assert (busy == (expected.size() != 0)) else $fatal(1, "busy does not include held completions");
            assert (output_valid == (!flush && expected.size() != 0 &&
                !(recovery.valid && younger_than(expected[0].id, recovery.id, head_slot))))
                else $fatal(1, "cancelled/held output valid");
            assert (output_preview_valid == (expected.size() != 0))
                else $fatal(1, "preview candidate does not match registered occupancy");
            if (output_preview_valid) begin
                assert (output_completion == expected[0]) else $fatal(1, "completion payload changed");
                if (flush) flushed_previews++;
                if (recovery.valid && younger_than(expected[0].id, recovery.id, head_slot))
                    cancelled_previews++;
            end
            assert (input_ready == (!flush && expected.size() < 2))
                else $fatal(1, "completion FIFO capacity");
        end
        take_in = input_valid && input_ready;
        take_out = output_valid && output_ready;
        if (rst || flush) expected.delete();
        else begin
            if (take_out) begin discarded = expected.pop_front(); transfers++; end
            for (int index = expected.size()-1; index >= 0; index--) begin
                if (recovery.valid && younger_than(expected[index].id, recovery.id, head_slot)) begin
                    expected.delete(index); cancellations++;
                end
            end
            if (take_in && !(recovery.valid && younger_than(input_completion.id, recovery.id, head_slot)))
                expected.push_back(input_completion);
        end
        @(posedge clk); @(negedge clk); checked++;
    endtask
    initial begin
        @(negedge clk); cycle(); rst = 0;
        input_valid = 1; input_completion = packet(3, 35); cycle();
        input_completion = packet(4, 36); cycle();
        // 满队列背压 8 拍，输入不被接纳，输出结构的每一位都应保持。
        input_completion = packet(5, 37); repeat (8) cycle();
        output_ready = 1; cycle(); while (!take_in) cycle(); input_valid = 0; cycle(); cycle();
        // 乱序完成导致较年轻项在前、较老项在后，恢复后必须保留后者。
        output_ready = 0; input_valid = 1; input_completion = packet(12, 44); cycle();
        input_completion = packet(2, 34); cycle(); input_valid = 0;
        recovery = '{valid:1'b1,id:'{slot:RETIRE_IDX_W'(7),generation:'0},pc:'0}; cycle();
        recovery = '0; output_ready = 1; cycle();
        // 环形年龄和全 flush；全 flush 同沿不接纳新结果。
        head_slot = RETIRE_IDX_W'(12); output_ready = 0; input_valid = 1;
        input_completion = packet(15, 63); cycle(); input_completion = packet(2, 66); cycle();
        recovery = '{valid:1'b1,id:'{slot:RETIRE_IDX_W'(0),generation:'0},pc:'0};
        input_valid = 0; cycle(); recovery = '0; flush = 1; input_valid = 1; output_ready = 1; cycle(); flush = 0;
        for (int step = 0; step < 400; step++) begin
            output_ready = step % 5 != 0;
            if (!input_valid || take_in) begin
                input_valid = step % 7 != 0;
                input_completion = packet(step % RETIRE_ENTRIES, 100 + step);
            end
            recovery.valid = step % 29 == 0;
            recovery.id.slot = RETIRE_IDX_W'(step % RETIRE_ENTRIES);
            head_slot = RETIRE_IDX_W'((step / 17) % RETIRE_ENTRIES);
            cycle();
        end
        recovery = '0; input_valid = 0; output_ready = 1; repeat (3) cycle();
        assert (expected.size() == 0 && !busy && transfers > 200 && cancellations >= 2)
            else $fatal(1, "insufficient completion queue coverage");
        assert (flushed_previews > 0 && cancelled_previews > 0)
            else $fatal(1, "flush/recovery preview with blocked handshake not covered");
        $display("PREVIEW flush_cycles=%0d cancelled_cycles=%0d", flushed_previews, cancelled_previews);
        $display("PASS tb_scoreboard_completion_queue RV%0d cycles=%0d transfers=%0d cancellations=%0d", XLEN, checked, transfers, cancellations);
        $finish;
    end
endmodule
