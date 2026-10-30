#!/usr/bin/env python3
"""Build the real NPU AXI/CDC shared library without a CPU model or place-and-route."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def file_list(path):
    result=[path]
    for line in (ROOT/path).read_text().splitlines():
        fields=shlex.split(line,comments=True)
        if not fields:continue
        if fields[0]=='-f':result.extend(file_list(fields[1]))
        else:result.extend(fields)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen',type=int,choices=(32,64),default=32)
    parser.add_argument('--output',type=Path,default=os.environ.get('YOLO_NETWORK_OUT'))
    parser.add_argument('--log-dir',type=Path)
    args=parser.parse_args()
    if args.output is None:parser.error('set YOLO_NETWORK_OUT or --output')
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    sources=file_list('scripts/demo/npu_csr_cosim.f')+[
        'tb/yolo/npu_rtl_cosim.cpp','tb/yolo/npu_rtl_cosim.h',
        'software/yolo/conv_schedule.c','software/yolo/conv_schedule.h','scripts/demo/build_npu_rtl.py']
    hashes={name:sha(ROOT/name) for name in sorted(set(sources))}
    identity=hashlib.sha256(json.dumps(dict(xlen=args.xlen,sources=hashes),sort_keys=True).encode()).hexdigest()[:16]
    folder=output/f'npu-rtl-rv{args.xlen}-{identity}';folder.mkdir(exist_ok=True)
    snapshot=folder/'source'
    for name,expected in hashes.items():
        path=snapshot/name;path.parent.mkdir(parents=True,exist_ok=True)
        if path.exists():
            if sha(path)!=expected:raise ValueError('source snapshot changed: '+name)
        else:path.write_bytes((ROOT/name).read_bytes())
    library=folder/'libyolo_npu_rtl.so';model=folder/'model';model.mkdir(exist_ok=True)
    logs=args.log_dir.resolve() if args.log_dir else folder;logs.mkdir(parents=True,exist_ok=True)
    logfile=logs/f'npu-rtl-rv{args.xlen}-{identity}-build.log'
    environment=dict(os.environ,CCACHE_DIR=os.environ.get('CCACHE_DIR',str(output/'ccache')),
                     CCACHE_TEMPDIR=os.environ.get('CCACHE_TEMPDIR',str(output/'ccache-tmp')))
    for name in ('CCACHE_DIR','CCACHE_TEMPDIR'):Path(environment[name]).mkdir(parents=True,exist_ok=True)
    object_file=folder/'conv_schedule.o'
    cc=[os.environ.get('CC','cc'),'-std=c11','-O3','-fPIC','-Wall','-Wextra','-Werror','-Isoftware/yolo',
        '-c','software/yolo/conv_schedule.c','-o',str(object_file)]
    command=[os.environ.get('VERILATOR','verilator'),'--cc','--exe','--build','--assert','-Wall','-Wno-fatal',
        '-j','1','--output-split','20000','--output-split-cfuncs','1000',f'-DCORE_XLEN={args.xlen}',
        '-f','scripts/demo/npu_csr_cosim.f','tb/yolo/npu_rtl_cosim.cpp',str(object_file),
        '--top-module','npu_csr_cosim','-Mdir',str(model),
        '-CFLAGS',shlex.join(['-fPIC','-O2','-I'+str(snapshot/'software/yolo'),'-I'+str(snapshot/'tb/yolo')]),
        '-LDFLAGS','-shared','-o',str(library)]
    start=time.monotonic()
    with logfile.open('w') as log:
        for call in (cc,command):
            log.write(shlex.join(call)+'\n');log.flush()
            subprocess.run(call,cwd=snapshot,env=environment,stdout=log,stderr=subprocess.STDOUT,check=True)
    receipt=dict(xlen=args.xlen,scope='Scalar master + real AXI/register-slice/CDC/NPU RTL; no RISC-V CPU',
        source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),source_sha256=hashes,
        commands=[cc,command],elapsed_seconds=time.monotonic()-start,library_sha256=sha(library),library=str(library),
        log=str(logfile),log_sha256=sha(logfile),jobs=1)
    (folder/'build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    (output/f'npu-rtl-rv{args.xlen}-latest.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS NPU AXI/CDC RTL shared library build: '+str(library))


if __name__=='__main__':main()
