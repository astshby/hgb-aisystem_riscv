// Module: address_decode
// Description: Decodes implemented ranges and validates access size and region permissions.
// 无 MMU；缓存和互连共用完整地址校验，访问须落在同一区间，不能回绕到 RAM 低位。
module address_decode #(
    parameter int unsigned DDR_BYTES = 0
) (
    input  bus_types_pkg::bus_req_t request,
    output bus_types_pkg::bus_target_e target,
    output bus_types_pkg::bus_error_e error
);
    import core_config_pkg::*;
    import core_types_pkg::*;
    import soc_config_pkg::*;
    import soc_addr_pkg::*;
    import bus_types_pkg::*;

    logic [64:0] address, access_end, region_base, region_end;
    logic executable, writable, word_only;

    // 译码只选择目标；执行/写权限与完整访问边界在后一个功能块处理。
    always_comb begin
        address = 65'(request.addr);
        access_end = address + (65'd1 << request.size);
        target = TARGET_ERROR;
        region_base = '0;
        region_end = '0;
        executable = 1'b0;
        writable = 1'b1;
        word_only = 1'b0;
        if (address < ROM_BASE + BOOT_ROM_BYTES) begin
            target = TARGET_ROM;
            region_base = ROM_BASE;
            region_end = ROM_BASE + BOOT_ROM_BYTES;
            executable = 1'b1;
            writable = 1'b0;
        end else if (address >= ITCM_BASE && address < ITCM_BASE + ITCM_BYTES) begin
            target = TARGET_ITCM;
            region_base = ITCM_BASE;
            region_end = ITCM_BASE + ITCM_BYTES;
            executable = 1'b1;
        end else if (address >= DTCM_BASE && address < DTCM_BASE + DTCM_BYTES) begin
            target = TARGET_DTCM;
            region_base = DTCM_BASE;
            region_end = DTCM_BASE + DTCM_BYTES;
        end else if (address >= MTIME_BASE && address < MTIME_BASE + MTIME_WINDOW_BYTES) begin
            target = TARGET_MTIME;
            region_base = MTIME_BASE;
            region_end = MTIME_BASE + MTIME_WINDOW_BYTES;
        end else if (address >= IRQ_BASE && address < IRQ_BASE + IRQ_WINDOW_BYTES) begin
            target = TARGET_IRQ;
            region_base = IRQ_BASE;
            region_end = IRQ_BASE + IRQ_WINDOW_BYTES;
            word_only = 1'b1;
        end else if (DDR_BYTES != 0 && address >= DDR_BASE &&
                     address < (65'(DDR_BASE) + 65'(DDR_BYTES))) begin
            target = TARGET_DDR;
            region_base = DDR_BASE;
            region_end = 65'(DDR_BASE) + 65'(DDR_BYTES);
            executable = 1'b1;
        end else begin
            word_only = 1'b1;
            region_base = address & ~65'hfff;
            region_end = region_base + MMIO_BYTES;
            unique case (region_base)
                UART0_BASE: target = TARGET_UART0;
                UART1_BASE: target = TARGET_UART1;
                TIMER_BASE: target = TARGET_TIMER;
                GPIO0_BASE: target = TARGET_GPIO0;
                GPIO1_BASE: target = TARGET_GPIO1;
                GPIO2_BASE: target = TARGET_GPIO2;
                DMA_BASE: target = TARGET_DMA;
                SOC_BASE: target = TARGET_SOC;
                default: ;
            endcase
        end
    end

    // 普通 MMIO 只接受对齐的 32 位访问；mtime 保留 RV64 原子 64 位访问能力。
    always_comb begin
        error = BUS_OK;
        if (target == TARGET_ERROR || address >= (65'd1 << PHYS_ADDR_W))
            error = BUS_DECERR;
        else if ((access_end > region_end) || (address < region_base) ||
                 ((address & ((65'd1 << request.size) - 1)) != 0) ||
                 ((request.size == MEM_DWORD) && (XLEN != 64)) ||
                 (request.write && !writable) ||
                 (request.execute && (!executable || request.write || request.size != MEM_WORD)) ||
                 (word_only && request.size != MEM_WORD) ||
                 (target == TARGET_MTIME && request.size < MEM_WORD))
            error = BUS_SLVERR;
    end
endmodule
