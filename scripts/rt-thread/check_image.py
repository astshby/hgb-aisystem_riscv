"""Check the DMA loader contract in the actual linked image (no ELF library)."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
xlen = int(sys.argv[2])
app = sys.argv[3] if len(sys.argv) > 3 else 'smoke'
layout = sys.argv[4] if len(sys.argv) > 4 else 'tcm'
symbols = {}
for line in (root / 'program.nm').read_text().splitlines():
    fields = line.split()
    if len(fields) == 3:
        symbols[fields[2]] = int(fields[0], 16)
assert symbols['_start'] == (0x80000000 if app == 'coremark' and layout == 'ddr' else 0x01000000)
if app == 'coremark' and layout == 'ddr':
    assert symbols['model_bootstrap'] == 0x01000000
assert symbols['hgb_trap'] == symbols['__hot_start'] == 0x0100e000
assert symbols['__hot_load'] == 0x0110c000
end = symbols['__hot_end']
assert 0x0100e000 < end <= 0x01010000
for name in ('rt_hw_context_switch', 'rt_hw_context_switch_to', 'rt_hw_context_switch_exit', 'hgb_dispatch'):
    assert 0x0100e000 <= symbols[name] < end, name
imem = [int(line, 16) for line in (root / 'imem.hex').read_text().split()]
assert all(v == 0 for v in imem[0xe000 // (xlen // 8):]), 'hot code was preloaded into ITCM'
assert symbols['__heap_end'] - symbols['__heap_start'] >= 8192
if app == 'coremark':
    assert symbols['__ddr_start'] == (0x80020000 if layout == 'ddr' else 0x80000000)
    assert symbols['__ddr_start'] <= symbols['static_memblk'] < symbols['__ddr_end']
    assert symbols['__ddr_end'] - symbols['__ddr_start'] >= 2000
    assert symbols['__ddr_end'] <= (0x80030000 if layout == 'ddr' else 0x80010000)
    if layout == 'ddr':
        for name in ('coremark_main', 'core_bench_list', 'core_bench_matrix', 'core_bench_state',
                     'rt_system_scheduler_start', 'hgb_boot', '__bss_start', '__heap_start'):
            assert 0x80000000 <= symbols[name] < 0x80020000, name
        print(f'PASS rt DDR code/data image RV{xlen}')
    print(f"PASS rt CoreMark image RV{xlen}: DDR workspace=0x{symbols['static_memblk']:08x}")
print(f'PASS rt image RV{xlen}: hot={end-0x0100e000} bytes, DMA source=0x0110c000, target initially zero')
