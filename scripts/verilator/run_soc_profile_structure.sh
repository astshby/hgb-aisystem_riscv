#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/soc_profile.sh
ddr_bytes="${SOC_DDR_BYTES:-0}"
local_tcm="${SOC_LOCAL_TCM_ENABLE:-0}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ && "$ddr_bytes" =~ ^(0|65536)$ && "$local_tcm" =~ ^[01]$ ]] || {
    echo "Usage: SOC_PROFILE=full|lite SOC_LOCAL_TCM_ENABLE=0|1 SOC_DDR_BYTES=0|65536 $0 [32|64]" >&2; exit 2;
}
suffix="rv${xlen}-p${soc_profile}-ltcm${local_tcm}-ddr${ddr_bytes}"
out="build/profile-structure/$suffix"
log="logs/soc-profile-structure-$suffix.log"
mkdir -p "$out" logs
# 本机 Verilator 5.052 使用 JSON AST；不依赖已移除的 XML 输出，不把 elaboration 当 LUT 报告。
verilator -Wall -Wno-fatal --timing --json-only --json-only-output "$out/rtl.tree.json" \
    --json-only-meta-output "$out/rtl.meta.json" -DCORE_XLEN="$xlen" -f scripts/soc_files.f \
    --top-module soc_top -GSOC_PROFILE="$soc_profile_id" -GLOCAL_TCM_ENABLE="$local_tcm" \
    -GDDR_BYTES="$ddr_bytes" \
    > "$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
python3 -B scripts/verilator/check_soc_profile_structure.py "$out/rtl.tree.json" \
    --profile "$soc_profile" --ddr-bytes "$ddr_bytes" --xlen "$xlen" \
    --local-tcm "$local_tcm" | tee -a "$log"
python3 -B tb/scripts/test_soc_profile_structure.py "$out/rtl.tree.json" \
    --profile "$soc_profile" --ddr-bytes "$ddr_bytes" --xlen "$xlen" \
    --local-tcm "$local_tcm" | tee -a "$log"
