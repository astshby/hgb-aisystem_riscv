#!/usr/bin/env python3
"""Record source, executable, software image and exact command identities for P2 simulation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--image-dir', type=Path)
    parser.add_argument('--commands', type=Path)
    args = parser.parse_args()
    paths = set()
    for pattern in ('vsrc/**/*.sv', 'scripts/**/*.sh', 'scripts/**/*.py', 'scripts/*.f',
                    'tb/soc/*.sv', 'tb/software/*.c', 'tb/common/*.sv', 'tb/common/*.svh', 'tb/common/*.vh'):
        paths.update(Path('.').glob(pattern))
    hashes = {str(p): digest(p) for p in sorted(paths) if p.is_file()}
    result = {
        'branch': subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
        'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'worktree_status': subprocess.check_output(['git', 'status', '--short'], text=True),
        'source_sha256': hashes,
        'source_set_sha256': hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
        'verilator': subprocess.check_output(['verilator', '--version'], text=True).strip(),
        'environment': {key: value for key, value in sorted(os.environ.items())
                        if key.startswith(('SYSTEM_', 'SOC_', 'COREMARK_', 'P2_')) or
                        key in ('RISCV_TOOL_ROOT', 'CORE_BACKEND', 'ISSUE_WIDTH', 'RETIRE_ENTRIES',
                                'MUL_IMPL', 'DIV_IMPL', 'PREDICTOR_MODE', 'RAS_ENABLE',
                                'SPLIT_ISSUE_QUEUE', 'INTEGER_QUEUE_ENTRIES', 'MEMORY_QUEUE_ENTRIES',
                                'LIMITED_INTEGER_OOO', 'SCHEDULER_FORWARD_MODE',
                                'CORE_PREDICTOR_MODE', 'CORE_RAS_ENABLE', 'CORE_RETIRE_ENTRIES', 'CORE_ISSUE_WIDTH')},
        'physical_timing': 'not run',
    }
    if args.binary:
        result['binary'] = {'path': str(args.binary), 'sha256': digest(args.binary)}
    if args.image_dir:
        result['images'] = {str(p): digest(p) for p in sorted(args.image_dir.iterdir())
                            if p.suffix in ('.hex', '.elf') and p.is_file()}
    if args.commands:
        result['commands_shell'] = args.commands.read_text()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
