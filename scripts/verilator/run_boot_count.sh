#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_parent="${BOOT_COUNT_LOG_ROOT:-logs/boot-count}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_parent"
log_root="$(mktemp -d "$log_parent/rv$xlen-XXXXXX")"
build_root="build/boot-count/$(basename "$log_root")-$p2_core_build_tag"
commands="$log_root/commands.txt"
printf 'BOOT_COUNT_LOG=%s\n' "$log_root"

# 同一个软件FIFO检查最小深度、绕回、反压和同拍双出双入；载荷也逐条比对。
for depth in 2 4 8; do
    out="$build_root/fetch-d$depth"
    log="$log_root/fetch-d$depth"
    mkdir -p "$out"
    command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 1 -CFLAGS -O0
        -DCORE_XLEN="$xlen" "${p2_core_flags[@]}" -GDEPTH="$depth"
        -f scripts/rtl_files.f tb/unit/tb_fetch_queue.sv
        --top-module tb_fetch_queue -Mdir "$out")
    printf '%q ' "${command[@]}" >> "$commands"; printf '\n' >> "$commands"
    "${command[@]}" > "$log.build.log" 2>&1 || { tail -40 "$log.build.log"; exit 1; }
    printf '%q\n' "$out/Vtb_fetch_queue" >> "$commands"
    "$out/Vtb_fetch_queue" > "$log.run.log" 2>&1 || { cat "$log.run.log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log.run.log"; then cat "$log.run.log"; exit 1; fi
    rg '^PASS tb_fetch_queue ' "$log.run.log"
done

# ROM跳转、ISS保序、两类IQ容量、恢复和退休分别由现有独立模型检查。
export SCOREBOARD_LOG_ROOT="$log_root/scoreboard" SCOREBOARD_BUILD_ROOT="$build_root"
command=(bash scripts/verilator/run_scoreboard.sh "$xlen"
    boot_prefix issue split_iq split_iq_small recovery retirement)
printf '%q ' "${command[@]}" >> "$commands"; printf '\n' >> "$commands"
"${command[@]}"
python3 - "$xlen" "$log_root" "$p2_core_build_tag" <<'PY'
from pathlib import Path
import hashlib
import json
import subprocess
import sys

xlen, directory, configuration = sys.argv[1:]
root = Path(directory)
sources = sorted(Path('vsrc').rglob('*.sv'))
sources += [Path('scripts/rtl_files.f'), Path('scripts/verilator/run_boot_count.sh'),
            Path('scripts/verilator/run_scoreboard.sh'), Path('scripts/verilator/p2_core_config.sh'),
            Path('scripts/verilator/core_build_config.sh'), Path('tb/unit/tb_fetch_queue.sv')]
sources += sorted(Path('tb/unit/scoreboard').glob('*.sv'))
logs = sorted(root.rglob('*.log')) + [root / 'commands.txt']
run_logs = sorted(root.rglob('*.run.log'))
passed = sum(sum(line.startswith('PASS ') for line in p.read_text().splitlines()) for p in run_logs)
assert passed == 9, f'expected 9 completed cases, found {passed}'
receipt = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'branch': subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
    'xlen': int(xlen), 'configuration': configuration,
    'stage': 'RTL simulation', 'clock_period_ns': 10,
    'firmware': 'literal instructions in tb_scoreboard_boot_prefix.sv; no ELF/HEX',
    'pass': passed, 'skip': 0, 'fail': 0,
    'source_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'evidence_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in logs},
}
(root / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(f'PASS boot-count RV{xlen}: {passed} cases; receipt={root / "receipt.json"}')
PY
