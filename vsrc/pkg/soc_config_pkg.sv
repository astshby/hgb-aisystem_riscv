// Package: soc_config_pkg
// Description: Portable physical-address and memory capacity configuration.
// 两种 XLEN 使用相同物理地址表；容量独立于地址窗口，不凭板卡型号推定 DDR 容量。
package soc_config_pkg;
    localparam int unsigned PHYS_ADDR_W = 32;
    localparam int unsigned BOOT_ROM_BYTES = 16 * 1024;
    localparam int unsigned ITCM_BYTES = 64 * 1024;
    localparam int unsigned DTCM_BYTES = 64 * 1024;
    localparam int unsigned DDR_WINDOW_BYTES = 512 * 1024 * 1024;
    // 固定端口与编号的容量上限；当前实际实例数由 profile 的存在位决定。
    localparam int unsigned UART_COUNT = 2;
    localparam int unsigned GPIO_COUNT = 3;
    // profile 仅决定实例是否存在，不搬移旧窗口或 IRQ 编号；bit 编号对应 bus_target_e。
    localparam int unsigned SOC_PROFILE_FULL = 0;
    localparam int unsigned SOC_PROFILE_LITE = 1;
    localparam logic [15:0] SOC_FULL_PRESENT = 16'h3fff;
    localparam logic [15:0] SOC_LITE_PRESENT = 16'h327f;
    localparam logic [15:0] SOC_DISCOVERY_ABI = 16'd1;
endpackage
