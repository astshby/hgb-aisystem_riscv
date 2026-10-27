#!/usr/bin/env python3
"""Build and run RT-Thread independently on the complete four-domain SoC."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(ROOT/'scripts'),str(ROOT/'scripts/verilator')]
from hardware_config import hardware_configuration
from sim_support import sha
import sim_support as support


def run(command,log,cwd=ROOT,env=None):
    with log.open('w') as out:
        out.write(shlex.join(map(str,command))+'\n');out.flush()
        subprocess.run(command,cwd=cwd,env=env,stdout=out,stderr=subprocess.STDOUT,check=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen',type=int,choices=(32,64),default=32)
    args=parser.parse_args();os.chdir(ROOT)
    opt=support.optimization();width=args.xlen
    root=ROOT/f'build/rt-thread/system-rv{width}-{opt}';root.mkdir(parents=True,exist_ok=True)
    run(['bash','scripts/rt-thread/build.sh',str(width)],root/'software-build.log')
    config=hardware_configuration('none',width)
    sources=support.rtl_sources()
    digest=hashlib.sha256(json.dumps([config,sources],sort_keys=True).encode()).hexdigest()[:16]
    model=ROOT/f'build/rt-thread/models/{width}-{digest}';binary=model/'Vtb_rt_thread_system'
    env=dict(os.environ,CCACHE_DIR=str(ROOT/'build/ccache'),CCACHE_TEMPDIR=str(ROOT/'build/ccache-tmp'))
    if not binary.exists():
        model.mkdir(parents=True,exist_ok=True)
        support.copy_sources([Path(p) for p in sources],model/'source')
        command=['verilator','--binary','--timing','--assert','-Wall','-Wno-fatal','-j','2','-CFLAGS','-O1',
                 *[f'-D{k}={v}' for k,v in config['macros'].items()],'-f','scripts/system_files.f',
                 'tb/common/store_result_monitor.sv','tb/soc/axi_system_memory_model.sv',
                 'tb/soc/spi_flash_model.sv','tb/soc/tb_soc_system.sv','tb/soc/tb_rt_thread_system.sv',
                 '--top-module','tb_rt_thread_system','-Mdir',str(model)]
        run(command,model/'build.log',model/'source',env)
        (model/'build.json').write_text(json.dumps(dict(config=config,command=command,source_sha256=sources,binary_sha256=sha(binary)),indent=2)+'\n')
    symbols=support.symbols_from_nm((root/'program.nm').read_text())
    command=[str(binary),f'+IMEM={root}/imem.hex',f'+DMEM={root}/dmem.hex',f'+DDR={root}/ddr.hex',
             f'+TOHOST={symbols["tohost"]:x}',f'+CONSOLE={symbols["sim_console"]:x}',
             '+UART_LOOPBACK','+GPIO_LOOPBACK','+TEST=rt-thread','+MAX_CYCLES=30000000']
    run(command,root/'simulation.log')
    text=(root/'simulation.log').read_text()
    for marker in (f'PASS rt-thread RV{width}',f'PASS rt four-domain RV{width}',
                   'PASS rt register context + thread return + idle','PASS rt capabilities profile=0'):
        if marker not in text:raise ValueError('missing '+marker)
    report=dict(status='PASS',xlen=width,optimization=opt,config=config,command=command,
                commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                model_receipt=str(model/'build.json'),image_sha256={p.name:sha(p) for p in [root/'program.elf',*root.glob('*.hex')]},
                software_sha256={str(p):sha(p) for p in Path('software/rt-thread').glob('*') if p.is_file()},
                log_sha256=sha(root/'simulation.log'),coremark=False)
    (root/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    for line in text.splitlines():
        if line.startswith('PASS '):print(line)
    print('PASS standalone RT-Thread result '+str(root/'result.json'))


if __name__=='__main__':main()
