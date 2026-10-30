#!/usr/bin/env python3
"""Run the software-math firmware on a preserved real-core RTL model with matching Core/pkg sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT=Path(__file__).resolve().parents[2]
def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen',type=int,choices=(32,64),required=True)
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--softmath',type=Path,help='required for pure RV64IM; never select the default FD library')
    parser.add_argument('--check-set',choices=('math','operators'),default='math',
                        help='operators runs the same graph/BN/quantization/NMS checks used by the native tests')
    args=parser.parse_args();os.chdir(ROOT)
    model=args.model.resolve();output=args.output.resolve();output.mkdir(parents=True)
    receipt=json.loads((model.parent/'build.json').read_text())
    if receipt['config']['xlen']!=args.xlen: raise ValueError('model XLEN differs')
    checked={name:expected for name,expected in receipt['source_sha256'].items()
             if name.startswith(('vsrc/core/','vsrc/pkg/'))}
    if not checked or any(sha(ROOT/name)!=expected for name,expected in checked.items()):
        raise ValueError('preserved model Core/pkg differs from current sources')
    libraries=['-lm','-lgcc']
    if args.xlen==64:
        if args.softmath is None: parser.error('--softmath is required for RV64IM')
        libraries=[str(args.softmath.resolve())]
    checks=['tb/yolo/softmath_check.c']
    marker='PASS yolo softmath checks=17 integer-only core'
    if args.check_set=='operators':
        checks=['software/yolo/network.c','software/yolo/network_pool.c',
                'tb/yolo/network_ops.c','tb/yolo/network_core_adapter.c']
        marker='PASS YOLO network C operators groups=5'
    command=['bash','scripts/verilator/build_baremetal_image.sh',str(args.xlen),str(output),
        '-fno-fast-math','-ffp-contract=off','-ffunction-sections','-fdata-sections','-Wl,--gc-sections',
        '-fstack-usage','-Isoftware/yolo',
        'software/common/baremetal/crt0.S','software/common/baremetal/runtime.c',
        'software/common/baremetal/softarith.c','software/yolo/demo_libc.c',*checks,*libraries]
    def run(command,path,env=None):
        with path.open('w') as stream:
            stream.write(shlex.join(command)+'\n');stream.flush()
            subprocess.run(command,cwd=ROOT,env=env,stdout=stream,stderr=subprocess.STDOUT,check=True)
    run(command,output/'build.log',dict(os.environ,SOC='1',SOC_DDR='0'))
    prefix=Path(os.environ['RISCV_TOOL_ROOT'])/'riscv64-unknown-elf-nm'
    lines=subprocess.check_output([str(prefix),'-n',str(output/'program.elf')],text=True)
    symbols={p[2]:int(p[0],16) for line in lines.splitlines() if len(p:=line.split())==3}
    simulation=[str(model),f'+IMEM={output}/imem.hex',f'+DMEM={output}/dmem.hex',
        f'+TOHOST={symbols["tohost"]:x}',f'+CONSOLE={symbols["sim_console"]:x}',
        '+TEST=yolo-'+args.check_set,'+MAX_CYCLES=2000000']
    run(simulation,output/'simulation.log')
    text=(output/'simulation.log').read_text()
    if marker not in text or '%Error' in text:
        raise ValueError('math firmware did not complete')
    report=dict(status='PASS',xlen=args.xlen,check_set=args.check_set,
        checks=17 if args.check_set=='math' else 5,compile_command=command,simulation_command=simulation,
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        source_sha256={name:sha(ROOT/name) for name in command if (ROOT/name).is_file()},
        verified_core_pkg_source_sha256=checked,model_sha256=sha(model),model_receipt_sha256=sha(model.parent/'build.json'),
        softmath_sha256=sha(args.softmath) if args.softmath else None,
        image_sha256={name:sha(output/name) for name in ('program.elf','imem.hex','dmem.hex')},
        simulation_log_sha256=sha(output/'simulation.log'),scope='actual integer core arithmetic; preserved SoC clock/memory configuration, not full YOLO inference')
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'PASS yolo {args.check_set} RV{args.xlen}; Core/pkg match preserved RTL model')

if __name__=='__main__': main()
