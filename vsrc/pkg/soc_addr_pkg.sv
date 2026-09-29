// Package: soc_addr_pkg
// Description: Shared physical address map for CPU, DMA, simulation, and board wrappers.
// 此处只有常量；访问范围、大小与权限在 address_decode 模块中检查。
package soc_addr_pkg;
    localparam logic [31:0] ROM_BASE   = 32'h0000_0000;
    localparam logic [31:0] ITCM_BASE  = 32'h0100_0000;
    localparam logic [31:0] DTCM_BASE  = 32'h0110_0000;
    localparam logic [31:0] MTIME_BASE = 32'h0200_0000;
    localparam logic [31:0] IRQ_BASE   = 32'h0c00_0000;
    localparam logic [31:0] UART0_BASE = 32'h1000_0000;
    localparam logic [31:0] UART1_BASE = 32'h1000_1000;
    localparam logic [31:0] TIMER_BASE = 32'h1001_0000;
    localparam logic [31:0] GPIO0_BASE = 32'h1002_0000;
    localparam logic [31:0] GPIO1_BASE = 32'h1002_1000;
    localparam logic [31:0] GPIO2_BASE = 32'h1002_2000;
    localparam logic [31:0] DMA_BASE   = 32'h1003_0000;
    localparam logic [31:0] SOC_BASE   = 32'h1004_0000;
    localparam logic [31:0] DDR_BASE   = 32'h8000_0000;
    localparam int unsigned MMIO_BYTES = 4096;
    localparam int unsigned MTIME_WINDOW_BYTES = 64 * 1024;
    localparam int unsigned IRQ_WINDOW_BYTES = 4 * 1024 * 1024;
endpackage
