#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ ]] || { echo "Usage: $0 [32|64]" >&2; exit 2; }
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
out="build/verilator/lsu-transaction-rv${xlen}-${core_build_tag}"
prefix="logs/lsu-transaction-rv${xlen}-${core_build_tag}"
mkdir -p "$out" logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 \
    --x-initial unique --x-assign unique -DCORE_XLEN="$xlen" \
    -Mdir "$out" -f scripts/lsu_transaction_files.f tb/unit/tb_lsu_transaction.sv \
    --top-module tb_lsu_transaction >"${prefix}-build.log" 2>&1 \
    || { tail -n 35 "${prefix}-build.log"; exit 1; }
if rg -n '%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|WIDTH)' "${prefix}-build.log"; then
    exit 1
fi
for seed in 1 7 31; do
    log="${prefix}-seed${seed}.log"
    "$out/Vtb_lsu_transaction" "+seed=$seed" +verilator+rand+reset+2 "+verilator+seed+$seed" \
        >"$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
    if rg -q '%Fatal|%Error|Assertion failed' "$log" || ! rg -q '^PASS tb_lsu_transaction ' "$log"; then
        tail -n 35 "$log"; exit 1
    fi
    rg '^PASS tb_lsu_transaction ' "$log"
done
# 协议违规必须由专用断言拒绝，不能把普通退出或另一个错误当成负例通过。
ulimit -c 0
for violation in CANCEL HEAD; do
    negative_log="${prefix}-negative-${violation,,}.log"
    if "$out/Vtb_lsu_transaction" "+NEGATIVE_$violation" >"$negative_log" 2>&1; then
        echo "blocked-request $violation unexpectedly passed" >&2; exit 1
    fi
    if [[ "$violation" == CANCEL ]]; then
        rg -q 'LSU cancel cannot withdraw a blocked request' "$negative_log"
    else
        rg -q 'LSU head permission cannot withdraw a blocked request' "$negative_log"
    fi
done
echo "PASS lsu-transaction RV$xlen: 3 seeds, 2 expected protocol rejections, 0 SKIP"
