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

    // 固定窗口的容量均为二次幂，掩码比较对应的高地址位。
    localparam logic [64:0] ROM_MASK = ~65'(BOOT_ROM_BYTES - 1);
    localparam logic [64:0] ITCM_MASK = ~65'(ITCM_BYTES - 1);
    localparam logic [64:0] DTCM_MASK = ~65'(DTCM_BYTES - 1);
    localparam logic [64:0] MTIME_MASK = ~65'(MTIME_WINDOW_BYTES - 1);
    localparam logic [64:0] IRQ_MASK = ~65'(IRQ_WINDOW_BYTES - 1);
    localparam logic [64:0] MMIO_MASK = ~65'(MMIO_BYTES - 1);
    localparam logic [64:0] DDR_END = 65'(DDR_BASE) + 65'(DDR_BYTES);

    logic [64:0] address;
    // 参数设定命中区域（其实就是枚举常量）
    logic [TARGET_MM3:TARGET_ROM] region_hit;
    logic [2:0] alignment_mask;
    logic executable, writable, word_only, is_word;
    logic misaligned, ddr_boundary_error;

    assign address = 65'(request.addr);
    assign is_word = (request.size == MEM_WORD);

    // 各个固定窗口独立比较；低位仍传给设备作偏移。
    assign region_hit[TARGET_ROM] = (address & ROM_MASK) == 65'(ROM_BASE);
    assign region_hit[TARGET_ITCM] = (address & ITCM_MASK) == 65'(ITCM_BASE);
    assign region_hit[TARGET_DTCM] = (address & DTCM_MASK) == 65'(DTCM_BASE);
    assign region_hit[TARGET_MTIME] = (address & MTIME_MASK) == 65'(MTIME_BASE);
    assign region_hit[TARGET_IRQ] = (address & IRQ_MASK) == 65'(IRQ_BASE);
    // 用高位选择 4 KiB 外设窗口，低 12 位仍由设备解释为寄存器偏移。
    assign region_hit[TARGET_UART0] = (address & MMIO_MASK) == 65'(UART0_BASE);
    assign region_hit[TARGET_UART1] = (address & MMIO_MASK) == 65'(UART1_BASE);
    assign region_hit[TARGET_TIMER] = (address & MMIO_MASK) == 65'(TIMER_BASE);
    assign region_hit[TARGET_GPIO0] = (address & MMIO_MASK) == 65'(GPIO0_BASE);
    assign region_hit[TARGET_GPIO1] = (address & MMIO_MASK) == 65'(GPIO1_BASE);
    assign region_hit[TARGET_GPIO2] = (address & MMIO_MASK) == 65'(GPIO2_BASE);
    assign region_hit[TARGET_DMA] = (address & MMIO_MASK) == 65'(DMA_BASE);
    assign region_hit[TARGET_SOC] = (address & MMIO_MASK) == 65'(SOC_BASE);
    assign region_hit[TARGET_MM3] = (address & MMIO_MASK) == 65'(MM3_BASE);
    // DDR 实际容量未必为二次幂；满足窗口对齐时使用高位匹配，否则保留起始地址范围比较。
    if (DDR_BYTES == 0) begin : g_no_ddr
        assign region_hit[TARGET_DDR] = 1'b0;
    end else if (((DDR_BYTES & (DDR_BYTES - 1)) == 0) &&
                 ((DDR_BASE & (DDR_BYTES - 1)) == 0)) begin : g_ddr_prefix
        assign region_hit[TARGET_DDR] = (address & ~65'(DDR_BYTES - 1)) == 65'(DDR_BASE);
    end else begin : g_ddr_range
        assign region_hit[TARGET_DDR] = address >= 65'(DDR_BASE) && address < DDR_END;
    end

    // 译码只选择目标；执行/写权限与完整访问边界在后一个功能块处理。
    // 各区域互不重叠，命中判断并行产生；unique 在仿真中检查多区域同时命中。
    always_comb begin
        target = TARGET_ERROR;
        unique case (1'b1)
            region_hit[TARGET_ROM]: target = TARGET_ROM;
            region_hit[TARGET_ITCM]: target = TARGET_ITCM;
            region_hit[TARGET_DTCM]: target = TARGET_DTCM;
            region_hit[TARGET_MTIME]: target = TARGET_MTIME;
            region_hit[TARGET_IRQ]: target = TARGET_IRQ;
            region_hit[TARGET_UART0]: target = TARGET_UART0;
            region_hit[TARGET_UART1]: target = TARGET_UART1;
            region_hit[TARGET_TIMER]: target = TARGET_TIMER;
            region_hit[TARGET_GPIO0]: target = TARGET_GPIO0;
            region_hit[TARGET_GPIO1]: target = TARGET_GPIO1;
            region_hit[TARGET_GPIO2]: target = TARGET_GPIO2;
            region_hit[TARGET_DMA]: target = TARGET_DMA;
            region_hit[TARGET_SOC]: target = TARGET_SOC;
            region_hit[TARGET_DDR]: target = TARGET_DDR;
            region_hit[TARGET_MM3]: target = TARGET_MM3;
            default: ;
        endcase
    end
    // 默认不可取指、可写；普通内存支持字节/半字/字及 RV64 双字，IRQ/MMIO 只支持字。
    assign executable = region_hit[TARGET_ROM] || region_hit[TARGET_ITCM] || region_hit[TARGET_DDR];
    assign writable = !region_hit[TARGET_ROM];
    assign word_only = region_hit[TARGET_MM3] || region_hit[TARGET_IRQ] || (|region_hit[TARGET_SOC:TARGET_UART0]);

    // 访问自然对齐；固定窗口和 8 B 对齐的 DDR 末端无需逐次算访问终点。
    always_comb begin
        unique case (request.size)
            MEM_BYTE: alignment_mask = 3'b000;
            MEM_HALF: alignment_mask = 3'b001;
            MEM_WORD: alignment_mask = 3'b011;
            MEM_DWORD: alignment_mask = 3'b111;
            default: alignment_mask = '0;
        endcase
    end
    assign misaligned = |(address[2:0] & alignment_mask);
    // 非 8 B 整数倍的 DDR 仍检查末字节，防止边界处跨出有效容量。
    if ((DDR_BYTES & 7) == 0) begin : g_ddr_aligned_end
        assign ddr_boundary_error = 1'b0;
    end else begin : g_ddr_partial_end
        assign ddr_boundary_error = region_hit[TARGET_DDR] &&
            ({address[64:3], (address[2:0] | alignment_mask)} >= DDR_END);
    end

    // 区域选中后只检查本次访问的大小、权限与边界；未映射地址优先报译码错误。
    always_comb begin
        error = BUS_OK;
        // 未映射或超出物理地址范围返回译码错误。
        if (target == TARGET_ERROR || (|address[64:PHYS_ADDR_W]))
            error = BUS_DECERR;
        // 已映射的访问再检查对齐、大小、写权限与执行权限。
        else if (misaligned || ddr_boundary_error ||
                 ((request.size == MEM_DWORD) && (XLEN != 64)) ||
                 (request.write && !writable) ||
                 (request.execute && (!executable || request.write)) ||
                 (!is_word && (request.execute || word_only)) ||
                 (region_hit[TARGET_MTIME] && request.size < MEM_WORD))
            error = BUS_SLVERR;
    end

`ifndef SYNTHESIS
    // 高位译码和省略跨界检查依赖这些配置条件；容量改变时必须重新确认。
    initial begin
        assert ((DDR_BASE & 7) == 0)
            else $fatal(1, "DDR base requires 8-byte alignment");
        assert (BOOT_ROM_BYTES >= 8 && (BOOT_ROM_BYTES & (BOOT_ROM_BYTES - 1)) == 0 &&
                (ROM_BASE & (BOOT_ROM_BYTES - 1)) == 0)
            else $fatal(1, "ROM requires an aligned power-of-two window of at least 8 bytes");
        assert (ITCM_BYTES >= 8 && (ITCM_BYTES & (ITCM_BYTES - 1)) == 0 &&
                (ITCM_BASE & (ITCM_BYTES - 1)) == 0)
            else $fatal(1, "ITCM requires an aligned power-of-two window of at least 8 bytes");
        assert (DTCM_BYTES >= 8 && (DTCM_BYTES & (DTCM_BYTES - 1)) == 0 &&
                (DTCM_BASE & (DTCM_BYTES - 1)) == 0)
            else $fatal(1, "DTCM requires an aligned power-of-two window of at least 8 bytes");
        assert (MTIME_WINDOW_BYTES >= 8 && (MTIME_WINDOW_BYTES & (MTIME_WINDOW_BYTES - 1)) == 0 &&
                (MTIME_BASE & (MTIME_WINDOW_BYTES - 1)) == 0)
            else $fatal(1, "MTIME requires an aligned power-of-two window of at least 8 bytes");
        assert (IRQ_WINDOW_BYTES >= 8 && (IRQ_WINDOW_BYTES & (IRQ_WINDOW_BYTES - 1)) == 0 &&
                (IRQ_BASE & (IRQ_WINDOW_BYTES - 1)) == 0)
            else $fatal(1, "IRQ requires an aligned power-of-two window of at least 8 bytes");
        assert (MMIO_BYTES >= 8 && (MMIO_BYTES & (MMIO_BYTES - 1)) == 0 &&
                ((UART0_BASE | UART1_BASE | TIMER_BASE | GPIO0_BASE | GPIO1_BASE |
                  GPIO2_BASE | DMA_BASE | SOC_BASE) & (MMIO_BYTES - 1)) == 0)
            else $fatal(1, "MMIO requires aligned power-of-two windows of at least 8 bytes");
    end
`endif
endmodule
