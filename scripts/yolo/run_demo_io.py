#!/usr/bin/env python3
"""Build the CPU-free real I/O RTL C API and run bounded UART/DDR/DMA/NPU/video checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO))
from scripts.pango.prepare_project import sources


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--log-root',type=Path,required=True)
    parser.add_argument('--xlen',type=int,choices=(32,64),default=32)
    parser.add_argument('--build-only',action='store_true')
    args=parser.parse_args()
    output,logs=args.output.resolve(),args.log_root.resolve()
    for path in (output,logs):
        if path.exists() and any(path.iterdir()):parser.error('use fresh output/log directories')
        path.mkdir(parents=True,exist_ok=True)
    paths=[path.relative_to(REPO).as_posix() for path in sources(REPO,'scripts/yolo/demo_io_files.f')]
    paths+=['scripts/yolo/demo_io_files.f','scripts/video_files.f','scripts/npu_files.f',
            'tb/yolo/yolo_demo_io.h','tb/yolo/yolo_demo_io.cpp','tb/yolo/yolo_demo_io_smoke.cpp',
            'tb/yolo/ms7210_registers.hex','scripts/yolo/run_demo_io.py']
    paths=list(dict.fromkeys(paths));hashes={p:sha(REPO/p) for p in paths}
    frozen=output/'source'
    for path in paths:
        target=frozen/path;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(REPO/path,target)
    env=os.environ.copy()
    for variable,name in (('CCACHE_DIR','ccache'),('CCACHE_TEMPDIR','ccache-tmp')):
        (output/name).mkdir();env[variable]=str(output/name)
    model=output/'model'
    command=['verilator','--cc','--exe','--build','--timing','--assert','-Wall','-Wno-fatal',
             '-DCORE_XLEN='+str(args.xlen),'-j','1','--threads','1','--output-split','5000',
             '--output-split-cfuncs','100','-CFLAGS','-O2 -g0 -fPIC -I'+str(frozen/'tb/yolo'),
             '--top-module','yolo_demo_io','--Mdir',str(model),'-f','scripts/yolo/demo_io_files.f',
             str(frozen/'tb/yolo/yolo_demo_io.cpp'),str(frozen/'tb/yolo/yolo_demo_io_smoke.cpp')]
    receipt={'status':'prepared','source_sha256':hashes,'build':command,'xlen':args.xlen,
             'branch':subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip(),
             'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),
             'contains_riscv_core':False,'contains_cpu_cache':False,'ddr_bytes':128*1024*1024,
             'clocks_hz':{'sys':100000000,'ddr':125000000,'periph':60000000,'npu':100000000,'pixel':148500000},
             'core_clock_metadata_hz':90000000,'i2c_sim_reset_settle_cycles':600,
             'not_run':['PDS','FPGA board','complete RV32 YOLO firmware']}
    def run(stage,argv,cwd):
        log=logs/(stage+'.log')
        with log.open('w') as stream:result=subprocess.run(argv,cwd=cwd,env=env,stdout=stream,stderr=subprocess.STDOUT)
        receipt[stage+'_exit']=result.returncode;receipt[stage+'_log_sha256']=sha(log)
        (logs/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        if result.returncode:raise SystemExit(stage+' failed; '+str(log))
        return log.read_text()
    run('build',command,frozen)
    library=model/'libyolo_demo_io.so'
    link=['g++','-shared','-o',str(library),str(model/'yolo_demo_io.o')]
    link += [str(p) for p in sorted(model.glob('verilated*.o'))]
    link += [str(model/'Vyolo_demo_io__ALL.a'),'-pthread','-latomic']
    receipt['library_link']=link;run('library',link,frozen)
    receipt['library_sha256']=sha(library);receipt['library']=str(library)
    if not args.build_only:
        binary=model/'Vyolo_demo_io';receipt['run']=[str(binary)]
        text=run('smoke',[str(binary)],frozen)
        if not re.search(r'^PASS yolo_demo_io ',text,re.M):raise SystemExit('missing full I/O smoke PASS')
        receipt['pass_lines']=[line for line in text.splitlines() if line.startswith('PASS')]
        receipt['binary_sha256']=sha(binary)
    receipt['status']='BUILT' if args.build_only else 'PASS'
    (logs/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(receipt['status'],'I/O RTL C API:',logs/'receipt.json',flush=True)


if __name__=='__main__':main()
