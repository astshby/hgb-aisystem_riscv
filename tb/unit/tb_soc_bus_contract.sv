// Module: tb_soc_bus_contract
// Description: Checks physical decoding, access permissions, and held error responses.
module tb_soc_bus_contract;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_config_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    bus_req_t request;
    bus_target_e target;
    bus_error_e error;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    bus_rsp_t response;
    int checks = 0;
    always #5 clk = ~clk;
    address_decode #(.DDR_BYTES(4096)) u_decode (.*);
    bus_error_slave u_error (.clk, .rst, .req_valid, .req_ready,
                            .req_error(error), .rsp_valid, .rsp_ready, .response);

    task automatic check_access(input xlen_t addr, input mem_size_e size,
        input logic write, execute, input bus_target_e want_target, input bus_error_e want_error);
        request = '0;
        request.addr = addr;
        request.size = size;
        request.write = write;
        request.execute = execute;
        #1;
        assert (target == want_target && error == want_error)
            else $fatal(1, "decode addr=%h target=%0d/%0d error=%0d/%0d",
                        addr, target, want_target, error, want_error);
        checks++;
    endtask

    initial begin
        request = '0;
        req_valid = 1'b0;
        rsp_ready = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        check_access(ROM_BASE, MEM_WORD, 0, 1, TARGET_ROM, BUS_OK);
        check_access(ROM_BASE, MEM_WORD, 1, 0, TARGET_ROM, BUS_SLVERR);
        check_access(BOOT_ROM_BYTES, MEM_WORD, 0, 0, TARGET_ERROR, BUS_DECERR);
        check_access(ITCM_BASE, MEM_WORD, 1, 0, TARGET_ITCM, BUS_OK);
        check_access(ITCM_BASE + ITCM_BYTES - 4, MEM_WORD, 0, 1, TARGET_ITCM, BUS_OK);
        check_access(ITCM_BASE + ITCM_BYTES, MEM_WORD, 0, 0, TARGET_ERROR, BUS_DECERR);
        check_access(DTCM_BASE, MEM_BYTE, 1, 0, TARGET_DTCM, BUS_OK);
        check_access(DTCM_BASE, MEM_WORD, 0, 1, TARGET_DTCM, BUS_SLVERR);
        check_access(DTCM_BASE + 1, MEM_WORD, 0, 0, TARGET_DTCM, BUS_SLVERR);
        check_access(UART0_BASE, MEM_WORD, 0, 0, TARGET_UART0, BUS_OK);
        check_access(UART1_BASE, MEM_WORD, 1, 0, TARGET_UART1, BUS_OK);
        check_access(UART0_BASE, MEM_DWORD, 0, 0, TARGET_UART0, BUS_SLVERR);
        check_access(UART0_BASE, MEM_BYTE, 0, 0, TARGET_UART0, BUS_SLVERR);
        check_access(UART0_BASE, MEM_WORD, 0, 1, TARGET_UART0, BUS_SLVERR);
        check_access(MTIME_BASE + 32'hbff8, MEM_DWORD, 0, 0, TARGET_MTIME,
                     XLEN == 64 ? BUS_OK : BUS_SLVERR);
        check_access(MTIME_BASE + 32'hbffc, MEM_WORD, 0, 0, TARGET_MTIME, BUS_OK);
        check_access(IRQ_BASE, MEM_WORD, 0, 0, TARGET_IRQ, BUS_OK);
        check_access(TIMER_BASE, MEM_WORD, 0, 0, TARGET_TIMER, BUS_OK);
        check_access(GPIO0_BASE, MEM_WORD, 0, 0, TARGET_GPIO0, BUS_OK);
        check_access(GPIO1_BASE, MEM_WORD, 0, 0, TARGET_GPIO1, BUS_OK);
        check_access(GPIO2_BASE, MEM_WORD, 0, 0, TARGET_GPIO2, BUS_OK);
        check_access(DMA_BASE, MEM_WORD, 0, 0, TARGET_DMA, BUS_OK);
        check_access(SOC_BASE, MEM_WORD, 0, 0, TARGET_SOC, BUS_OK);
        check_access(xlen_t'(DDR_BASE), MEM_WORD, 0, 1, TARGET_DDR, BUS_OK);
        check_access(xlen_t'(DDR_BASE + 4096), MEM_WORD, 0, 0, TARGET_ERROR, BUS_DECERR);
        if (XLEN == 64)
            check_access(xlen_t'(64'h0000_0001_1000_0000), MEM_WORD, 0, 0,
                         TARGET_ERROR, BUS_DECERR);

        // 错误从设备只接受一次，反压期间不能因上游地址变化而改变响应。
        @(negedge clk);
        request.addr = xlen_t'(32'h7000_0000);
        req_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        request.addr = ROM_BASE;
        repeat (4) begin
            #1;
            assert (rsp_valid && !req_ready && response.error == BUS_DECERR &&
                    response.rdata == '0) else $fatal(1, "held error response changed");
            @(negedge clk);
        end
        rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        assert (!rsp_valid) else $fatal(1, "error response duplicated");
        $display("PASS tb_soc_bus_contract RV%0d decode_checks=%0d", XLEN, checks);
        $finish;
    end
endmodule
