// Module: tb_soc_irq_cdc
// Description: Checks independent IRQ level transfer, simultaneous transitions, clearing, and reset in the actual SoC.
module tb_soc_irq_cdc;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import axi_types_pkg::*;

    logic clk_core = 0, clk_sys = 0, clk_ddr = 0, clk_periph = 0;
    logic reset_async = 1;
    int core_half_ps = 5000, periph_half_ps = 20000;
    logic [2:0] injected_pending = '0;
    logic [2:0] sampled [3] = '{default:'0};
    logic [31:0] gpio_in [3] = '{default:'0};
    int samples = 0, transitions = 0, simultaneous = 0, clears = 0;

    initial begin
        void'($value$plusargs("CORE_HALF_PS=%d", core_half_ps));
        void'($value$plusargs("PERIPH_HALF_PS=%d", periph_half_ps));
        #1ps;
        forever #(core_half_ps * 1ps) clk_core = !clk_core;
    end
    always #6.25ns clk_sys = !clk_sys;
    always #4ns clk_ddr = !clk_ddr;
    initial begin
        #3101ps;
        forever #(periph_half_ps * 1ps) clk_periph = !clk_periph;
    end

    soc_system #(.DDR_BYTES(0), .FLASH_BYTES(0)) dut (
        .clk_core, .clk_sys, .clk_ddr, .clk_periph, .reset_async,
        .ddr_ready(1'b0), .uart_rx(2'b11), .uart_tx(),
        .gpio_in, .gpio_out(), .gpio_oe(), .flash_cs_n(), .flash_sck(),
        .flash_mosi(), .flash_miso(1'b0), .ddr_req(), .ddr_rsp('0),
        .external_req('0), .external_rsp(), .npu_req(), .npu_rsp('0),
        .commit_valid(), .commit_pc(), .commit_inst(), .commit_rd(), .commit_rd_we(),
        .commit_rd_data(), .commit_exception(), .commit_trace(), .dmem_store_fire(),
        .dmem_store_addr(), .dmem_store_data(), .dmem_store_strb()
    );

    // 仅在外设 pending 边界注入电平，实际 SoC 两级同步器和 IRQ 寄存器全部参与。
    // 该用例验证跨域电平契约；各外设产生/清除 pending 的语义由各自 MMIO 测试覆盖。
    always @(posedge clk_core) begin
        if (dut.rst_core) begin
            sampled = '{default:'0};
        end else begin
            sampled[2] = sampled[1];
            sampled[1] = sampled[0];
            sampled[0] = injected_pending;
        end
        #1ps;
        assert (dut.core_pending === sampled[2])
            else $fatal(1, "IRQ capture mismatch input=%b expected=%b actual=%b",
                        injected_pending, sampled[2], dut.core_pending);
        samples++;
    end

    task automatic hold_level(input logic [2:0] value);
        logic [2:0] pending_before;
        @(negedge clk_periph);
        pending_before = dut.core_pending;
        simultaneous += $countones(injected_pending ^ value) > 1;
        clears += |(injected_pending & ~value);
        injected_pending = value;
        transitions++;
        #1ps;
        assert (dut.core_pending === pending_before) else $fatal(1, "IRQ combinational bypass");
        // 接收域三次采样后必须稳定；源保持到下一次外设下降沿。
        repeat (3) @(posedge clk_core);
        #2ps;
        assert (dut.core_pending === value) else $fatal(1, "held IRQ level lost or delayed");
    endtask

    initial begin
        force dut.device_pending = injected_pending;
        // CPU 在 ITCM 自循环，避免随机未初始化取指干扰中断边界检查。
        dut.g_tcm[0].u_ram.g_bank[0].mem[0] = XLEN'(64'h0000006f0000006f);
        dut.g_tcm[0].u_ram.g_bank[1].mem[0] = XLEN'(64'h0000006f0000006f);
        repeat (5) @(negedge clk_periph);
        reset_async = 0;
        wait (!dut.rst_core);
        for (int old_value = 0; old_value < 8; old_value++) begin
            for (int new_value = 0; new_value < 8; new_value++) begin
                hold_level(3'(old_value));
                hold_level(3'(new_value));
            end
        end
        hold_level(3'b111);
        @(negedge clk_periph);
        reset_async = 1;
        repeat (5) @(negedge clk_core);
        assert (dut.core_pending == 0) else $fatal(1, "IRQ reset did not clear pending");
        @(negedge clk_periph);
        reset_async = 0;
        wait (!dut.rst_core);
        repeat (3) @(posedge clk_core);
        #2ps;
        assert (dut.core_pending == 3'b111) else $fatal(1, "held IRQ missing after reset release");
        hold_level(3'b000);
        assert (simultaneous > 0 && clears > 0 && samples > transitions)
            else $fatal(1, "IRQ transition coverage missing");
        $display("PASS tb_soc_irq_cdc RV%0d core_half_ps=%0d periph_half_ps=%0d transitions=%0d simultaneous=%0d clears=%0d samples=%0d reset=1",
                 XLEN, core_half_ps, periph_half_ps, transitions, simultaneous, clears, samples);
        $finish;
    end
    initial begin
        #1ms;
        $fatal(1, "IRQ CDC timeout");
    end
endmodule
