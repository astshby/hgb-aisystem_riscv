#!/usr/bin/env python3
"""Compare the AW-captured WSTRB mask with the preserved AXI-to-AXI-Lite bridge."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
TOP = 'tb_axi_to_axil_mask_miter'
SOURCES = ['vsrc/pkg/core_config_pkg.sv', 'vsrc/pkg/axi_types_pkg.sv',
           'vsrc/soc/common/rv_fifo.sv', 'vsrc/soc/bus/axi_register_slice.sv',
           'vsrc/soc/bus/axi_to_axil.sv']


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=Path('build/closing-c6-20261030/reference/axi_to_axil.sv'))
    parser.add_argument('--output', type=Path, default=Path('build/closing-c6-20261030/axil-mask'))
    parser.add_argument('--logs', type=Path, default=Path('logs/closing-c6-20261030/axil-mask'))
    args = parser.parse_args()
    os.chdir(ROOT)
    reference = args.reference.resolve()
    original = json.loads((reference.parent/'soc-original-source.json').read_text())
    if sha(reference) != original['vsrc/soc/bus/axi_to_axil.sv']:
        raise ValueError('preserved control bridge SHA mismatch')
    output, logs = args.output.resolve(), args.logs.resolve()
    output.mkdir(parents=True, exist_ok=False);logs.mkdir(parents=True, exist_ok=False)
    renamed = output/'axi_to_axil_reference.sv'
    text, count = re.subn(r'\bmodule axi_to_axil\b', 'module axi_to_axil_reference', reference.read_text())
    if count != 1:
        raise ValueError('expected exactly one reference module')
    renamed.write_text(text)
    env = dict(os.environ, CCACHE_DIR=str(ROOT/'build/ccache'), CCACHE_TEMPDIR=str(ROOT/'build/ccache-tmp'))
    for key in ('CCACHE_DIR', 'CCACHE_TEMPDIR'):
        Path(env[key]).mkdir(exist_ok=True)
    receipt = dict(status='RUNNING', branch=subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
        commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        reference_sha256=sha(reference), source_sha256={name:sha(ROOT/name) for name in SOURCES+[
            'tb/soc/'+TOP+'.sv', 'scripts/verilator/run_axil_mask_miter.py']}, results=[])
    try:
        for width in (32, 64):
            build = output/f'rv{width}'
            command = [os.environ.get('VERILATOR', 'verilator'), '--binary', '--timing', '--assert',
                '-Wall', '-Wno-fatal', '-j', '1', '-CFLAGS', '-O1', f'-DCORE_XLEN={width}',
                '--Mdir', str(build), '--top-module', TOP, *SOURCES, str(renamed), 'tb/soc/'+TOP+'.sv']
            build_log, run_log = logs/f'rv{width}.build.log', logs/f'rv{width}.run.log'
            begin = time.monotonic()
            with build_log.open('w') as stream:
                subprocess.run(command, check=True, env=env, stdout=stream, stderr=subprocess.STDOUT)
            if re.search(r'%Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER)', build_log.read_text()):
                raise RuntimeError('structural Verilator warning in ' + str(build_log))
            run = [str(build/('V'+TOP))]
            with run_log.open('w') as stream:
                subprocess.run(run, check=True, stdout=stream, stderr=subprocess.STDOUT)
            lines = [line for line in run_log.read_text().splitlines() if line.startswith('PASS '+TOP+' ')]
            if len(lines) != 1:
                raise RuntimeError('missing unique PASS in '+str(run_log))
            receipt['results'].append(dict(xlen=width, build_command=command, run_command=run,
                pass_line=lines[0], elapsed_seconds=time.monotonic()-begin,
                binary_sha256=sha(build/('V'+TOP)), build_log_sha256=sha(build_log), run_log_sha256=sha(run_log)))
            print(lines[0], flush=True)
        receipt['status'] = 'PASS'
    except Exception as error:
        receipt.update(status='FAIL', error=repr(error));raise
    finally:
        (logs/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')


if __name__ == '__main__':
    main()
