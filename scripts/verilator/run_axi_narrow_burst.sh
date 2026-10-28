#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/axi-narrow-burst}"
out="build/axi-narrow-burst-rv$xlen"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root" "$out"
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen"
    -f scripts/rtl_files.f -f scripts/axi_files.f tb/soc/tb_axi_narrow_burst.sv
    --top-module tb_axi_narrow_burst -Mdir "$out")
printf '%q ' "${command[@]}" > "$log_root/command-rv$xlen.txt"
printf '\n' >> "$log_root/command-rv$xlen.txt"
"${command[@]}" > "$log_root/build-rv$xlen.log" 2>&1 || { tail -30 "$log_root/build-rv$xlen.log"; exit 1; }
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/build-rv$xlen.log"; then exit 1; fi
"$out/Vtb_axi_narrow_burst" > "$log_root/run-rv$xlen.log" 2>&1 || { tail -20 "$log_root/run-rv$xlen.log"; exit 1; }
rg '^PASS ' "$log_root/run-rv$xlen.log"
