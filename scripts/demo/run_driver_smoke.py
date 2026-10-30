#!/usr/bin/env python3
"""Build a fresh real-core SoC model and run the production NPU driver, without replacing CPU execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.hardware_config import hardware_configuration
from scripts.pango.prepare_project import sources
from scripts.sim_support import symbols_from_nm


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--logs', type=Path, required=True)
    parser.add_argument('--softmath', type=Path)
    args = parser.parse_args()
    output, logs = args.output.resolve(), args.logs.resolve()
    for path in (output, logs):
        path.mkdir(parents=True, exist_ok=False)
    config = hardware_configuration('yolo', args.xlen, 16384, 8192, 2)
    paths = {str(p.relative_to(ROOT)) for p in sources(ROOT, 'scripts/system_files.f')}
    paths.update(str(p.relative_to(ROOT)) for p in (ROOT / 'scripts').glob('*.f'))
    paths.update(str(p.relative_to(ROOT)) for p in (ROOT / 'tb/common').glob('*.sv*'))
    paths.update(('tb/common/store_result_monitor.sv', 'tb/soc/axi_system_memory_model.sv',
                  'tb/soc/spi_flash_model.sv', 'tb/soc/tb_soc_system.sv', 'tb/yolo/tb_yolo_driver.sv'))
    paths.update(str(p.relative_to(ROOT)) for p in (ROOT / 'vsrc/pkg').glob('*.svh'))
    frozen = output / 'source'
    hashes = {name: sha(ROOT / name) for name in sorted(paths)}
    for name in paths:
        destination = frozen / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, destination)
    env = dict(os.environ, SOC='1', SOC_DDR='0', SOFTWARE_OPT='O3')
    for key, suffix in (('CCACHE_DIR', 'ccache'), ('CCACHE_TEMPDIR', 'ccache-tmp')):
        path = output / suffix
        path.mkdir()
        env[key] = str(path)
    report = dict(status='prepared', branch=subprocess.check_output(
        ['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip(),
        base_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        config=config, source_sha256=hashes, commands=[],
        scope='real integer RISC-V Core, production tiled C driver, actual SoC and NPU RTL; three small convolutions, not full YOLO demo')

    def run(name, command, cwd=ROOT):
        report['commands'].append(dict(stage=name, argv=list(map(str, command))))
        with (logs / (name + '.log')).open('w') as stream:
            stream.write(shlex.join(map(str, command)) + '\n')
            stream.flush()
            result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        report[name + '_exit'] = result.returncode
        report[name + '_log_sha256'] = sha(logs / (name + '.log'))
        (logs / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
        if result.returncode:
            raise SystemExit(name + ' failed: ' + str(logs / (name + '.log')))

    firmware = ['software/common/baremetal/crt0.S', 'software/common/baremetal/runtime.c',
                'software/common/baremetal/softarith.c', 'software/yolo/conv_schedule.c',
                'software/yolo/network.c', 'software/yolo/demo_libc.c', 'tb/yolo/conv_driver_smoke.c']
    libraries = ['-lm', '-lgcc']
    if args.xlen == 64:
        if args.softmath is None:
            parser.error('--softmath is required for pure RV64IM')
        libraries = [str(args.softmath.resolve())]
    build = ['bash', 'scripts/verilator/build_baremetal_image.sh', str(args.xlen), str(output),
             '-Wall', '-Wextra', '-Werror', '-fno-fast-math', '-ffp-contract=off',
             '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections', *firmware, *libraries]
    run('firmware', build)
    report['software_sha256'] = {name: sha(ROOT / name) for name in firmware}
    model = output / 'model'
    compile_rtl = ['verilator', '--binary', '--timing', '--assert', '-Wall', '-Wno-fatal',
                   '-j', '1', '--threads', '1', f'-GCLOCK_PROFILE={config["board_clock_profile"]}',
                   f'-GNPU_PERIOD_PS={config["periods_ps"]["npu"]}', '--output-split', '5000', '--output-split-cfuncs', '100',
                   '-CFLAGS', '-O1 -g0', *[f'-D{k}={v}' for k, v in config['macros'].items()],
                   '-f', 'scripts/system_files.f', 'tb/common/store_result_monitor.sv',
                   'tb/soc/axi_system_memory_model.sv', 'tb/soc/spi_flash_model.sv',
                   'tb/soc/tb_soc_system.sv', 'tb/yolo/tb_yolo_driver.sv',
                   '--top-module', 'tb_yolo_driver', '--Mdir', str(model)]
    run('rtl-build', compile_rtl, frozen)
    binary = model / 'Vtb_yolo_driver'
    nm = subprocess.check_output([str(Path(env['RISCV_TOOL_ROOT']) / 'riscv64-unknown-elf-nm'),
                                  str(output / 'program.elf')], text=True)
    symbols = symbols_from_nm(nm)
    simulation = [str(binary), f'+IMEM={output}/imem.hex', f'+DMEM={output}/dmem.hex',
                  f'+TOHOST={symbols["tohost"]:x}', f'+CONSOLE={symbols["sim_console"]:x}',
                  '+TEST=yolo-production-driver', '+MAX_CYCLES=20000000']
    run('simulation', simulation)
    text = (logs / 'simulation.log').read_text()
    if 'PASS yolo production driver cases=3 outputs=171 quantize=5 real-core real-NPU' not in text:
        raise SystemExit('missing complete driver PASS')
    report.update(status='PASS', image_sha256={name: sha(output / name) for name in
                  ('program.elf', 'imem.hex', 'dmem.hex')}, binary_sha256=sha(binary))
    if args.softmath:
        report['softmath_sha256'] = sha(args.softmath)
    (logs / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS RV{args.xlen} production C driver: 3 convolutions, 171 outputs, 5 quantized values')


if __name__ == '__main__':
    main()
