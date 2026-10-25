// Module: test_soc_clocks
// Description: BSP helper read-boundary, malformed discovery and timebase divider cases.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
static uint32_t words[32], reads, forbidden_reads;
static int extension_allowed;
static uint32_t mock_read(uintptr_t address)
{
    assert(address >= 0x10040000u && address < 0x10040080u);
    unsigned offset = (unsigned)(address - 0x10040000u);
    assert(!(offset & 3u));
    ++reads;
    if (!extension_allowed && offset >= 0x50) ++forbidden_reads;
    return words[offset / 4];
}
#define HGB_SOC_CLOCK_READ32(address) mock_read(address)
#include "../../software/common/soc_clocks.h"
int main(void)
{
    struct hgb_soc_clocks c;
    uint32_t discovery = 0x00010001u;
    words[1] = 50000000;
    assert(!hgb_soc_read_clocks(0x10040000u, discovery, &c));
    assert(c.core_hz == 50000000 && c.sys_hz == 50000000 && c.ddr_hz == 50000000 &&
           c.periph_hz == 50000000 && c.timer_hz == 50000000);
    assert(reads == 1 && forbidden_reads == 0);
    words[1] = 0;
    assert(hgb_soc_read_clocks(0x10040000u, discovery, &c));
    assert(reads == 2 && forbidden_reads == 0);
    extension_allowed = 1; discovery |= HGB_SOC_CLOCK_INFO_PRESENT;
    words[1] = 125000000;
    words[0x50/4] = HGB_SOC_CLOCK_INFO_V1;
    words[0x54/4] = 100000000; words[0x58/4] = 80000000;
    words[0x5c/4] = 125000000; words[0x60/4] = words[0x64/4] = 25000000;
    assert(!hgb_soc_read_clocks(0x10040000u, discovery, &c));
    assert(c.core_hz == 100000000 && c.sys_hz == 80000000 && c.ddr_hz == 125000000 &&
           c.periph_hz == 25000000 && c.timer_hz == 25000000);
    assert(reads == 9);
    for (unsigned off = 0x54; off <= 0x64; off += 4) {
        uint32_t old = words[off/4]; words[off/4] = 0;
        assert(hgb_soc_read_clocks(0x10040000u, discovery, &c)); words[off/4] = old;
    }
    words[0x64/4] = 100000000;
    assert(hgb_soc_read_clocks(0x10040000u, discovery, &c)); words[0x64/4] = 25000000;
    words[0x50/4] = 0x0002001fu;
    assert(hgb_soc_read_clocks(0x10040000u, discovery, &c));
    assert(hgb_soc_discovery_valid(0x7ffe, discovery));
    assert(!hgb_soc_discovery_valid(0x7ffe, discovery | 0x200));
    assert(!hgb_soc_discovery_valid(0x10000, discovery));
    assert(hgb_soc_uart_divisor(25000000, 1000000) == 25);
    assert(hgb_soc_uart_divisor(25000000, 115200) == 217);
    assert(!hgb_soc_uart_divisor(25000000, 0));
    assert(!hgb_soc_uart_divisor(25000000, 6250001));
    assert(hgb_soc_uart_divisor(25000000, 6250000) == 4);
    assert(hgb_soc_spi_divider(80000000, 12000000) == 4);
    assert(hgb_soc_spi_divider(100000000, 12000000) == 5);
    assert(hgb_soc_spi_divider(80000000, 40000000) == 1);
    assert(hgb_soc_spi_divider(80000000, UINT32_MAX) == 1);
    assert(hgb_soc_spi_divider(UINT32_MAX, UINT32_MAX) == 1);
    assert(hgb_soc_spi_divider(131070, 1) == 65535);
    assert(!hgb_soc_spi_divider(131071, 1));
    assert(!hgb_soc_spi_divider(80000000, 0));
    assert(!hgb_soc_spi_divider(0, 12000000));
    puts("PASS soc_clocks legacy/extension/negative/dividers");
    return 0;
}
