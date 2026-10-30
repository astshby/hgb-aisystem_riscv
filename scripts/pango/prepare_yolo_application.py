#!/usr/bin/env python3
"""Stage complete UART/HDMI YOLO firmware and matching C10 RTL; never run PDS."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import prepare_project as board


def verify(root):
    root = Path(root).resolve()
    manifest = json.loads((root / 'manifest.json').read_text())
    board.verify_staged_manifest(root, manifest)
    if (manifest.get('firmware_role') != 'yolo-interactive' or not manifest.get('npu_enable') or
            not manifest.get('video_enable') or manifest['board_clock_profile'] != 10):
        raise ValueError('requires complete C10 YOLO UART/HDMI application')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firmware-dir', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ip-dir', type=Path)
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=32)
    parser.add_argument('--synthesis-strategy', choices=('standard', 'timing-v2', 'timing-v3'), default='timing-v2')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify(args.output)
        print('PASS complete YOLO application inputs')
        return
    if args.firmware_dir is None or args.ip_dir is None:
        parser.error('--firmware-dir and --ip-dir are required')
    root = Path(__file__).resolve().parents[2]
    board.inspect_firmware(args.firmware_dir.resolve(), args.xlen, 'yolo-interactive', root)
    command = [sys.executable, str(root / 'scripts/pango/prepare_project.py'),
               '--output', str(args.output.resolve()), '--ip-dir', str(args.ip_dir.resolve()),
               '--xlen', str(args.xlen), '--core-backend', 'scoreboard',
               '--board-clock-profile', '10', '--npu-enable', '--video-enable', '1',
               '--firmware-role', 'yolo-interactive', '--firmware-dir', str(args.firmware_dir.resolve()),
               '--icache-bytes', '16384', '--dcache-bytes', '8192', '--dcache-bank-xor-mask', '2',
               '--synthesis-strategy', args.synthesis_strategy]
    subprocess.run(command, cwd=root, check=True)
    verify(args.output)
    print('PASS staged complete YOLO UART/HDMI firmware; synthesis and physical timing not run')


if __name__ == '__main__':
    main()
