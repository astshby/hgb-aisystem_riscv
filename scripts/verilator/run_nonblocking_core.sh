#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
case "$xlen" in 32|64) ;; *) echo "XLEN must be 32 or 64" >&2; exit 2 ;; esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi
passes=0
# 默认先验四槽，容量/后端矩阵可复用同一独立年龄与总线监视；串行 -j1 不争抢编译内存。
for depth in ${RETIRE_DEPTHS:-4}; do
    case "$depth" in 2|4|8) ;; *) echo "RETIRE_DEPTHS accepts only 2, 4, 8" >&2; exit 2 ;; esac
    for name in ${CORE_TESTS:-tb_core_nonblocking tb_core_retire_queue tb_core_bus_contract}; do
        tag="c2c-rv${xlen}-${core_build_tag}-n${depth}-m${MUL_IMPL:-0}-d${DIV_IMPL:-0}-${name}"
        out="build/verilator/$tag"
        log="logs/$tag.log"
        mkdir -p "$out"
        verilator "${core_microarch_flags[@]:0:2}" "-DCORE_ISSUE_WIDTH=$core_issue_width" -Wall -Wno-fatal --assert --timing --binary -j 1 \
            --x-initial unique --x-assign unique "${host_cflags[@]}" \
            -DCORE_XLEN="$xlen" -DCORE_RETIRE_ENTRIES="$depth" \
            -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
            -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
            tb/common/store_result_monitor.sv tb/common/retire_contract_monitor.sv \
            "tb/core/$name.sv" --top-module "$name" >"$log" 2>&1 \
            || { tail -n 20 "$log"; exit 1; }
        if rg -q '%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)' "$log"; then
            rg '%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)' "$log"
            exit 1
        fi
        "$out/V$name" +verilator+seed+"${RTL_SEED:-1}" >>"$log" 2>&1 \
            || { tail -n 12 "$log"; exit 1; }
        if rg -q '%Fatal|%Error|Assertion failed' "$log" || ! rg -q "^PASS $name " "$log"; then
            tail -n 12 "$log"; exit 1
        fi
        rg "^PASS $name " "$log"
        passes=$((passes + 1))
    done
done
echo "PASS nonblocking-core RV${xlen}: ${passes} runs, 0 SKIP"
