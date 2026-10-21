// Module: tb_rt_thread
// Description: Passive checks for DMA-loaded RT-Thread hot code on the existing SoC runner.
module tb_rt_thread #(
    parameter bit LOCAL_TCM_ENABLE = 1'b0,
    parameter bit CACHE_BLOCK_ENABLE = 1'b0,
    parameter bit DMA_WIDE_ENABLE = 1'b0,
    parameter bit DMA_BLOCK_ENABLE = 1'b0,
    parameter int unsigned SOC_PROFILE = soc_config_pkg::SOC_PROFILE_FULL
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import bus_types_pkg::*;
    tb_soc_benchmark #(.LOCAL_TCM_ENABLE(LOCAL_TCM_ENABLE), .SOC_PROFILE(SOC_PROFILE),
        .CACHE_BLOCK_ENABLE(CACHE_BLOCK_ENABLE), .DMA_WIDE_ENABLE(DMA_WIDE_ENABLE),
        .DMA_BLOCK_ENABLE(DMA_BLOCK_ENABLE)) test();

    integer hot_bytes;
    integer copied_bytes = 0;
    integer hot_commits = 0;
    integer trap_entries = 0;
    integer dma_responses = 0;
    logic itcm_accepted = 0;
    integer itcm_accept_count = 0;

    initial begin
        if (!$value$plusargs("HOT_BYTES=%d", hot_bytes) || hot_bytes <= 0 || hot_bytes > 8192)
            $fatal(1, "missing/invalid HOT_BYTES");
        @(negedge test.rst);
        for (int i = 'he000 / DBUS_BYTES; i < 'h10000 / DBUS_BYTES; i++)
            assert (test.dut.u_itcm.mem[i] == '0)
                else $fatal(1, "hot region must be empty before DMA");
    end

    always @(posedge test.clk) begin
        if (!test.rst) begin
            // 验证 bank 接受请求后下一拍响应，不把仲裁等待误算为 RAM 延迟。
            if (itcm_accepted)
                assert (test.dut.tcm_rsp_valid[0]) else $fatal(1, "TCM bank response not one cycle");
            itcm_accepted <= test.dut.tcm_req_valid[0] && test.dut.tcm_req_ready[0];
            if (test.dut.tcm_req_valid[0] && test.dut.tcm_req_ready[0]) itcm_accept_count++;
            if (test.dut.m_req_valid[2] && test.dut.m_req_ready[2]) begin
                if (test.dut.m_request[2].write) begin
                    assert (test.dut.m_request[2].addr == XLEN'('h0100e000 + copied_bytes))
                        else $fatal(1, "unexpected DMA destination/order");
                    copied_bytes += $countones(test.dut.m_request[2].wstrb);
                    assert (copied_bytes <= hot_bytes) else $fatal(1, "DMA wrote outside hot image");
                end else begin
                    assert (test.dut.m_request[2].addr >= XLEN'('h0110c000) &&
                            test.dut.m_request[2].addr < XLEN'('h0110c000 + hot_bytes))
                        else $fatal(1, "DMA source outside load image");
                end
            end
            if (test.dut.m_rsp_valid[2] && test.dut.m_rsp_ready[2]) begin
                assert (test.dut.m_response[2].error == BUS_OK) else $fatal(1, "DMA bus error");
                dma_responses++;
            end
            if (test.dmem_store_fire)
                assert (test.dmem_store_addr < XLEN'('h0100e000) ||
                        test.dmem_store_addr >= XLEN'('h01010000))
                    else $fatal(1, "CPU must not copy hot code instead of DMA");
            for (int lane = 0; lane < 2; lane++)
                if (test.commit_trace[lane].valid && test.commit_trace[lane].pc >= XLEN'('h0100e000) &&
                    test.commit_trace[lane].pc < XLEN'('h01010000)) begin
                    assert (copied_bytes == hot_bytes && test.fence_commits > 0)
                        else $fatal(1, "hot code executed before DMA + FENCE.I");
                    hot_commits++;
                    if (test.commit_trace[lane].pc == XLEN'('h0100e000)) trap_entries++;
                end
        end
    end
    final begin
        if (test.test_pass) begin
            assert (copied_bytes == hot_bytes && hot_commits > 100 && trap_entries > 10 &&
                    dma_responses > 0 && itcm_accept_count > 0 && test.ddr_fetches == 0 && test.cache_hits == 0)
                else $fatal(1, "missing DMA/TCM/interrupt coverage");
            $display("PASS rt hardware RV%0d DMA_bytes=%0d hot_commits=%0d traps=%0d one_cycle_TCM_bank",
                     XLEN, copied_bytes, hot_commits, trap_entries);
        end
    end
endmodule
