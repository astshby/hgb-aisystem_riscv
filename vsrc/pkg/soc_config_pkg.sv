// Package: soc_config_pkg
// Description: Portable physical-address and memory capacity configuration.
// 两种 XLEN 使用相同物理地址表；容量独立于地址窗口，不凭板卡型号推定 DDR 容量。
package soc_config_pkg;
    localparam int unsigned PHYS_ADDR_W = 32;
    localparam int unsigned BOOT_ROM_BYTES = 16 * 1024;
    localparam int unsigned ITCM_BYTES = 64 * 1024;
    localparam int unsigned DTCM_BYTES = 64 * 1024;
    localparam int unsigned DDR_WINDOW_BYTES = 512 * 1024 * 1024;
    localparam int unsigned UART_COUNT = 2;
    localparam int unsigned GPIO_COUNT = 3;
endpackage
