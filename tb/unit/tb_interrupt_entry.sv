// Module: tb_interrupt_entry
// Description: Checks drain qualification and architectural next-PC tracking for interrupts.
module tb_interrupt_entry;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    logic clk = 0, rst = 1, irq_pending, pipeline_busy, retire_valid, interrupt_take;
    mem_wb_t commit_packet;
    redirect_t wb_redirect;
    xlen_t interrupt_pc;
    always #5 clk = ~clk;
    interrupt_entry dut (.*);
    initial begin
        irq_pending = 0;
        pipeline_busy = 0;
        retire_valid = 0;
        commit_packet = '0;
        wb_redirect = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 0;
        irq_pending = 1; #1;
        assert (interrupt_take && interrupt_pc == RESET_VECTOR) else $fatal(1, "empty reset entry");
        pipeline_busy = 1; #1;
        assert (!interrupt_take) else $fatal(1, "interrupt crossed unfinished work");
        // next_pc 可以是已解决的跳转目标，绝不能用 pc+4 替代。
        commit_packet.pc = xlen_t'(32'h100);
        commit_packet.seq_pc = xlen_t'(32'h104);
        commit_packet.next_pc = xlen_t'(32'h300);
        retire_valid = 1;
        @(posedge clk);
        @(negedge clk);
        retire_valid = 0;
        pipeline_busy = 0; #1;
        assert (interrupt_take && interrupt_pc == xlen_t'(32'h300)) else $fatal(1, "branch resume PC");
        wb_redirect.valid = 1;
        wb_redirect.pc = xlen_t'(32'h800);
        @(posedge clk);
        @(negedge clk);
        wb_redirect = '0;
        irq_pending = 0; #1;
        assert (!interrupt_take && interrupt_pc == xlen_t'(32'h800)) else $fatal(1, "trap PC override");
        $display("PASS tb_interrupt_entry RV%0d", XLEN);
        $finish;
    end
endmodule
