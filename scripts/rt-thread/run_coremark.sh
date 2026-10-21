#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-64}"
source scripts/rt-thread/sim_config.sh
mode="${RT_COREMARK_MODE:-performance}"
layout="${RT_COREMARK_LAYOUT:-tcm}"
tag="$mode"
if [[ "$layout" == ddr ]]; then tag="ddr-$mode"; fi
export RT_APP=coremark
export RT_COREMARK_ITERATIONS="${RT_COREMARK_ITERATIONS:-1}"
mkdir -p logs
bash scripts/rt-thread/build.sh "$xlen" > "logs/rt-coremark-$tag-build-rv$xlen-p$soc_profile.log" 2>&1 || {
    tail -n 60 "logs/rt-coremark-$tag-build-rv$xlen-p$soc_profile.log"; exit 1;
}
bash scripts/rt-thread/build_sim.sh "$xlen"
out="build/rt-thread/coremark-$mode-rv$xlen"
extra_args=()
if [[ "${RT_COREMARK_LAYOUT:-tcm}" == ddr ]]; then
    out="build/rt-thread/coremark-ddr-$mode-rv$xlen"
    extra_args=(+DDR_IMAGE="$out/ddr.hex" +DDR_CODE_CHECK)
fi
sim="build/verilator/rt-thread-coremark-rv$xlen-${rt_sim_tag}/Vtb_rt_thread_coremark"
tohost=$(awk '$3 == "tohost" {print $1}' "$out/program.nm")
console=$(awk '$3 == "sim_console" {print $1}' "$out/program.nm")
hot_start=$(awk '$3 == "__hot_start" {print $1}' "$out/program.nm")
hot_end=$(awk '$3 == "__hot_end" {print $1}' "$out/program.nm")
hot_bytes=$((16#$hot_end - 16#$hot_start))
log="logs/rt-coremark-$tag-rv$xlen-${rt_sim_tag}.log"
"$sim" +IMEM="$out/imem.hex" +DMEM="$out/dmem.hex" \
    +TOHOST="$tohost" +CONSOLE="$console" +HOT_BYTES="$hot_bytes" "${extra_args[@]}" \
    +TEST=rt-coremark +MAX_CYCLES="${RT_COREMARK_MAX_CYCLES:-40000000}" > "$log" 2>&1 || {
    tail -n 50 "$log"; exit 1;
}
if [[ "$RT_COREMARK_ITERATIONS" == 0 ]]; then
    grep -q 'PASS rt-thread CoreMark DDR valid-duration CRC' "$log"
else
    grep -q 'PASS rt-thread CoreMark DDR functional CRC (short run)' "$log"
fi
grep -q "PASS rt CoreMark SoC integration RV$xlen" "$log"
grep -E 'CoreMark Size|Total ticks|Iterations|Correct operation validated|PASS rt' "$log"
