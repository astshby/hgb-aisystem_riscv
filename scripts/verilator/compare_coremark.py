#!/usr/bin/env python3
"""Compare current RTL with validated baseline CoreMark images without rebuilding software."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

import coremark_snapshot as snapshot


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--expect-equal', action='store_true')
    args = parser.parse_args()
    cfg = snapshot.configuration(args.xlen)
    runtime, rtl_parameters = snapshot.runtime_configuration(cfg)
    baseline = args.baseline_root.resolve()
    out = args.output.resolve()
    snapshot.require(not out.exists(), 'preserve comparison output; use a new directory')
    image_root = baseline / f'build/benchmark/coremark-rv{args.xlen}-{runtime}'
    tool_root = os.environ.get('RISCV_TOOL_ROOT')
    snapshot.require(tool_root, 'set RISCV_TOOL_ROOT')
    tools = str(Path(tool_root) / 'riscv64-unknown-elf-')
    records = {}
    # 保留基线实际 ISA 属性，不修改 ELF，也不将此证据目录冒充 snapshot.py 的格式。
    for mode in snapshot.MODES:
        log = baseline / f'logs/coremark-{mode}-rv{args.xlen}-{runtime}.log'
        record = snapshot.result_fields(log, mode, args.xlen)
        elf = image_root / mode / 'program.elf'
        data = elf.read_bytes()
        snapshot.require(data[:4] == b'\x7fELF' and data[4] == (1 if args.xlen == 32 else 2) and
                         data[5] == 1 and struct.unpack_from('<H', data, 18)[0] == 243,
                         'baseline ELF width, endianness or machine mismatch')
        snapshot.require(struct.unpack_from('<I', data, 36 if args.xlen == 32 else 48)[0] & 15 == 0,
                         'baseline ELF requires unsupported ABI/extensions')
        nm = subprocess.check_output([tools + 'nm', '-n', str(elf)], text=True)
        symbols = {name: int(value, 16) for value, name in re.findall(
            r'^([0-9a-fA-F]+)\s+\S\s+(tohost|sim_console)$', nm, re.M)}
        snapshot.require(set(symbols) == {'tohost', 'sim_console'}, 'missing baseline host symbols')
        record.update(symbols=symbols, elf_attributes=subprocess.check_output(
            [tools + 'readelf', '-A', str(elf)], text=True))
        records[mode] = record
    out.mkdir(parents=True)
    report = {'kind': 'same-image comparison', 'config': cfg, 'rtl_parameters': rtl_parameters,
              'baseline_revision': subprocess.check_output(['git', '-C', str(baseline), 'rev-parse', 'HEAD'], text=True).strip(),
              'rtl_checkout': snapshot.checkout_info(), 'expect_equal': args.expect_equal,
              'modes': {}, 'status': 'running'}
    result_file = out / 'result.json'

    def save():
        result_file.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    for mode in snapshot.MODES:
        target = out / 'images' / mode
        target.mkdir(parents=True)
        for name in snapshot.IMAGE_FILES:
            shutil.copyfile(image_root / mode / name, target / name)
        shutil.copyfile(baseline / f'logs/coremark-{mode}-rv{args.xlen}-{runtime}.log', out / f'baseline-{mode}.log')
        report['modes'][mode] = {'baseline': records[mode], 'images_sha256': {
            name: sha(target / name) for name in snapshot.IMAGE_FILES}}
    save()
    try:
        subprocess.run(['bash', 'scripts/verilator/build_benchmark_sim.sh', str(args.xlen)], check=True)
        top = 'tb_soc_benchmark' if cfg['soc'] else 'tb_benchmark'
        simulator = Path(f'build/verilator/benchmark-rv{args.xlen}-{runtime}/V{top}').resolve()
        report['simulator_sha256'] = sha(simulator)
        for mode in snapshot.MODES:
            symbols = records[mode]['symbols']
            target = out / 'images' / mode
            command = [str(simulator), f'+IMEM={target / "imem.hex"}', f'+DMEM={target / "dmem.hex"}',
                       f'+TOHOST={symbols["tohost"]:x}', f'+CONSOLE={symbols["sim_console"]:x}',
                       f'+TEST=coremark-{mode}', '+MAX_CYCLES=100000000']
            report['modes'][mode]['command'] = command
            save()
            log = out / f'{mode}.log'
            with log.open('x') as stream:
                subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
            observed = snapshot.result_fields(log, mode, args.xlen)
            for field in ('iterations', 'crc', 'compiler_version', 'compiler_flags'):
                snapshot.require(observed[field] == records[mode][field], f'{mode} {field} mismatch')
            report['modes'][mode]['observed'] = observed
            report['modes'][mode]['coremark_per_mhz'] = observed['iterations'] * 1e6 / observed['ticks']
            equal = all(observed.get(key) == records[mode].get(key)
                        for key in ('ticks', 'harness_cycles', 'scoreboard_metrics'))
            report['modes'][mode]['cycle_and_metrics_equal'] = equal
            save()
            snapshot.require(not args.expect_equal or equal, f'{mode} cycle/metrics mismatch')
            print(f'PASS CoreMark comparison {mode} RV{args.xlen} ticks={observed["ticks"]} equal={equal}', flush=True)
        for mode in snapshot.MODES:
            target = out / 'images' / mode
            snapshot.require(all(sha(target / name) == expected for name, expected in
                                 report['modes'][mode]['images_sha256'].items()), 'comparison images changed')
        snapshot.require(sha(simulator) == report['simulator_sha256'], 'comparison simulator changed')
        snapshot.require(snapshot.checkout_info()['source_files_sha256'] ==
                         report['rtl_checkout']['source_files_sha256'], 'source files changed during comparison')
        report['status'] = 'PASS'
    except Exception as error:
        report['status'] = 'FAIL'
        report['error'] = str(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
