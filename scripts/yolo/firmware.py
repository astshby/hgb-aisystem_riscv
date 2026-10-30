#!/usr/bin/env python3
"""Freeze and verify the complete initialized YOLO UART/HDMI firmware; never launch PDS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/pango'))
from prepare_project import YOLO_INPUTS, inspect_firmware


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare(output, width, optimization, hdmi, baud):
    sources = {name: sha(ROOT / name) for name in YOLO_INPUTS}
    config = dict(application='yolox-tiny-full-network', xlen=width, optimization=optimization,
                  memory='tcm', hdmi=hdmi, baud=baud,
                  march=f'rv{width}im_zicsr', abi='ilp32' if width == 32 else 'lp64')
    identity = hashlib.sha256(json.dumps(dict(config=config, sources=sources), sort_keys=True).encode()).hexdigest()[:16]
    output.mkdir(parents=True, exist_ok=True)
    receipt = dict(config=config, source_sha256=sources, firmware_id=identity,
                   source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                   source_status=subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).splitlines())
    (output / 'build-inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
    (output / 'build-id.h').write_text('#define HGB_YOLO_FIRMWARE_ID "' + identity + '"\n')
    return receipt


def seal(output, tool_root):
    receipt = json.loads((output / 'build-inputs.json').read_text())
    for name, digest in receipt['source_sha256'].items():
        if sha(ROOT / name) != digest:
            raise ValueError('YOLO source changed during firmware build: ' + name)
    prefix = str(tool_root / 'riscv64-unknown-elf-')
    elf = output / 'program.elf'
    dump = subprocess.check_output([prefix + 'objdump', '-d', '-M', 'no-aliases', str(elf)], text=True)
    instructions = 0
    for line in dump.splitlines():
        match = re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s+(\S+)', line)
        if not match:
            continue
        word = int(match[1], 16)
        if len(match[1]) != 8 or word & 3 != 3:
            raise ValueError('unsupported compressed instruction: ' + line)
        if word & 127 in (7, 39, 67, 71, 75, 79, 83) or re.search(r'\b(?:frm|fcsr|fflags)\b', line):
            raise ValueError('unsupported floating-point instruction: ' + line)
        instructions += 1
    symbols = subprocess.check_output([prefix + 'nm', '-n', str(elf)], text=True)
    required = ('main', 'ydm_receive_one', 'yolo_network_infer_rgb888', 'yolo_network_service_init')
    for name in required:
        if not re.search(r'\b' + re.escape(name) + r'$', symbols, re.M):
            raise ValueError('complete application symbol missing: ' + name)
    if subprocess.check_output([prefix + 'nm', '-u', str(elf)], text=True).strip():
        raise ValueError('YOLO firmware has unresolved symbols')
    if receipt['config']['xlen'] == 64:
        archive = Path(os.environ.get('YOLO_SOFTMATH_ARCHIVE', output / 'softmath/libyolo_softmath.a'))
        receipt['libraries_sha256'] = {'rv64im_softmath': sha(archive)}
    receipt.update(image_sha256={name: sha(output / name) for name in ('program.elf', 'imem.hex', 'dmem.hex')},
                   instruction_count=instructions, compressed_instructions=0, floating_point_instructions=0,
                   status='BUILD_AND_ISA_AUDIT_PASS', role='yolo-interactive')
    (output / 'manifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
    actual = inspect_firmware(output, receipt['config']['xlen'], 'yolo-interactive', ROOT)
    (output / 'identity.json').write_text(json.dumps(actual, indent=2) + '\n')
    print('PASS complete YOLO UART/HDMI firmware RV' + str(receipt['config']['xlen']) + ' id=' + receipt['firmware_id'])
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'seal', 'verify'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--optimization', choices=('O2', 'O3', 'Ofast'), default='O3')
    parser.add_argument('--hdmi', type=int, choices=(0, 1), default=1)
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--tool-root', type=Path)
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.output, args.xlen, args.optimization, args.hdmi, args.baud)
    elif args.action == 'seal':
        if args.tool_root is None:
            parser.error('--tool-root is required for the ISA audit')
        seal(args.output, args.tool_root)
    else:
        width = json.loads((args.output / 'manifest.json').read_text())['config']['xlen']
        inspect_firmware(args.output, width, 'yolo-interactive', ROOT)
        print('PASS complete YOLO firmware identity')


if __name__ == '__main__':
    main()
