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

# 隔离普通回归产物；每次只启动一个编译，三种队列容量都跑真实流水/总线监视。
passes=0
for depth in 2 4 8; do
    for name in tb_core_retire_queue tb_core_bus_contract tb_core_interrupt; do
        out="build/verilator/retire-integration-rv${xlen}-${core_build_tag}-n${depth}/${name}"
        log="logs/retire-integration-rv${xlen}-${core_build_tag}-n${depth}-${name}.log"
        mkdir -p "$out"
        verilator "${core_microarch_flags[@]:0:2}" "-DCORE_ISSUE_WIDTH=$core_issue_width" -Wall -Wno-fatal --assert --timing --binary -j 1 \
            -DCORE_XLEN="$xlen" -DCORE_RETIRE_ENTRIES="$depth" \
            -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
            -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
            tb/common/store_result_monitor.sv tb/common/retire_contract_monitor.sv \
            "tb/core/${name}.sv" --top-module "$name" >"$log" 2>&1 \
            || { tail -n 30 "$log"; exit 1; }
        "$out/V${name}" >>"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS ${name} " "$log"; then
            tail -n 30 "$log"
            exit 1
        fi
        rg "^PASS ${name} " "$log"
        passes=$((passes + 1))
    done
done
echo "PASS retire-integration RV${xlen}: ${passes} runs, 0 SKIP"
