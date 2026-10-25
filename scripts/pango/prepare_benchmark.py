#!/usr/bin/env python3
"""Stage the same three CoreMark hardware configurations; no PDS launch or board programming."""
import argparse
import json
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from benchmark_config import CONFIG, ROOT, configuration, sha
import prepare_project as board


def compile_tcm(config):
    clocks=config['frequencies_hz']
    params=['ONCHIP_SOC '+str(int(config['platform']=='soc_tcm')),
            'ITCM_INIT_FILE "firmware/imem.hex"','DTCM_INIT_FILE "firmware/dmem.hex"']
    params += [d.upper()+'_CLOCK_HZ '+str(clocks[d] or 1) for d in ('core','sys','periph')]
    return (f'compile -top_module {config["pds_top"]} -verilog_standard SystemVerilog '
            '-compiler_directives {'+' '.join(f'{k}={v}' for k,v in config['macros'].items())+'} '
            '-defined_parameters {'+' '.join(params)+'} -loop_limit 65536')


def constraints(config):
    lines=['# Runnable TCM configuration; external clocks, no board pin or CDC timing closure claim.']
    for d in config['domains']:
        lines += [f'create_clock -name {{clk_{d}}} -period {{{config["periods_ps"][d]/1000:g}}} [get_ports {{clk_{d}}}]',
                  f'set_clock_uncertainty -setup 0.2 [get_clocks {{clk_{d}}}]',
                  f'set_clock_uncertainty -hold 0.05 [get_clocks {{clk_{d}}}]']
    return '\n'.join(lines)+'\n'


def stage(output, config, bundle, sim_receipt, ip_dir=None):
    if output.exists() and any(output.iterdir()):
        raise ValueError('PDS output must be empty; preserve previous runs')
    native=subprocess.check_output(['wslpath','-w',str(output)],text=True).strip() if sys.platform!='win32' else str(output)
    if not native.isascii() or PureWindowsPath(native).drive.startswith('\\\\') or not PureWindowsPath(native).drive:
        raise ValueError('PDS requires an ASCII native Windows drive path')
    firmware=json.loads((bundle/'manifest.json').read_text())
    simulation=json.loads(sim_receipt.read_text())
    if simulation['config']!=config:
        raise ValueError('simulation and synthesis configurations differ')
    for name,digest in simulation['source_sha256'].items():
        if Path(name).suffix in ('.sv','.svh','.v','.vh','.f') and sha(ROOT/name)!=digest:
            raise ValueError('RTL/test inputs changed since paired simulation build: '+name)
    image=next(im for im in firmware['images'] if im['scenario']=='tcm' and im['mode']=='performance')
    for name,digest in image['image_sha256'].items():
        if sha(bundle/name)!=digest: raise ValueError('modified frozen firmware: '+name)
    if config['platform']=='soc_ddr':
        if config['native_board_profile'] is None or ip_dir is None:
            raise ValueError('full DDR staging requires generated DDR IP and a supported native board clock profile')
        m=config['macros']
        flags={'retire-entries':'CORE_RETIRE_ENTRIES','split-issue-queue':'CORE_SPLIT_ISSUE_QUEUE',
               'limited-integer-ooo':'CORE_LIMITED_INTEGER_OOO','scheduler-forward-mode':'CORE_SCHEDULER_FORWARD_MODE',
               'integer-queue-entries':'CORE_ISSUE_QUEUE_ENTRIES','memory-queue-entries':'CORE_MEMORY_QUEUE_ENTRIES',
               'predictor-mode':'CORE_PREDICTOR_MODE','ras-enable':'CORE_RAS_ENABLE'}
        # 通用板级脚本接收 build/loader 固件。临时源目录直接提供本次已冻结的
        # CoreMark，不依赖或覆盖工作区原有 loader；正式 PDS 输入保留在 output。
        with tempfile.TemporaryDirectory(prefix='paired-stage-',dir=ROOT/'build') as tmp:
            source=Path(tmp)
            inputs=set(board.sources(ROOT,'scripts/pango_files.f')) | set((ROOT/'scripts').glob('*.f'))
            inputs.update(ROOT/'scripts/pango'/name for name in (
                'prepare_project.py','check_ip_dq.py','mes2l676_200hp.fdc',
                'implement.tcl','memory_gate.ps1','memory_guard.ps1'))
            for path in inputs:
                dest=source/path.relative_to(ROOT)
                dest.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(path,dest)
            loader=source/'build/loader/rv32'
            loader.mkdir(parents=True)
            for original,dest in (('imem.hex','imem.hex'),('dmem.hex','dmem.hex'),('program.elf','loader.elf')):
                shutil.copyfile(bundle/image['directory']/original,loader/dest)
            command=[sys.executable,str(source/'scripts/pango/prepare_project.py'),'--output',str(output),
                     '--ip-dir',str(ip_dir.resolve()),'--core-backend','scoreboard',
                     '--board-clock-profile',str(config['native_board_profile'])]
            for name,macro in flags.items(): command += ['--'+name,str(m[macro])]
            subprocess.run(command,check=True,cwd=source)
        native_manifest=json.loads((output/'manifest.json').read_text())
    else:
        output.mkdir(parents=True,exist_ok=True)
        rtl=[p.relative_to(ROOT) for p in board.sources(ROOT,'scripts/system_files.f')]
        rtl += [Path('vsrc/cpu/'+p+'.sv') for p in
                ('pango_measure_hot','pango_measure_scan','benchmark_core_tcm','pango_benchmark_tcm_top')]
        for p in rtl:
            (output/p).parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/p,output/p)
        (output/'benchmark.fdc').write_text(constraints(config))
        commands=['set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6',
                  'set_option max_threads 1',*[f'add_design {{{p.as_posix()}}}' for p in rtl],
                  'add_constraint {benchmark.fdc}',compile_tcm(config)]
        (output/'compile.tcl').write_text('\n'.join(commands)+'\n')
        for name in ('implement.tcl','memory_gate.ps1','memory_guard.ps1'):
            shutil.copyfile(ROOT/'scripts/pango'/name,output/name)
    (output/'firmware').mkdir(exist_ok=True)
    for name in ('imem.hex','dmem.hex','program.elf'):
        shutil.copyfile(bundle/image['directory']/name,output/'firmware'/name)
    for name in ('imem.hex','dmem.hex'):
        words=(output/'firmware'/name).read_text().split()
        for bank in (0,1):
            (output/'firmware'/f'{name}.bank{bank}').write_text('\n'.join(words[bank::2])+'\n')
    if config['platform']=='soc_ddr':
        # 保留通用板级核验器的文件名；清单明确该 ELF 已换为同份 TCM CoreMark。
        shutil.copyfile(output/'firmware/program.elf',output/'firmware/loader.elf')
        native_manifest['firmware_role']='unified TCM CoreMark, not production Flash loader'
        native_manifest['files']={name:sha(output/name) for name in native_manifest['files']}
        board.verify_staged_manifest(output,native_manifest)
        (output/'manifest.json').write_text(json.dumps(native_manifest,indent=2)+'\n')
    (output/'benchmark_synthesize.tcl').write_text(
        'set bench_root [file dirname [info script]]\n'
        'puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
        '-File [file join $bench_root memory_gate.ps1] -LogDirectory [file join $bench_root memory] -Phase synthesis]\n'
        'source [file join $bench_root compile.tcl]\nset_option max_threads 1\n'
        'synthesize -ads -selected_syn_tool_opt 2 -max_path 100 -nworst 3 -report_logic_level_distribution -report_exception TRUE\n')
    for name in ('benchmark_config.py','benchmark_platforms.json'):
        shutil.copyfile(ROOT/'scripts'/name,output/name)
    shutil.copyfile(sim_receipt,output/'simulation-build.json')
    manifest=dict(schema=1,config=config,firmware=image,firmware_manifest_sha256=sha(bundle/'manifest.json'),
                  backend='real DDR3 controller and PHY' if config['platform']=='soc_ddr' else 'production TCM RTL; external clock inputs',
                  status='staged inputs only; no synthesis or timing result',
                  simulation_receipt_sha256=sha(sim_receipt),
                  source_branch=subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip(),
                  source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  files={str(p.relative_to(output)):sha(p) for p in sorted(output.rglob('*')) if p.is_file()})
    (output/'benchmark.json').write_text(json.dumps(manifest,indent=2)+'\n')
    verify(output)
    print(f'PASS staged paired {config["platform"]}: {output}')


def verify(root):
    manifest=json.loads((root/'benchmark.json').read_text())
    c=manifest['config']
    if c!=configuration(c['platform'],c['clock'],c['xlen']): raise ValueError('platform configuration changed')
    for name,digest in manifest['files'].items():
        if sha(root/name)!=digest: raise ValueError('modified PDS input: '+name)
    sim=json.loads((root/'simulation-build.json').read_text())
    if sim['config']!=c: raise ValueError('paired simulation configuration mismatch')
    for name,digest in sim['source_sha256'].items():
        if name in manifest['files'] and manifest['files'][name]!=digest:
            raise ValueError('synthesis source differs from paired simulation: '+name)
    if c['platform']=='soc_ddr':
        board.verify_staged_manifest(root,json.loads((root/'manifest.json').read_text()))
    elif compile_tcm(c) not in (root/'compile.tcl').read_text() or constraints(c)!=(root/'benchmark.fdc').read_text():
        raise ValueError('compiled clocks/macros differ from paired configuration')
    for name in ('imem.hex','dmem.hex'):
        words=(root/'firmware'/name).read_text().split()
        for bank in (0,1):
            if (root/'firmware'/f'{name}.bank{bank}').read_text().split()!=words[bank::2]:
                raise ValueError('TCM bank image mismatch')
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--platform',choices=CONFIG['platforms'])
    parser.add_argument('--clock',choices=CONFIG['clock_periods_ps'],default='target')
    parser.add_argument('--bundle',type=Path)
    parser.add_argument('--ip-dir',type=Path)
    parser.add_argument('--sim-receipt',type=Path)
    parser.add_argument('--verify',action='store_true')
    args=parser.parse_args()
    if args.verify:
        verify(args.output.resolve()); print('PASS paired PDS inputs'); return
    if not args.platform or not args.bundle or not args.sim_receipt:
        parser.error('--platform, --bundle and --sim-receipt are required for staging')
    stage(args.output.resolve(),configuration(args.platform,args.clock),args.bundle.resolve(),args.sim_receipt.resolve(),args.ip_dir)


if __name__=='__main__':
    main()
