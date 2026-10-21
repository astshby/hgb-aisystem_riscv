#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/rt-thread/sim_config.sh
mkdir -p logs
bash scripts/rt-thread/build.sh "$xlen" > "logs/rt-thread-build-rv$xlen-p$soc_profile.log" 2>&1 || {
    tail -n 60 "logs/rt-thread-build-rv$xlen-p$soc_profile.log"; exit 1;
}
bash scripts/rt-thread/build_sim.sh "$xlen"
out="build/rt-thread/rv$xlen"
tohost=$(awk '$3 == "tohost" {print $1}' "$out/program.nm")
console=$(awk '$3 == "sim_console" {print $1}' "$out/program.nm")
sim="build/verilator/rt-thread-rv${xlen}-${rt_sim_tag}/Vtb_rt_thread"
hot_start=$(awk '$3 == "__hot_start" {print $1}' "$out/program.nm")
hot_end=$(awk '$3 == "__hot_end" {print $1}' "$out/program.nm")
hot_bytes=$((16#$hot_end - 16#$hot_start))
log="logs/rt-thread-rv$xlen-${rt_sim_tag}.log"
# BSP 按运行时发现同一 ELF 支持两个 profile；保留每次运行实际镜像哈希。
sha256sum "$out/program.elf" > "${log%.log}.elf.sha256"
"$sim" +IMEM="$out/imem.hex" +DMEM="$out/dmem.hex" +TOHOST="$tohost" +CONSOLE="$console" \
    +HOT_BYTES="$hot_bytes" +UART_LOOPBACK +GPIO_LOOPBACK +TEST=rt-thread +MAX_CYCLES=10000000 > "$log" 2>&1 || {
    tail -n 40 "$log"; exit 1;
}
grep 'PASS rt' "$log"
grep -q "PASS rt-thread RV$xlen" "$log"
grep -q "PASS rt hardware RV$xlen" "$log"
grep -q "PASS rt capabilities profile=$soc_profile_id " "$log"
