#!/usr/bin/env python3
"""Run standalone YOLO software with real DMA/MAC overlap on the five-domain SoC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from hardware_config import hardware_configuration
from sim_support import optimization,rtl_sources,copy_sources,symbols_from_nm,sha


def run(command,log,cwd=ROOT,env=None):
    with log.open('w') as out:
        out.write(shlex.join(map(str,command))+'\n');out.flush()
        subprocess.run(command,cwd=cwd,env=env,stdout=out,stderr=subprocess.STDOUT,check=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen',type=int,choices=(32,64),default=32)
    parser.add_argument('--icache-bytes',type=int,default=16384)
    parser.add_argument('--dcache-bytes',type=int,default=8192)
    parser.add_argument('--bank-xor-mask',type=int,choices=(0,1,2,3),default=2)
    parser.add_argument('--clock',choices=('yolo60','yolo60_core81'),default='yolo60')
    parser.add_argument('--output',type=Path,help='new result directory; existing runs are preserved')
    args=parser.parse_args();os.chdir(ROOT)
    width=args.xlen;opt=optimization()
    config=hardware_configuration('yolo',width,args.icache_bytes,args.dcache_bytes,args.bank_xor_mask,clock=args.clock)
    root=args.output.resolve() if args.output else ROOT/f'build/yolo/system-rv{width}-{opt}-i{args.icache_bytes}-d{args.dcache_bytes}-h{args.bank_xor_mask}'
    root.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ,SOC='1',SOC_DDR='0',CCACHE_DIR=str(ROOT/'build/ccache'),
             CCACHE_TEMPDIR=str(ROOT/'build/ccache-tmp'))
    command=['bash','scripts/verilator/build_baremetal_image.sh',str(width),str(root),
             'software/common/baremetal/crt0.S','software/common/baremetal/runtime.c',
             'software/common/baremetal/softarith.c','software/yolo/main.c']
    run(command,root/'software-build.log',env=env)
    sources=rtl_sources()
    digest=hashlib.sha256(json.dumps([config,sources],sort_keys=True).encode()).hexdigest()[:16]
    model=ROOT/f'build/yolo/models/{width}-{digest}';binary=model/'Vtb_yolo_system'
    if not binary.exists():
        model.mkdir(parents=True)
        copy_sources([Path(p) for p in sources],model/'source')
        command=['verilator','--binary','--timing','--assert','-Wall','-Wno-fatal','-j','2','-CFLAGS','-O1',
                 f'-GICACHE_BYTES={args.icache_bytes}',f'-GDCACHE_BYTES={args.dcache_bytes}',
                 f'-GCLOCK_PROFILE={config["board_clock_profile"]}',
                 *[f'-D{k}={v}' for k,v in config['macros'].items()],'-f','scripts/system_files.f',
                 'tb/common/store_result_monitor.sv','tb/soc/axi_system_memory_model.sv',
                 'tb/soc/spi_flash_model.sv','tb/soc/tb_soc_system.sv','tb/soc/tb_yolo_system.sv',
                 '--top-module','tb_yolo_system','-Mdir',str(model)]
        run(command,model/'build.log',model/'source',env)
        (model/'build.json').write_text(json.dumps(dict(config=config,command=command,
            source_sha256=sources,binary_sha256=sha(binary)),indent=2)+'\n')
    nm=subprocess.check_output([os.environ['RISCV_TOOL_ROOT']+'/riscv64-unknown-elf-nm',str(root/'program.elf')],text=True)
    symbols=symbols_from_nm(nm)
    command=[str(binary),f'+IMEM={root}/imem.hex',f'+DMEM={root}/dmem.hex',
             f'+TOHOST={symbols["tohost"]:x}',f'+CONSOLE={symbols["sim_console"]:x}',
             '+TEST=yolo','+MAX_CYCLES=10000000']
    run(command,root/'simulation.log')
    text=(root/'simulation.log').read_text()
    for marker in (f'PASS yolo RV{width}',f'PASS YOLO_DMA_MAC RV{width}'):
        if marker not in text:raise ValueError('missing '+marker)
    report=dict(status='PASS',xlen=width,optimization=opt,config=config,command=command,
        commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        model_receipt=str(model/'build.json'),log_sha256=sha(root/'simulation.log'),
        software_sha256={str(p):sha(p) for p in Path('software/yolo').glob('*') if p.is_file()},
        image_sha256={p.name:sha(p) for p in [root/'program.elf',root/'imem.hex',root/'dmem.hex']})
    (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    for line in text.splitlines():
        if line.startswith('PASS '):print(line)


if __name__=='__main__':main()
