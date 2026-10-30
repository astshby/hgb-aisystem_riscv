#!/usr/bin/env python3
"""Run two short UART requests on the complete no-NPU SoC; this is not a formal score."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from hardware_config import hardware_configuration
import sim_support as support


def run(command, log, cwd=ROOT, env=None):
    with log.open('w') as stream:
        stream.write(shlex.join(map(str, command)) + '\n')
        stream.flush()
        subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--prepare-only', action='store_true',
                        help='only compile firmware and record the intended hardware; no Verilator build/run')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    os.chdir(ROOT)
    output = args.output.resolve() if args.output else ROOT / f'build/coremark-board/uart-rv{args.xlen}'
    output.mkdir(parents=True, exist_ok=args.output is None)
    image = output / 'firmware'
    env = dict(os.environ, COREMARK_BOARD_OUT=str(image),
               COREMARK_BOARD_TEST_ITERATIONS='2', COREMARK_BOARD_BAUD='500000')
    run(['bash', 'scripts/coremark/build_board.sh', str(args.xlen)], output / 'software-build.log', env=env)
    config = hardware_configuration('none', args.xlen, 16384, 8192, 2)
    if config['board_clock_profile'] is None:
        raise ValueError('UART TB requires an existing numbered board clock profile')
    (output / 'hardware.json').write_text(json.dumps(config, indent=2) + '\n')
    if args.prepare_only:
        print(f'PASS prepared short UART firmware RV{args.xlen}; RTL simulation not run: {output}')
        return

    sources = support.rtl_sources()
    for name in ('tb/benchmark/tb_coremark_uart.sv', 'scripts/coremark/run_uart.py',
                 'scripts/hardware_config.py', 'scripts/hardware_profile.json'):
        sources[name] = support.sha(name)
    digest = hashlib.sha256(json.dumps([config, sources], sort_keys=True).encode()).hexdigest()[:16]
    model = ROOT / f'build/coremark-board/models/rv{args.xlen}-{digest}'
    binary = model / 'Vtb_coremark_uart'
    if not binary.exists():
        model.mkdir(parents=True, exist_ok=True)
        snapshot = model / 'source'
        for name, expected in sources.items():
            path = snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists():
                if support.sha(path) != expected:
                    raise ValueError('model source snapshot differs: ' + name)
            else:
                path.write_bytes((ROOT / name).read_bytes())
        command = ['verilator', '--binary', '--timing', '--assert', '-Wall', '-Wno-fatal',
                   '-j', str(args.jobs), '-CFLAGS', '-O1',
                   *[f'-D{k}={v}' for k, v in config['macros'].items()],
                   '-f', 'scripts/system_files.f', 'tb/common/store_result_monitor.sv',
                   'tb/soc/axi_system_memory_model.sv', 'tb/soc/spi_flash_model.sv',
                   'tb/soc/tb_soc_system.sv', 'tb/benchmark/tb_coremark_uart.sv',
                   f'-GCLOCK_PROFILE={config["board_clock_profile"]}',
                   f'-GPERIPH_HZ={config["frequencies_hz"]["periph"]}',
                   '-GBAUD=500000', '-GICACHE_BYTES=16384', '-GDCACHE_BYTES=8192',
                   '--top-module', 'tb_coremark_uart', '-Mdir', str(model)]
        compile_env = dict(os.environ, CCACHE_DIR=str(ROOT / 'build/ccache'),
                           CCACHE_TEMPDIR=str(ROOT / 'build/ccache-tmp'))
        Path(compile_env['CCACHE_DIR']).mkdir(parents=True, exist_ok=True)
        Path(compile_env['CCACHE_TEMPDIR']).mkdir(parents=True, exist_ok=True)
        run(command, model / 'build.log', snapshot, compile_env)
        (model / 'build.json').write_text(json.dumps(dict(config=config, command=command,
            source_sha256=sources, binary_sha256=support.sha(binary)), indent=2) + '\n')
    symbols = support.symbols_from_nm((image / 'program.nm').read_text())
    command = [str(binary), f'+IMEM={image}/imem.hex', f'+DMEM={image}/dmem.hex',
               f'+TOHOST={symbols["tohost"]:x}', '+TEST=coremark-uart', '+MAX_CYCLES=30000000']
    run(command, output / 'simulation.log')
    text = (output / 'simulation.log').read_text()
    marker = f'PASS board CoreMark UART RV{args.xlen} requests=2 ready=3 real_uart=1 formal=0'
    if marker not in text or '%Error' in text or '%Fatal' in text:
        raise ValueError('UART simulation did not complete the two-request check')
    receipt = dict(status='PASS', formal=False, xlen=args.xlen, config=config,
                   command=command, firmware_manifest=json.loads((image / 'manifest.json').read_text()),
                   model_receipt=str(model / 'build.json'), log_sha256=support.sha(output / 'simulation.log'))
    (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(marker)
    print('Evidence: ' + str(output / 'result.json'))


if __name__ == '__main__':
    main()
