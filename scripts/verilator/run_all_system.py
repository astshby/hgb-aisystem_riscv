#!/usr/bin/env python3
"""Run bounded simultaneous-accelerator checks without PDS or a full model export."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    tracked = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
    generated_sources = ['vsrc/soc/soc_all_system.sv', 'vsrc/soc/bus/axi_external_arbiter.sv',
                         'tb/soc/all_accelerators.S', 'tb/soc/tb_all_system.sv',
                         'tb/soc/tb_axi_external_arbiter.sv', 'scripts/verilator/run_all_system.py']
    inputs = sorted(set(p for p in tracked+generated_sources
                        if p.startswith(('vsrc/', 'tb/', 'scripts/', 'third_party/')) and Path(p).is_file()))
    initial_hashes = {p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in inputs}
    out = (root / 'build' / f'all-system-rv{args.xlen}').resolve()
    logs = (root / 'logs' / f'all-system-rv{args.xlen}' / f'attempt-{time.time_ns()}').resolve()
    out.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(command, name):
        commands.append(shlex.join(map(str, command)))
        with (logs / (name+'.log')).open('w') as stream:
            subprocess.run(list(map(str, command)), stdout=stream, stderr=subprocess.STDOUT, check=True)

    start = time.time()
    if not os.environ.get('RISCV_TOOL_ROOT'):
        raise RuntimeError('RISCV_TOOL_ROOT must name the RISC-V toolchain bin directory')
    prefix = Path(os.environ['RISCV_TOOL_ROOT']) / 'riscv64-unknown-elf-'
    os.environ['CCACHE_TEMPDIR'] = str(root/'build'/'ccache-tmp')
    os.environ['CCACHE_DIR'] = str(root/'build'/'ccache')
    Path(os.environ['CCACHE_TEMPDIR']).mkdir(parents=True, exist_ok=True)
    Path(os.environ['CCACHE_DIR']).mkdir(parents=True, exist_ok=True)
    run([str(prefix)+'gcc', f'-march=rv{args.xlen}im', '-mabi=ilp32' if args.xlen == 32 else '-mabi=lp64',
         '-nostdlib', '-nostartfiles', '-Wl,-Ttext=0x01000000', '-Wl,--no-relax',
         'tb/soc/all_accelerators.S', '-o', out/'program.elf'], 'firmware')
    run([str(prefix)+'objcopy', '-O', 'binary', '--only-section=.text', out/'program.elf', out/'program.bin'], 'objcopy')
    memory = (out/'program.bin').read_bytes().ljust(65536, b'\x00')
    word = args.xlen//8
    words = [memory[i:i+word][::-1].hex() for i in range(0, len(memory), word)]
    image = out/'imem.hex'
    image.write_text('\n'.join(words)+'\n')
    for bank in (0, 1):
        Path(str(image)+f'.bank{bank}').write_text('\n'.join(words[bank::2])+'\n')
    flags = ['verilator', '-Wall', '-Wno-fatal', '--assert', '--timing', '--binary', '-j', '1',
             f'-DCORE_XLEN={args.xlen}', '-DCORE_SCOREBOARD', '-DCORE_DIV_IMPL=1',
             '-DCORE_ISSUE_WIDTH=2', '-DCORE_RETIRE_ENTRIES=16', '-DCORE_SPLIT_ISSUE_QUEUE=1',
             '-DCORE_ISSUE_QUEUE_ENTRIES=8', '-DCORE_MEMORY_QUEUE_ENTRIES=4',
             '-DCORE_SCHEDULER_FORWARD_MODE=3', '-DCORE_PREDICTOR_MODE=1', '-DCORE_RAS_ENABLE=0',
             '-f', 'scripts/soc_files.f']
    for top, sources, parameters in [
        ('tb_all_system', ['tb/soc/axi_system_memory_model.sv', 'tb/soc/tb_all_system.sv'],
         ['-GITCM_INIT_FILE='+json.dumps(str(image))]),
        ('tb_axi_external_arbiter', ['tb/soc/axi_system_memory_model.sv', 'tb/soc/tb_axi_external_arbiter.sv'], []),
    ]:
        model = out/top
        run(flags+sources+parameters+['--top-module', top, '-Mdir', model], top+'-build')
        run([model/('V'+top)], top+'-run')
        if f'PASS {top}' not in (logs/(top+'-run.log')).read_text():
            raise RuntimeError('missing PASS: '+top)
    hashes = {p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in inputs}
    if hashes != initial_hashes:
        raise RuntimeError('source files changed during this run')
    receipt = dict(status='PASS', xlen=args.xlen, passed=2, skipped=0,
                   elapsed_seconds=time.time()-start, commands=commands, sources=hashes,
                   firmware_sha256=hashlib.sha256((out/'program.elf').read_bytes()).hexdigest(),
                   scope='real RV32/RV64 Core with two original accelerators; bounded mapping/IRQ/GEMV and independent-owner tests; no full model or PDS')
    (logs/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    (logs.parent/'receipt.json').write_text(json.dumps(dict(receipt, attempt_directory=str(logs)), indent=2)+'\n')
    print(f'PASS all-system RV{args.xlen} 2 PASS / 0 SKIP')


if __name__ == '__main__':
    main()
