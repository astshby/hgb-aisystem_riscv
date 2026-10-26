// Module: tb_address_decode
// Description: Checks decoder targets and faults against arithmetic region rules at window edges.
module tb_address_decode #(
    parameter int unsigned DDR_BYTES = 65536
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_config_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;

    typedef struct packed {
        logic [64:0] base;
        int unsigned bytes;
        bus_target_e target;
        logic executable, writable, word_only;
    } region_t;

    logic clk = 1'b0;
    bus_req_t request;
    bus_target_e target;
    bus_error_e error;
    region_t regions [15];
    int checks = 0;
    logic [63:0] random_q = 64'h7a19_24b3_1357_2468;

    always #5 clk = ~clk;
    address_decode #(.DDR_BYTES(DDR_BYTES)) dut (.request, .target, .error);

    // 参考规则使用完整区间加法和取模，不使用 DUT 的前缀掩码与省略末端检查。
    task automatic check_address(input logic [63:0] probe);
        logic [64:0] address, end_address;
        int unsigned transfer_bytes;
        bus_target_e want_target;
        bus_error_e want_error;
        region_t selected;
        for (int size = 0; size < 4; size++) begin
            for (int flags = 0; flags < 4; flags++) begin
                @(negedge clk);
                request = '0;
                request.addr = xlen_t'(probe);
                request.size = mem_size_e'(size);
                request.write = 1'(flags);
                request.execute = 1'(flags >> 1);
                address = 65'(request.addr);
                transfer_bytes = 1 << size;
                end_address = address + 65'(transfer_bytes);
                want_target = TARGET_ERROR;
                selected = '0;
                foreach (regions[r]) begin
                    if (regions[r].bytes != 0 && address >= regions[r].base &&
                        address < regions[r].base + 65'(regions[r].bytes)) begin
                        want_target = regions[r].target;
                        selected = regions[r];
                        break;
                    end
                end
                want_error = BUS_OK;
                if (want_target == TARGET_ERROR || address >= (65'd1 << PHYS_ADDR_W))
                    want_error = BUS_DECERR;
                else if (end_address > selected.base + 65'(selected.bytes) ||
                         (address % 65'(transfer_bytes)) != 0 ||
                         (size == 3 && XLEN != 64) ||
                         (request.write && !selected.writable) ||
                         (request.execute && (!selected.executable || request.write || size != 2)) ||
                         (selected.word_only && size != 2) ||
                         (want_target == TARGET_MTIME && size < 2))
                    want_error = BUS_SLVERR;
                #1;
                assert (target == want_target && error == want_error)
                    else $fatal(1, "decode addr=%h size=%0d write=%0d exec=%0d got=%0d/%0d want=%0d/%0d",
                                request.addr, size, request.write, request.execute,
                                target, error, want_target, want_error);
                checks++;
            end
        end
    endtask

    initial begin
        request = '0;
        regions = '{
            '{65'(ROM_BASE), BOOT_ROM_BYTES, TARGET_ROM, 1'b1, 1'b0, 1'b0},
            '{65'(ITCM_BASE), ITCM_BYTES, TARGET_ITCM, 1'b1, 1'b1, 1'b0},
            '{65'(DTCM_BASE), DTCM_BYTES, TARGET_DTCM, 1'b0, 1'b1, 1'b0},
            '{65'(MTIME_BASE), MTIME_WINDOW_BYTES, TARGET_MTIME, 1'b0, 1'b1, 1'b0},
            '{65'(IRQ_BASE), IRQ_WINDOW_BYTES, TARGET_IRQ, 1'b0, 1'b1, 1'b1},
            '{65'(UART0_BASE), MMIO_BYTES, TARGET_UART0, 1'b0, 1'b1, 1'b1},
            '{65'(UART1_BASE), MMIO_BYTES, TARGET_UART1, 1'b0, 1'b1, 1'b1},
            '{65'(TIMER_BASE), MMIO_BYTES, TARGET_TIMER, 1'b0, 1'b1, 1'b1},
            '{65'(GPIO0_BASE), MMIO_BYTES, TARGET_GPIO0, 1'b0, 1'b1, 1'b1},
            '{65'(GPIO1_BASE), MMIO_BYTES, TARGET_GPIO1, 1'b0, 1'b1, 1'b1},
            '{65'(GPIO2_BASE), MMIO_BYTES, TARGET_GPIO2, 1'b0, 1'b1, 1'b1},
            '{65'(DMA_BASE), MMIO_BYTES, TARGET_DMA, 1'b0, 1'b1, 1'b1},
            '{65'(SOC_BASE), MMIO_BYTES, TARGET_SOC, 1'b0, 1'b1, 1'b1},
            '{65'(DDR_BASE), DDR_BYTES, TARGET_DDR, 1'b1, 1'b1, 1'b0},
            '{65'(MM3_BASE), MMIO_BYTES, TARGET_MM3, 1'b0, 1'b1, 1'b1}
        };

        // 每个边界逐字节扫描，组合全部访问大小、读写和取指标志。
        foreach (regions[r]) begin
            for (int offset = -8; offset < 16; offset++)
                check_address(64'(regions[r].base) + 64'(offset));
            for (int offset = -8; offset < 8; offset++)
                check_address(64'(regions[r].base) + 64'(regions[r].bytes) + 64'(offset));
            check_address(64'(regions[r].base) + 64'(regions[r].bytes / 2));
            if (XLEN == 64) begin
                check_address(64'(regions[r].base) | 64'h0000_0001_0000_0000);
                check_address(64'(regions[r].base) | 64'h8000_0000_0000_0000);
            end
        end

        // 固定种子覆盖窗口内部、空洞和物理地址上限，结果可重复。
        for (int sample = 0; sample < 128; sample++) begin
            random_q = random_q * 64'd6364136223846793005 + 64'd1;
            check_address(random_q);
            if (regions[sample % 15].bytes != 0)
                check_address(64'(regions[sample % 15].base) +
                              random_q % 64'(regions[sample % 15].bytes));
        end
        check_address(64'h0000_0000_ffff_fff8);
        check_address(64'h0000_0001_0000_0000);
        check_address(64'hffff_ffff_ffff_ffff);
        $display("PASS tb_address_decode RV%0d DDR_BYTES=%0d checks=%0d", XLEN, DDR_BYTES, checks);
        $finish;
    end
endmodule
