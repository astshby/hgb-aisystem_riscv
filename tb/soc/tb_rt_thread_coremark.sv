// Module: tb_rt_thread_coremark
// Description: Checks RT-Thread CoreMark really visits DDR, DMA-loaded hot code and UART TX.
module tb_rt_thread_coremark;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import bus_types_pkg::*;

    tb_soc_benchmark #(.DDR_BYTES(256 * 1024)) test();
    string ddr_image;
    initial begin
        // 仅此仿真阶段预装模型；不代表 UART 下载或板级 DDR 已初始化。
        if ($value$plusargs("DDR_IMAGE=%s", ddr_image)) begin
            @(negedge test.clk);
            $readmemh(ddr_image, test.g_external.u_external.mem);
        end
    end
    integer hot_bytes;
    integer copied_bytes = 0;
    integer hot_commits = 0;
    integer ddr_reads = 0;
    integer ddr_writes = 0;
    integer uart_edges = 0;
    logic uart_tx_q = 1'b1;

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
            if (test.dut.m_req_valid[2] && test.dut.m_req_ready[2]) begin
                if (test.dut.m_request[2].write) begin
                    assert (test.dut.m_request[2].addr == XLEN'('h0100e000 + copied_bytes))
                        else $fatal(1, "unexpected hot DMA write order");
                    copied_bytes += $countones(test.dut.m_request[2].wstrb);
                end else
                    assert (test.dut.m_request[2].addr >= XLEN'('h0110c000) &&
                            test.dut.m_request[2].addr < XLEN'('h0110c000 + hot_bytes))
                        else $fatal(1, "hot DMA source outside D-TCM load image");
            end
            if (test.commit_valid && test.commit_pc >= XLEN'('h0100e000) &&
                test.commit_pc < XLEN'('h01010000)) begin
                assert (copied_bytes == hot_bytes && test.fence_commits > 0)
                    else $fatal(1, "hot code ran before DMA and FENCE.I");
                hot_commits++;
            end
            if (test.ddr_req_valid && test.ddr_req_ready) begin
                if (test.ddr_request.write) ddr_writes++;
                else ddr_reads++;
            end
            if (test.uart_tx[0] != uart_tx_q) uart_edges++;
            uart_tx_q <= test.uart_tx[0];
        end
    end

    final begin
        if (test.test_pass) begin
            if ($test$plusargs("DDR_CODE_CHECK")) begin
                assert (test.ddr_fetches > 100 && test.cache_hits > 100)
                    else $fatal(1, "missing DDR instruction fetch evidence");
                $display("PASS rt DDR instruction path RV%0d fetches=%0d hits=%0d",
                         XLEN, test.ddr_fetches, test.cache_hits);
            end
            $display("RT COREMARK COVERAGE DMA=%0d/%0d hot=%0d DDR_R=%0d DDR_W=%0d UART_edges=%0d",
                     copied_bytes, hot_bytes, hot_commits, ddr_reads, ddr_writes, uart_edges);
            assert (copied_bytes == hot_bytes && hot_commits > 0 &&
                    ddr_reads > 10 && ddr_writes > 10 && uart_edges > 10)
                else $fatal(1, "missing DMA/DDR/UART evidence");
            $display("PASS rt CoreMark SoC integration RV%0d DMA=%0d DDR_R=%0d DDR_W=%0d UART_edges=%0d",
                     XLEN, copied_bytes, ddr_reads, ddr_writes, uart_edges);
        end
    end
endmodule
