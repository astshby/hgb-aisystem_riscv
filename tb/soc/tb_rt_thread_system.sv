// Module: tb_rt_thread_system
// Description: Standalone RT-Thread on the four-domain SoC with DDR, cache and real DMA hot-code loading.
module tb_rt_thread_system;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    tb_soc_system #(.DDR_BYTES(262144), .FLASH_BYTES(0), .NPU_ENABLE(0),
        .CLOCK_PROFILE(1), .UART_DIVISOR(217)) u_test();
    int hot_retired = 0;
    int ddr_retired = 0;
    int trap_entries = 0;

    initial begin
        @(negedge u_test.reset_async);
        // ITCM 最后 8 KiB 必须由启动 DMA 填充，禁止仿真预装热代码。
        for (int word_index = 'he000 / DBUS_BYTES; word_index < 'h10000 / DBUS_BYTES; word_index++) begin
            if (word_index[0])
                assert (u_test.dut.g_tcm[0].u_ram.g_bank[1].mem[word_index / 2] == 0)
                    else $fatal(1, "RT hot code preloaded into bank 1");
            else
                assert (u_test.dut.g_tcm[0].u_ram.g_bank[0].mem[word_index / 2] == 0)
                    else $fatal(1, "RT hot code preloaded into bank 0");
        end
    end
    always @(posedge u_test.clk_core) begin
        if (!u_test.dut.rst_core) begin
            for (int lane = 0; lane < 2; lane++) begin
                if (u_test.commit_trace[lane].valid) begin
                    if (u_test.commit_trace[lane].pc >= 'h80000000 && u_test.commit_trace[lane].pc < 'h80040000)
                        ddr_retired++;
                    if (u_test.commit_trace[lane].pc >= 'h0100e000 && u_test.commit_trace[lane].pc < 'h01010000)
                        hot_retired++;
                    if (u_test.commit_trace[lane].pc == 'h0100e000) trap_entries++;
                end
            end
        end
    end
    final begin
        if (u_test.test_pass) begin
            assert (hot_retired > 100 && ddr_retired > 100 && trap_entries > 10 &&
                    u_test.ddr_fetches > 0 && u_test.cache_hits > 0 && u_test.dcache_hits > 0 &&
                    u_test.dma_reads > 0 && u_test.dma_writes > 0 && u_test.fence_commits > 0)
                else $fatal(1, "RT full-system execution coverage missing");
            $display("PASS rt four-domain RV%0d hot=%0d DDR=%0d traps=%0d I_hits=%0d D_hits=%0d DMA_reads=%0d DMA_writes=%0d",
                XLEN, hot_retired, ddr_retired, trap_entries, u_test.cache_hits, u_test.dcache_hits,
                u_test.dma_reads, u_test.dma_writes);
        end
    end
endmodule
