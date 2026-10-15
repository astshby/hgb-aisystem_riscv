#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
[[ "${RT_COREMARK_ITERATIONS:-1}" == 1 ]] || { echo 'UART integration TB requires RT_COREMARK_ITERATIONS=1'; exit 2; }
export RT_APP=coremark RT_COREMARK_LAYOUT=ddr RT_COREMARK_RESIDENT=1
export RT_COREMARK_BAUD=500000 RT_COREMARK_ITERATIONS=1 MUL_IMPL=0 DIV_IMPL=1
export CROSS_COMPILE="${CROSS_COMPILE:-/usr/bin/riscv64-linux-gnu-}"
mode="${RT_COREMARK_MODE:-performance}"
mkdir -p logs
bash scripts/rt-thread/build.sh "$xlen" > "logs/uart-rt-$mode-build-rv$xlen.log" 2>&1 || {
    tail -n 40 "logs/uart-rt-$mode-build-rv$xlen.log"; exit 1;
}
app="build/rt-thread/coremark-ddr-$mode-rv$xlen-resident-baud500000"
export LOADER_PACKET="$app/program.hgb"
python3 scripts/loader/host.py "$app/program.elf" --output "$LOADER_PACKET"
hot_start=$(awk '$3=="__hot_start" {print $1}' "$app/program.nm")
hot_end=$(awk '$3=="__hot_end" {print $1}' "$app/program.nm")
export LOADER_HOT_BYTES=$((16#$hot_end - 16#$hot_start))
export LOADER_TOHOST=$(awk '$3=="tohost" {print $1}' "$app/program.nm")
export LOADER_CONSOLE=$(awk '$3=="sim_console" {print $1}' "$app/program.nm")
[[ -n "$LOADER_TOHOST" && -n "$LOADER_CONSOLE" ]]
# 只改变宿主 C++ 优化；不改变固件、RTL 或 UART 周期契约。
export LOADER_HOST_OPT="${LOADER_HOST_OPT:--O2}"
bash scripts/loader/test_soc.sh "$xlen"
