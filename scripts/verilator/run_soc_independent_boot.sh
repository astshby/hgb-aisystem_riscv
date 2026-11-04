#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/independent-boot-$p2_core_build_tag}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
commands="$log_root/independent-boot-rv$xlen.commands.txt"
[[ ! -e "$commands" ]] || { echo "refusing to overwrite $commands" >&2; exit 2; }
for profile in 1 4; do
    out="build/p2/independent-boot-rv$xlen-$p2_core_build_tag-c$profile"
    log="$log_root/independent-boot-rv$xlen-c$profile"
    mkdir -p "$out"
    command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 1 -CFLAGS -O1
        -DCORE_XLEN="$xlen" "${p2_core_flags[@]}" -GCLOCK_PROFILE="$profile"
        -f scripts/system_files.f vsrc/cpu/pango_soc_reset.sv tb/soc/tb_soc_independent_boot.sv
        --top-module tb_soc_independent_boot -Mdir "$out")
    printf '%q ' "${command[@]}" >> "$commands"
    printf '\n' >> "$commands"
    "${command[@]}" > "$log.build.log" 2>&1 || { tail -40 "$log.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log.build.log"; then exit 1; fi
    printf '%q\n' "$out/Vtb_soc_independent_boot" >> "$commands"
    "$out/Vtb_soc_independent_boot" > "$log.run.log" 2>&1 || { cat "$log.run.log"; exit 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "$log.run.log"; then cat "$log.run.log"; exit 1; fi
    rg '^PASS ' "$log.run.log"
    python3 - "$out/Vtb_soc_independent_boot" "$log" "$commands" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
binary, log, commands=map(Path,sys.argv[1:])
paths=sorted(Path('vsrc').rglob('*.sv'))+[Path('tb/soc/tb_soc_independent_boot.sv'),Path('scripts/system_files.f'),Path('scripts/soc_files.f'),Path('scripts/verilator/run_soc_independent_boot.sh'),commands,binary]
receipt={'commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
         'sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
         'program':'eight literal RV instructions in testbench; common to RV32/RV64',
         'passed':True}
log.with_suffix('.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
done
