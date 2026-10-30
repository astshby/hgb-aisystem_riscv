// Module: tb_all_system
// Description: Real RV32/RV64 boot through simultaneous accelerator windows, native IRQs and DDR master traffic.
module tb_all_system #(
    parameter ITCM_INIT_FILE = ""
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;
    logic clk_core = 0, clk_sys = 0, clk_ddr = 0, clk_periph = 0;
    logic clk_yolo = 0, clk_minimind = 0, clk_pixel = 0, reset_async = 1;
    always #5556ps clk_core = !clk_core;
    always #5000ps clk_sys = !clk_sys;
    always #4000ps clk_ddr = !clk_ddr;
    always #8333ps clk_periph = !clk_periph;
    always #5882ps clk_yolo = !clk_yolo;
    always #6667ps clk_minimind = !clk_minimind;
    always #3367ps clk_pixel = !clk_pixel;
    axi_req_t ddr_req;
    axi_rsp_t ddr_rsp;
    logic [31:0] gpio_in [3], gpio_out [3], gpio_oe [3];
    logic [1:0] uart_tx, accelerator_irq;
    logic commit_valid, commit_exception;
    int successful_rounds = 0, mini_reads = 0, mini_writes = 0;
    soc_all_system #(.DDR_BYTES(65536), .MM3_MAC_LANES(2), .ITCM_INIT_FILE(ITCM_INIT_FILE)) dut (
        .clk_core, .clk_sys, .clk_ddr, .clk_periph, .clk_yolo, .clk_minimind, .clk_pixel,
        .reset_async, .ddr_ready(1'b1), .uart_rx(2'b11), .uart_tx,
        .gpio_in, .gpio_out, .gpio_oe, .ddr_req, .ddr_rsp,
        .hdmi_sda_in(1'b1), .hdmi_scl(), .hdmi_sda_drive_low(), .hdmi_reset_n(),
        .video_hs(), .video_vs(), .video_de(), .video_rgb(), .accelerator_irq,
        .commit_valid, .commit_pc(), .commit_inst(), .commit_rd(), .commit_rd_we(),
        .commit_rd_data(), .commit_exception);
    axi_system_memory_model u_ram (.clk(clk_ddr), .rst(dut.u_soc.rst_ddr), .stall(1'b0),
        .req(ddr_req), .rsp(ddr_rsp), .fault_read_addr(32'hffffffff), .fault_write_addr(32'hffffffff));
    initial begin
        for (int i = 0; i < 3; i++) gpio_in[i] = '0;
        for (int i = 0; i < 65536; i++) u_ram.mem[i] = 0;
        u_ram.mem[0] = 2;
        u_ram.mem[64] = 3;
        u_ram.mem[131] = 8'h40;
        repeat (12) @(negedge clk_core);
        reset_async = 0;
    end
    always @(posedge clk_sys) if (!reset_async) begin
        if (dut.external_masters[0].ar_valid && dut.external_responses[0].ar_ready) mini_reads++;
        if (dut.external_masters[0].aw_valid && dut.external_responses[0].aw_ready) mini_writes++;
    end
    initial begin
        forever begin
            @(posedge clk_core);
            if (!reset_async && dut.u_soc.dmem_store_fire && dut.u_soc.dmem_store_addr == XLEN'(32'h01100000)) begin
                assert (dut.u_soc.dmem_store_data == XLEN'(32'h600d0001))
                    else $fatal(1, "all firmware failure stage=%0d", dut.u_soc.dmem_store_data);
                successful_rounds++;
                if (successful_rounds == 2) begin
                    assert (mini_reads >= 6 && mini_writes >= 4)
                        else $fatal(1, "MiniMind DDR master did not execute reads=%0d writes=%0d", mini_reads, mini_writes);
                    $display("PASS tb_all_system RV%0d rounds=%0d MiniMind_AR=%0d MiniMind_AW=%0d native_IRQ=8,9", XLEN, successful_rounds, mini_reads, mini_writes);
                    $finish;
                end
                @(negedge clk_core);
                reset_async = 1;
                repeat (12) @(negedge clk_core);
                assert (accelerator_irq == 0) else $fatal(1, "accelerator IRQ survived common reset");
                reset_async = 0;
            end
        end
    end
    always @(negedge clk_core) if (!reset_async && commit_valid && commit_exception)
        $fatal(1, "unexpected real-core trap");
    initial begin #20ms; $fatal(1, "all system timeout"); end
endmodule
