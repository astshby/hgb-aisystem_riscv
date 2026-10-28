#!/usr/bin/env python3
"""Run the pinned NPU through the production AXI/CDC adapter; preserve each run's evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    args = parser.parse_args()
    os.chdir(ROOT)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    pinned = ROOT/'third_party/yolo_npu128'
    manifest = json.loads((pinned/'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        if digest(pinned/name) != expected:
            raise ValueError('pinned NPU changed: '+name)
    sources = {str(p): digest(p) for glob in ('vsrc/**/*.sv', 'third_party/yolo_npu128/**/*.sv',
        'scripts/*.f', 'tb/soc/tb_npu_axi.sv', 'scripts/verilator/run_npu_tests.py') for p in Path('.').glob(glob)}
    records = []
    env = dict(os.environ, CCACHE_TEMPDIR=str(ROOT/'build/ccache-tmp'), CCACHE_DIR=str(ROOT/'build/ccache'))
    for half in (5000, 6250, 4000, 5556):
        build = output/f'npu-{half}'
        build.mkdir()
        command = ['verilator', '--binary', '--assert', '--timing', '-Wall', '-Wno-fatal', '-j', '2',
            '-CFLAGS', '-O1', f'-DCORE_XLEN={args.xlen}', '-f', 'scripts/system_files.f',
            'tb/soc/tb_npu_axi.sv', '--top-module', 'tb_npu_axi', f'-GNPU_HALF_PS={half}', '-Mdir', str(build)]
        for label, cmd in [('build',command), ('run',[str(build/'Vtb_npu_axi')])]:
            with (build/(label+'.log')).open('w') as log:
                log.write(shlex.join(cmd)+'\n'); log.flush()
                subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, check=True)
        build_log=(build/'build.log').read_text()
        if re.search(r'%(?:Error|Warning-(?:LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))',build_log):
            raise ValueError('critical RTL diagnostic: '+str(build))
        result = re.search(r'^PASS npu-axi.*$',(build/'run.log').read_text(), re.M)
        if not result: raise ValueError('missing PASS')
        print(result[0],flush=True)
        records.append(dict(command=shlex.join(command), result=result[0],
            binary_sha256=digest(build/'Vtb_npu_axi'),log_sha256=digest(build/'run.log')))
    for name, expected in sources.items():
        if digest(ROOT/name)!=expected: raise ValueError('source changed during run: '+name)
    (output/'result.json').write_text(json.dumps(dict(status='PASS',passed=len(records),skipped=0,
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        source_branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),
        source_sha256=sources,upstream=manifest,records=records),indent=2)+'\n')


if __name__=='__main__':
    main()
