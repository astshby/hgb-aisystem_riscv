"""Validate the standalone DDR RT-Thread image and DMA hot-code placement."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
xlen = int(sys.argv[2])
symbols = {}
for line in (root / 'program.nm').read_text().splitlines():
    fields = line.split()
    if len(fields) == 3:
        symbols[fields[2]] = int(fields[0], 16)
assert symbols['_start'] == 0x80000000
assert symbols['model_bootstrap'] == 0x01000000
assert symbols['hgb_trap'] == symbols['__hot_start'] == 0x0100e000
assert symbols['__hot_load'] == 0x0110c000
end = symbols['__hot_end']
assert 0x0100e000 < end <= 0x01010000
for name in ('rt_hw_context_switch', 'rt_hw_context_switch_to', 'rt_hw_context_switch_exit', 'hgb_dispatch'):
    assert 0x0100e000 <= symbols[name] < end, name
for name in ('rt_system_scheduler_start', 'hgb_boot', '__bss_start', '__heap_start'):
    assert 0x80000000 <= symbols[name] < 0x80040000, name
imem = [int(line, 16) for line in (root / 'imem.hex').read_text().split()]
assert all(v == 0 for v in imem[0xe000 // (xlen // 8):]), 'hot code was preloaded into ITCM'
assert symbols['__heap_end'] - symbols['__heap_start'] >= 8192
print(f'PASS rt image RV{xlen}: DDR code/data/heap, hot={end-0x0100e000} bytes loaded by DMA')
