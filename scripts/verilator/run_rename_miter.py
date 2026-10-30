#!/usr/bin/env python3
"""Compare a preserved RAT against the selected-entry query and run its existing directed test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = [
    'vsrc/pkg/core_config_pkg.sv', 'vsrc/pkg/riscv_unpriv_pkg.sv',
    'vsrc/pkg/riscv_priv_pkg.sv', 'vsrc/pkg/core_types_pkg.sv',
    'vsrc/pkg/predictor_types_pkg.sv', 'vsrc/pkg/pipeline_pkg.sv',
    'vsrc/pkg/soc_config_pkg.sv', 'vsrc/pkg/soc_addr_pkg.sv', 'vsrc/pkg/scoreboard_pkg.sv',
]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=Path('build/closing-c6-20261030/reference/rename_table.sv'))
    parser.add_argument('--output', type=Path, default=Path('build/closing-c6-20261030/rename'))
    parser.add_argument('--logs', type=Path, default=Path('logs/closing-c6-20261030/rename'))
    parser.add_argument('--xlens', nargs='+', type=int, choices=(32, 64), default=[32, 64])
    parser.add_argument('--retire-entries', type=int, choices=(16, 32), default=16)
    parser.add_argument('--cycles', type=int, default=25000)
    args = parser.parse_args()
    os.chdir(ROOT)
    reference = args.reference.resolve()
    recorded = json.loads(reference.with_suffix('.json').read_text())
    if sha(reference) != recorded['sha256']:
        raise ValueError('preserved reference SHA mismatch')
    output, logs = args.output.resolve(), args.logs.resolve()
    output.mkdir(parents=True, exist_ok=False)
    logs.mkdir(parents=True, exist_ok=False)
    renamed = output / 'rename_table_reference.sv'
    text = reference.read_text()
    text, count = re.subn(r'\bmodule rename_table\b', 'module rename_table_reference', text)
    if count != 1:
        raise ValueError('expected exactly one module declaration')
    renamed.write_text(text)
    environment = dict(os.environ, CCACHE_DIR=str(ROOT / 'build/ccache'),
                       CCACHE_TEMPDIR=str(ROOT / 'build/ccache-tmp'))
    Path(environment['CCACHE_DIR']).mkdir(exist_ok=True)
    Path(environment['CCACHE_TEMPDIR']).mkdir(exist_ok=True)
    receipt = dict(status='RUNNING', branch=subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
        commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        reference=recorded, parameters=dict(xlens=args.xlens, retire_entries=args.retire_entries,
                                           issue_width=2, branch_checkpoints=4, random_cycles=args.cycles),
        source_sha256={name:sha(ROOT/name) for name in PACKAGES + [
            'vsrc/core/control/rename_table.sv', 'tb/unit/scoreboard/tb_rename_query_miter.sv',
            'tb/unit/scoreboard/tb_scoreboard_rename.sv', 'scripts/verilator/run_rename_miter.py']},
        results=[])
    try:
        for width in args.xlens:
            for top in ('tb_rename_query_miter', 'tb_scoreboard_rename'):
                build = output / f'{top}-rv{width}'
                sources = PACKAGES + ['vsrc/core/control/rename_table.sv']
                if top == 'tb_rename_query_miter':
                    sources += [str(renamed)]
                sources += [f'tb/unit/scoreboard/{top}.sv']
                command = [os.environ.get('VERILATOR', 'verilator'), '--binary', '--timing', '--assert',
                    '-Wall', '-Wno-fatal', '-j', '1', '-CFLAGS', '-O1',
                    f'-DCORE_XLEN={width}', f'-DCORE_RETIRE_ENTRIES={args.retire_entries}',
                    '-DCORE_ISSUE_WIDTH=2', '-DCORE_BRANCH_CHECKPOINTS=4',
                    '--top-module', top, '--Mdir', str(build), *sources]
                start = time.monotonic()
                build_log = logs / f'{top}-rv{width}.build.log'
                with build_log.open('w') as stream:
                    subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT, env=environment)
                if re.search(r'%Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER)', build_log.read_text()):
                    raise RuntimeError('structural Verilator warning in ' + str(build_log))
                run_command = [str(build/f'V{top}')]
                if top == 'tb_rename_query_miter':
                    run_command += [f'+cycles={args.cycles}']
                run_log = logs / f'{top}-rv{width}.run.log'
                with run_log.open('w') as stream:
                    subprocess.run(run_command, check=True, stdout=stream, stderr=subprocess.STDOUT)
                passed = [line for line in run_log.read_text().splitlines() if line.startswith('PASS ' + top + ' ')]
                if len(passed) != 1:
                    raise RuntimeError('missing unique PASS in ' + str(run_log))
                receipt['results'].append(dict(xlen=width, top=top, build_command=command, run_command=run_command,
                    pass_line=passed[0], elapsed_seconds=time.monotonic()-start,
                    binary_sha256=sha(build/f'V{top}'), build_log_sha256=sha(build_log), run_log_sha256=sha(run_log)))
                print(passed[0], flush=True)
        receipt['status'] = 'PASS'
    except Exception as error:
        receipt.update(status='FAIL', error=repr(error))
        raise
    finally:
        (logs/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')


if __name__ == '__main__':
    main()
