#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh

xlen="${1:-32}"
case "$xlen" in
    32|64) ;;
    *) echo "XLEN must be 32 or 64" >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"

# 固定随机种子与独立目录避免覆盖普通单测的模型和证据。
passes=0
for depth in 2 4 8 16; do
    out="build/verilator/retire-queue-rv${xlen}-${core_build_tag}-n${depth}"
    prefix="logs/retire-queue-rv${xlen}-${core_build_tag}-n${depth}"
    mkdir -p "$out"
    verilator "${core_microarch_flags[@]:0:2}" "-DCORE_ISSUE_WIDTH=$core_issue_width" -Wall -Wno-fatal --assert --timing --binary -j 1 \
        --x-initial unique --x-assign unique \
        -DCORE_XLEN="$xlen" -DCORE_RETIRE_ENTRIES="$depth" \
        -Mdir "$out" -f scripts/rtl_files.f tb/unit/tb_retire_queue.sv \
        --top-module tb_retire_queue >"${prefix}-build.log" 2>&1 \
        || { tail -n 30 "${prefix}-build.log"; exit 1; }
    for seed in 1 7 31; do
        log="${prefix}-seed${seed}.log"
        "$out/Vtb_retire_queue" "+seed=${seed}" +verilator+rand+reset+2 \
            "+verilator+seed+${seed}" >"$log" 2>&1 \
            || { tail -n 30 "$log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "$log" ||
           ! rg -q '^PASS tb_retire_queue ' "$log"; then
            tail -n 30 "$log"
            exit 1
        fi
        rg '^PASS tb_retire_queue ' "$log"
        passes=$((passes + 1))
    done
done
echo "PASS retire-queue RV${xlen}: ${passes} runs, 0 SKIP"
