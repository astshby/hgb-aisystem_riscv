#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/soc_profile.sh
ddr_bytes="${SOC_DDR_BYTES:-0}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ && "$ddr_bytes" =~ ^(0|65536)$ ]] || {
    echo "Usage: SOC_PROFILE=full|lite SOC_DDR_BYTES=0|65536 $0 [32|64]" >&2; exit 2;
}
suffix="rv${xlen}-p${soc_profile}-ddr${ddr_bytes}"
out="build/verilator/soc-profile-$suffix"
log="logs/soc-profile-$suffix.log"
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p "$out" logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -DCORE_XLEN="$xlen" \
    -Mdir "$out" -f scripts/soc_files.f tb/soc/tb_soc_profile.sv \
    -GSOC_PROFILE="$soc_profile_id" -GDDR_BYTES="$ddr_bytes" --top-module tb_soc_profile \
    > "$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
"$out/Vtb_soc_profile" >> "$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
if grep -Eq '(%Fatal|%Error|Assertion failed|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN))' "$log"; then
    tail -n 35 "$log"; exit 1;
fi
grep "^PASS tb_soc_profile RV$xlen profile=$soc_profile_id DDR_BYTES=$ddr_bytes " "$log"
