#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "$xlen" == 32 || "$xlen" == 64 ]] || exit 2
clock_profile="${2:-1}"
[[ "$clock_profile" == 1 || "$clock_profile" == 9 || "$clock_profile" == 10 ]] || exit 2
source scripts/verilator/p1_core_config.sh
source scripts/verilator/p2_core_config.sh
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
log_root="${P2_LOG_ROOT:-logs/p2/clock-contract}"
name="soc-clock-contract-rv$xlen-$p2_core_build_tag-c$clock_profile"
out="build/p2/$name"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$log_root"
command=(verilator --binary --assert --timing -Wall -Wno-fatal -j 2 -DCORE_XLEN="$xlen" "${p2_core_flags[@]}"
    -f scripts/system_files.f tb/soc/tb_soc_clock_contract.sv
    -GCLOCK_PROFILE="$clock_profile" --top-module tb_soc_clock_contract -Mdir "$out")
commands="$log_root/clock-contract-rv$xlen-c$clock_profile.commands.txt"
printf '%q ' "${command[@]}" > "$commands"
printf '\n%q\n' "$out/Vtb_soc_clock_contract" >> "$commands"
"${command[@]}" >"$log_root/$name.build.log" 2>&1 || { tail -40 "$log_root/$name.build.log"; exit 1; }
if rg '%(Error|Warning-(LATCH|UNOPTFLAT|MULTIDRIVEN|ALWCOMBORDER))' "$log_root/$name.build.log"; then exit 1; fi
"$out/Vtb_soc_clock_contract" >"$log_root/$name.run.log" 2>&1 || { tail -30 "$log_root/$name.run.log"; exit 1; }
rg '^PASS' "$log_root/$name.run.log"
python3 scripts/verilator/p2_manifest.py "$log_root/clock-contract-rv$xlen-c$clock_profile.manifest.json" --binary "$out/Vtb_soc_clock_contract" --commands "$commands"
