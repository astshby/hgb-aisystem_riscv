#!/usr/bin/env python3
"""Stage the passing bare-metal YOLO image and matching five-domain RTL for PDS."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hardware_config import ROOT, hardware_configuration
from sim_support import sha
import prepare_project as board


def verify(root):
    result = json.loads((root/'application.json').read_text())
    for name, digest in result['files'].items():
        if sha(root/name) != digest:
            raise ValueError('modified paired application input: '+name)
    board.verify_staged_manifest(root, json.loads((root/'manifest.json').read_text()))
    return result


def stage(application, output, ip):
    run = json.loads((application/'result.json').read_text())
    model = json.loads(Path(run['model_receipt']).read_text())
    config = run['config']
    memory = config['memory']
    if run['status'] != 'PASS' or run['xlen'] != 32 or config != hardware_configuration(
            'yolo', 32, memory['icache_bytes'], memory['dcache_bytes'], memory.get('dcache_bank_xor_mask', 0),
            clock=config.get('clock')):
        raise ValueError('requires passing RV32 YOLO with the current hardware configuration')
    if model['config'] != config:
        raise ValueError('YOLO simulation model configuration mismatch')
    if sha(application/'simulation.log') != run['log_sha256']:
        raise ValueError('YOLO simulation log changed')
    for name, digest in run['image_sha256'].items():
        if sha(application/name) != digest:
            raise ValueError('YOLO application image changed: '+name)
    for name, digest in model['source_sha256'].items():
        if sha(ROOT/name) != digest:
            raise ValueError('YOLO hardware changed since simulation: '+name)
    if output.exists():
        raise ValueError('application project needs a new directory')
    with tempfile.TemporaryDirectory(prefix='yolo-native-', dir=ROOT/'build') as temporary:
        source = Path(temporary)
        inputs = set(board.sources(ROOT, 'scripts/pango_files.f'))
        inputs.update((ROOT/'scripts').glob('*.f'))
        inputs.update((ROOT/'scripts').glob('*.json'))
        inputs.update(p for p in (ROOT/'scripts/pango').iterdir() if p.is_file())
        for path in inputs:
            target = source/path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        loader = source/'build/loader/rv32'; loader.mkdir(parents=True)
        for src, dst in (('imem.hex', 'imem.hex'), ('dmem.hex', 'dmem.hex'), ('program.elf', 'loader.elf')):
            shutil.copyfile(application/src, loader/dst)
        m = config['macros']
        command = [sys.executable, str(source/'scripts/pango/prepare_project.py'),
                   '--output', str(output), '--ip-dir', str(ip), '--core-backend', 'scoreboard',
                   '--board-clock-profile', str(config['board_clock_profile']), '--npu-enable',
                   '--icache-bytes', str(memory['icache_bytes']), '--dcache-bytes', str(memory['dcache_bytes']),
                   '--dcache-bank-xor-mask', str(memory.get('dcache_bank_xor_mask', 0))]
        for flag, macro in (('retire-entries', 'CORE_RETIRE_ENTRIES'), ('split-issue-queue', 'CORE_SPLIT_ISSUE_QUEUE'),
                ('limited-integer-ooo', 'CORE_LIMITED_INTEGER_OOO'), ('scheduler-forward-mode', 'CORE_SCHEDULER_FORWARD_MODE'),
                ('integer-queue-entries', 'CORE_ISSUE_QUEUE_ENTRIES'), ('memory-queue-entries', 'CORE_MEMORY_QUEUE_ENTRIES'),
                ('predictor-mode', 'CORE_PREDICTOR_MODE'), ('ras-enable', 'CORE_RAS_ENABLE')):
            command += ['--'+flag, str(m[macro])]
        subprocess.run(command, cwd=source, check=True)
    # 同一标准综合选项供策略对照，固件明确标为YOLO应用，避免与生产Flash loader混淆。
    (output/'application_synthesize.tcl').write_text(
        'set app_root [file dirname [info script]]\n'
        'puts [exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
        '-File [file join $app_root memory_gate.ps1] -LogDirectory [file join $app_root memory] -Phase synthesis]\n'
        'source [file join $app_root compile.tcl]\nset_option max_threads 1\n'
        'synthesize -ads -selected_syn_tool_opt 2 -max_path 100 -nworst 3 -report_logic_level_distribution -report_exception TRUE\n')
    shutil.copyfile(application/'result.json', output/'simulation-result.json')
    shutil.copyfile(Path(run['model_receipt']), output/'simulation-build.json')
    board_manifest = json.loads((output/'manifest.json').read_text())
    board_manifest['firmware_role'] = 'passing bare-metal YOLO convolution and concurrent DMA test; no RT-Thread'
    (output/'manifest.json').write_text(json.dumps(board_manifest, indent=2)+'\n')
    native_config = dict(config, platform='soc_ddr_yolo', domains=list(config['periods_ps']),
                         native_board_profile=config['board_clock_profile'], npu_enable=1,
                         pds_top='pango_200hp_top', xlen=32)
    result = dict(schema=1, config=native_config, source_commit=run['commit'],
                  application='YOLO 128-MAC bare-metal convolution/DMA validation',
                  software_optimization=run['optimization'],
                  memory_backend='native DDR3 IP; simulation used 256 KiB AXI memory',
                  status='paired application staged; no synthesis or physical result',
                  files={str(p.relative_to(output)): sha(p) for p in sorted(output.rglob('*')) if p.is_file()})
    (output/'application.json').write_text(json.dumps(result, indent=2)+'\n')
    verify(output)
    print(f'PASS paired YOLO application: {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--application', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ip-dir', type=Path)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify(args.output.resolve())
        print('PASS paired YOLO application inputs')
        return
    if args.application is None or args.ip_dir is None:
        parser.error('--application and --ip-dir are required when staging')
    stage(args.application.resolve(), args.output.resolve(), args.ip_dir.resolve())


if __name__ == '__main__':
    main()
