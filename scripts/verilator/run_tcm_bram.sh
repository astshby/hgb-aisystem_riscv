#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/tcm-bram}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
for instruction in 0 1; do
    name="tcm-bram-rv$xlen-if$instruction"
    out="build/$name"
    mkdir -p "$out"
    python3 - "$xlen" "$out/init.hex" <<'PY'
import sys
from pathlib import Path
xlen = int(sys.argv[1])
Path(sys.argv[2]).write_text(''.join(
    f'{int.from_bytes(bytes(((i+j)^0x97) & 255 for j in range(xlen//8)), "little"):0{xlen//4}x}\n'
    for i in range(0, 1024, xlen//8)))
PY
    command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen"
        -f scripts/rtl_files.f -f scripts/soc_files.f tb/soc/tb_tcm_bram.sv
        --top-module tb_tcm_bram -GINSTRUCTION="$instruction" -Mdir "$out")
    printf '%q ' "${command[@]}" > "$log_root/$name.commands.txt"
    printf '\n' >> "$log_root/$name.commands.txt"
    "${command[@]}" > "$log_root/$name.build.log" 2>&1 || { tail -30 "$log_root/$name.build.log"; exit 1; }
    if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/$name.build.log"; then exit 1; fi
    for seed in 430097725 19349663 83492791; do
        command=("$out/Vtb_tcm_bram" "+SEED=$seed" "+IMAGE=$out/init.hex")
        printf '%q ' "${command[@]}" >> "$log_root/$name.commands.txt"
        printf '\n' >> "$log_root/$name.commands.txt"
        "${command[@]}" > "$log_root/$name-$seed.log" 2>&1 || { tail -20 "$log_root/$name-$seed.log"; exit 1; }
        rg '^PASS ' "$log_root/$name-$seed.log"
    done
    python3 scripts/verilator/p2_manifest.py "$log_root/$name.manifest.json" \
        --binary "$out/Vtb_tcm_bram" --commands "$log_root/$name.commands.txt"
done
