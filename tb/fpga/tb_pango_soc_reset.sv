// Module: tb_pango_soc_reset
// Description: Independent boot, DDR clock loss and coordinated in-flight FIFO reset.
module tb_pango_soc_reset;
    timeunit 1ns;
    timeprecision 1ps;
    logic ref_clk = 0, clk_core = 0, clk_sys = 0, clk_ddr = 0, clk_periph = 0;
    logic ddr_run = 0, board_reset_n = 0, soc_pll_locked = 0;
    logic ddr_pll_locked = 0, ddr_phy_locked = 0, ddr_ready = 0;
    logic reset_async, ddr_reset_n, rst_core, rst_sys, rst_ddr, rst_periph;
    logic in_valid = 0, in_ready, out_valid, out_ready = 0;
    logic [7:0] in_data = 0, out_data;
    int core_edges = 0;
    always #4ns ref_clk = ~ref_clk;
    always #5ns clk_core = ~clk_core;
    always #6.25ns clk_sys = ~clk_sys;
    always #20ns clk_periph = ~clk_periph;
    always begin
        #4ns;
        if (ddr_run) clk_ddr = ~clk_ddr;
        else clk_ddr = 0;
    end
    pango_soc_reset dut (.*);
    soc_reset_controller domains (.*);
    async_fifo #(.WIDTH(8), .DEPTH(4)) pending (
        .s_clk(clk_sys), .s_rst(rst_sys), .m_clk(clk_ddr), .m_rst(rst_ddr),
        .in_valid, .in_ready, .in_data, .out_valid, .out_ready, .out_data);
    always @(posedge clk_core) if (!rst_core) core_edges++;

    task automatic released;
        wait (!reset_async);
        repeat (6) @(negedge clk_periph);
        assert (!rst_core && !rst_sys && !rst_periph && ddr_reset_n)
            else $fatal(1, "local domains did not release");
    endtask
    task automatic online;
        @(negedge ref_clk);
        ddr_run = 1;
        ddr_pll_locked = 1;
        ddr_phy_locked = 1;
        ddr_ready = 1;
        repeat (40) @(negedge ref_clk);
        assert (!reset_async && !rst_ddr && dut.ddr_armed_q)
            else $fatal(1, "DDR did not arm after calibration");
    endtask
    task automatic enqueue(input logic [7:0] value);
        @(negedge clk_sys);
        in_valid = 1;
        in_data = value;
        do @(posedge clk_sys); while (!in_ready);
        @(negedge clk_sys);
        in_valid = 0;
    endtask
    task automatic check_reset;
        wait (reset_async);
        #1ps;
        assert (reset_async && rst_core && rst_sys && rst_ddr && rst_periph && !ddr_reset_n)
            else $fatal(1, "fault did not reset every domain and DDR controller");
        // DDR IP 接到复位后撤销 lock/ready；该握手在 TB 模拟，不模拟 DDR PHY。
        @(negedge ref_clk);
        ddr_ready = 0;
        ddr_pll_locked = 0;
        ddr_phy_locked = 0;
        repeat (32) @(negedge ref_clk);
        assert (reset_async) else $fatal(1, "reset pulse too short");
    endtask
    task automatic no_ghost_and_retry;
        released();
        online();
        repeat (8) @(negedge clk_ddr);
        assert (!out_valid) else $fatal(1, "discarded epoch produced ghost payload");
        enqueue(8'h5a);
        wait (out_valid);
        @(negedge clk_ddr);
        assert (out_data == 8'h5a) else $fatal(1, "new epoch data mismatch");
        out_ready = 1;
        @(negedge clk_ddr);
        out_ready = 0;
        repeat (6) @(negedge clk_ddr);
        assert (!out_valid) else $fatal(1, "duplicate completion");
    endtask

    initial begin
        repeat (5) @(negedge ref_clk);
        board_reset_n = 1;
        repeat (5) @(negedge ref_clk);
        soc_pll_locked = 1;
        released();
        assert (rst_ddr && core_edges > 0 && !ddr_ready)
            else $fatal(1, "boot waited for stopped DDR clock");
        $display("PASS independent local boot with DDR clock stopped");
        online();
        enqueue(8'ha5);
        wait (out_valid);
        @(negedge ref_clk);
        ddr_phy_locked = 0;
        check_reset();
        no_ghost_and_retry();
        $display("PASS DDR PHY lock loss discards in-flight epoch");
        enqueue(8'ha6);
        wait (out_valid);
        @(negedge ref_clk);
        ddr_ready = 0;
        check_reset();
        no_ghost_and_retry();
        $display("PASS DDR ready loss coordinates all domains");
        enqueue(8'ha7);
        wait (out_valid);
        @(negedge clk_ddr);
        ddr_run = 0;
        wait (reset_async);
        check_reset();
        no_ghost_and_retry();
        $display("PASS silent DDR stop detected by reference watchdog");
        enqueue(8'ha8);
        wait (out_valid);
        @(negedge ref_clk);
        soc_pll_locked = 0;
        check_reset();
        @(negedge ref_clk);
        soc_pll_locked = 1;
        no_ghost_and_retry();
        $display("PASS SoC PLL loss resets DDR and both CDC endpoints");
        $display("PASS pango_soc_reset");
        $finish;
    end
    initial begin
        #100us;
        $fatal(1, "reset supervisor test timeout");
    end
endmodule
