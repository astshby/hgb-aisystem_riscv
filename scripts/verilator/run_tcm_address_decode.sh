#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/m1-local-followup-20261022/decode}"
out="build/p2/tcm-decode-rv$xlen"
mkdir -p "$log_root" "$CCACHE_TEMPDIR" "$CCACHE_DIR"
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen"
    -f scripts/soc_files.f tb/soc/tb_tcm_address_decode.sv --top-module tb_tcm_address_decode
    -Mdir "$out")
commands="$log_root/commands-rv$xlen.txt"
printf '%q ' "${command[@]}" > "$commands"
printf '\n' >> "$commands"
"${command[@]}" > "$log_root/build-rv$xlen.log" 2>&1 || { tail -35 "$log_root/build-rv$xlen.log"; exit 1; }
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/build-rv$xlen.log"; then exit 1; fi
printf '%q\n' "$out/Vtb_tcm_address_decode" >> "$commands"
"$out/Vtb_tcm_address_decode" > "$log_root/run-rv$xlen.log" 2>&1
rg '^PASS ' "$log_root/run-rv$xlen.log"
python3 scripts/verilator/p2_manifest.py "$log_root/decode-rv$xlen.manifest.json" \
    --binary "$out/Vtb_tcm_address_decode" --commands "$commands"
