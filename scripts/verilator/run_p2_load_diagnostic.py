#!/usr/bin/env python3
"""Separate IRQ-only and continuously submitted DMA diagnostics; no CoreMark score."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('p2_coremark', ROOT / 'scripts/verilator/run_p2_coremark.py')
p2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p2)
SOURCES = [Path(name) for name in (
    'tb/software/p2_load_diagnostic.c', 'benchmark/bsp/crt0.S', 'benchmark/bsp/runtime.c',
    'benchmark/bsp/softarith.c', 'benchmark/bsp/benchmark_runtime.h', 'benchmark/bsp/link_soc.ld',
    'software/common/soc_clocks.h', 'software/common/soc_capabilities.h',
    'scripts/verilator/build_benchmark_image.sh', 'scripts/verilator/verilog_hex_to_mem.py',
    'scripts/verilator/run_p2_load_diagnostic.py')]


def images(root, xlen, mode, tools):
    root.mkdir(parents=True, exist_ok=True)
    # 不同 clock 的重放可共享同一软件镜像；首次构建锁住该镜像，不能读取半写 manifest。
    with (root / f'.rv{xlen}-{mode}.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _images_locked(root, xlen, mode, tools)


def _images_locked(root, xlen, mode, tools):
    directory = root / f'rv{xlen}-{mode}'
    if directory.exists():
        manifest = json.loads((directory / 'image.json').read_text())
        if manifest['xlen'] != xlen or manifest['mode'] != mode:
            raise ValueError('diagnostic image selection mismatch')
        p2.verify_hashes(directory, manifest['images'])
        p2.verify_hashes(directory / 'source', manifest['source_sha256'])
        return directory, manifest
    directory.mkdir(parents=True, exist_ok=False)
    sources = p2.copy_sources(SOURCES, directory / 'source')
    command = ['bash', 'scripts/verilator/build_benchmark_image.sh', str(xlen), str(directory),
               '-Wall', '-Wextra', '-Werror', '-DP2_DIAGNOSTIC_IRQ_ONLY=' + str(int(mode == 'irq_only')),
               'benchmark/bsp/crt0.S', 'benchmark/bsp/runtime.c', 'benchmark/bsp/softarith.c',
               'tb/software/p2_load_diagnostic.c']
    environment = {**os.environ, 'SOC': '1', 'SOC_DDR': '0', 'RISCV_TOOL_ROOT': str(tools)}
    with (directory / 'build.log').open('x') as log:
        log.write('$ ' + shlex.join(command) + '\n'); log.flush()
        subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    p2.verify_hashes(Path('.'), sources)
    nm = subprocess.check_output([str(tools / 'riscv64-unknown-elf-nm'), '-n', str(directory / 'program.elf')], text=True)
    symbols = p2.symbols_from_nm(nm)
    if not 0x01100000 <= symbols['p2_diag_roi'] < 0x01110000:
        raise ValueError('diagnostic marker is outside DTCM')
    manifest = {'xlen': xlen, 'mode': mode, 'source_sha256': sources,
                'images': {path.name: p2.sha(path) for path in directory.glob('*') if path.suffix in ('.elf', '.hex')},
                'symbols': {key: symbols[key] for key in ('tohost', 'sim_console', 'p2_diag_roi')},
                'compiler': subprocess.check_output([str(tools / 'riscv64-unknown-elf-gcc'), '--version'], text=True).splitlines()[0],
                'build_command': shlex.join(command),
                'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()}
    p2.write_json(directory / 'image.json', manifest)
    return directory, manifest


def validate_activity(values, mode, hardware, clock, metrics):
    if (mode not in ('irq_only', 'dma_only') or values.get('errors') != 0 or values.get('core_cycles', 0) <= 0 or
            values.get('irq') != (16 if mode == 'irq_only' else 0) or
            values.get('dma_completed') != (8 if mode == 'dma_only' else 0) or
            values.get('dma_bytes') != (131072 if mode == 'dma_only' else 0)):
        raise ValueError('diagnostic activity or byte comparison failed')
    if (hardware is None or hardware['clock_profile'] != clock or
            values.get('core_hz') != hardware['core_hz'] or values.get('timer_hz') != hardware['timer_hz'] or
            values.get('interval_ticks') != (hardware['timer_hz'] + 9999) // 10000):
        raise ValueError('diagnostic clock contract mismatch')
    dma = metrics['axi']['sys.master2']
    if mode == 'irq_only' and (dma['roi_rbeats'] or dma['roi_wbeats']):
        raise ValueError('IRQ-only diagnostic unexpectedly issued DMA')
    if mode == 'dma_only' and (dma['roi_rbeats'] != 4096 or dma['roi_wbeats'] != 4096):
        raise ValueError('DMA-only diagnostic did not transfer its complete payload in ROI')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', type=Path, required=True)
    parser.add_argument('--sim-receipt', type=Path, help='P2 build receipt or run_soc_system per-profile manifest')
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--clock', type=int, choices=p2.CLOCKS, default=1)
    parser.add_argument('--modes', nargs='+', choices=('irq_only', 'dma_only'), default=['irq_only', 'dma_only'])
    parser.add_argument('--image-root', type=Path, default=Path('build/frozen/p2-load-diagnostic-20261023'))
    parser.add_argument('--log-root', type=Path, required=True)
    args = parser.parse_args()
    os.chdir(ROOT)
    args.log_root.mkdir(parents=True, exist_ok=True)
    receipt_path = args.sim_receipt or args.sim.parent / 'p2-build.json'
    receipt = json.loads(receipt_path.read_text())
    binary_hash = receipt.get('binary_sha256') or receipt.get('binary', {}).get('sha256')
    if p2.sha(args.sim) != binary_hash:
        raise ValueError('diagnostic simulator differs from its recorded build')
    if 'soc_config' in receipt:
        p2.load_sim(args.sim)
        p2.validate_sim_selection(receipt, [args.clock])
    tool_root = Path(os.environ['RISCV_TOOL_ROOT'])
    for mode in args.modes:
        directory, frozen = images(args.image_root, args.xlen, mode, tool_root)
        name = f'p2-load-{mode}-rv{args.xlen}-c{args.clock}'
        command = [str(args.sim), '+IMEM=' + str(directory / 'imem.hex'), '+DMEM=' + str(directory / 'dmem.hex'),
                   '+TOHOST=' + format(frozen['symbols']['tohost'], 'x'), '+CONSOLE=' + format(frozen['symbols']['sim_console'], 'x'),
                   '+P2_ROI=' + format(frozen['symbols']['p2_diag_roi'], 'x'), '+P2_METRICS',
                   '+TEST=' + name, '+CLOCK_CONFIG=' + str(args.clock), '+MAX_CYCLES=3000000']
        log = args.log_root / (name + '.log')
        p2.run(command, log)
        text = log.read_text()
        if re.search(r'%Fatal|%Error|Assertion failed|TIMEOUT', text) or not re.search(r'^PASS ' + re.escape(name) + r' RV' + str(args.xlen) + r'\b', text, re.M):
            raise ValueError('diagnostic software failed')
        lines = re.findall(r'^P2_LOAD_DIAGNOSTIC mode=(\w+) (.*)$', text, re.M)
        if len(lines) != 1 or lines[0][0] != mode:
            raise ValueError('missing diagnostic workload record')
        values = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', lines[0][1])}
        hardware = p2.parse_soc_config(text, receipt.get('soc_config'))
        metrics = p2.parse_metrics(text, p2.CLOCKS[args.clock], require_w=True)
        validate_activity(values, mode, hardware, args.clock, metrics)
        result = {'classification': 'isolated_load_diagnostic_not_coremark', 'values': values,
                  'soc_config': hardware, 'metrics': metrics, 'image_manifest': frozen,
                  'image_manifest_sha256': p2.sha(directory / 'image.json'), 'binary_sha256': binary_hash,
                  'sim_receipt': str(receipt_path), 'sim_receipt_sha256': p2.sha(receipt_path),
                  'command': shlex.join(command), 'log_sha256': p2.sha(log), 'runner_sha256': p2.sha(Path(__file__))}
        p2.write_json(args.log_root / (name + '.json'), result)
        print('PASS ' + name + ' cycles=' + str(values['core_cycles']), flush=True)


if __name__ == '__main__':
    main()
