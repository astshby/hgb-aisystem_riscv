#!/usr/bin/env python3
"""Test the video clock with unmodified PDS simulation models; never invoke PDS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--log-root', type=Path, required=True)
    args = parser.parse_args()
    vendor = Path(os.environ.get('PDS_HOME', '')) / 'arch/vendor/pango/verilog/simulation'
    libraries = [vendor / name for name in ('GTP_PPLL.v', 'GTP_CLKBUFG.v')]
    if not os.environ.get('PDS_HOME') or not all(path.is_file() for path in libraries):
        parser.error('PDS_HOME must contain the unmodified PPLL and CLKBUFG simulation models')
    output, logs = args.output.resolve(), args.log_root.resolve()
    for path in (output, logs):
        if path.exists() and any(path.iterdir()):
            parser.error('use fresh build/log directories')
        path.mkdir(parents=True, exist_ok=True)
    sources = [REPO / name for name in ('vsrc/cpu/pango_video_pll.sv', 'vsrc/cpu/pango_soc_reset.sv',
               'vsrc/soc/common/soc_reset_controller.sv', 'tb/fpga/tb_pango_video_pll.sv')]
    env = os.environ.copy()
    for name, directory in (('CCACHE_DIR','ccache'),('CCACHE_TEMPDIR','ccache-tmp')):
        (output / directory).mkdir()
        env[name] = str(output / directory)
    command = ['verilator','--binary','--timing','--assert','-Wno-fatal','-j','1','--threads','1',
               '--top-module','tb_pango_video_pll','--Mdir',str(output/'model')]
    command += [str(path) for path in libraries+sources]
    receipt = {'status':'prepared','scope':'unmodified vendor PPLL model; no PDS or board',
               'build':command,'run':[str(output/'model/Vtb_pango_video_pll')],
               'source_sha256':{str(path.relative_to(REPO)):sha(path) for path in sources},
               'vendor_sha256':{path.name:sha(path) for path in libraries},
               'vendor_root':str(vendor),'jobs':1}
    for stage in ('build','run'):
        log = logs/(stage+'.log')
        with log.open('w') as stream:
            result = subprocess.run(receipt[stage],cwd=REPO,env=env,stdout=stream,stderr=subprocess.STDOUT)
        receipt[stage+'_exit'] = result.returncode
        receipt[stage+'_log_sha256'] = sha(log)
        if result.returncode:
            receipt['status'] = 'FAIL'
            (logs/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
            raise SystemExit(f'{stage} failed: {log}')
    text = (logs/'run.log').read_text()
    if not re.search(r'^PASS vendor PPLL ',text,re.M) or re.search('error|illegal|fatal',text,re.I):
        raise SystemExit('missing PASS or vendor model error; inspect run.log')
    receipt.update(status='PASS',pass_count=1,skip_count=0,binary_sha256=sha(output/'model/Vtb_pango_video_pll'),
                   measurements=[line for line in text.splitlines() if line.startswith(('VIDEO_PLL','PASS'))])
    (logs/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS vendor PPLL clock/reset:',logs/'receipt.json')


if __name__ == '__main__':
    main()
