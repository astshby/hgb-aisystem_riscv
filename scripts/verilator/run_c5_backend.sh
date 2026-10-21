#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
case "$xlen" in 32|64) ;; *) echo "XLEN must be 32 or 64" >&2; exit 2;; esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
passes=0

# 独立源码清单不依赖施工中的Core接线；每次只有一个-j1编译进程，日志保留完整配置。
run_test() {
    local name="$1" width="$2" depth="$3"
    local tag="c5-backend-rv${xlen}-w${width}-q${depth}-${name}"
    local output="build/verilator/${tag}" prefix="logs/${tag}"
    mkdir -p "$output"
    verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
        --x-initial unique --x-assign unique \
        -DCORE_XLEN="$xlen" -DCORE_ISSUE_WIDTH="$width" -DCORE_RETIRE_ENTRIES="$depth" \
        -Mdir "$output" -f scripts/c5_backend_files.f "tb/unit/${name}.sv" \
        --top-module "$name" >"${prefix}-build.log" 2>&1 \
        || { tail -n 35 "${prefix}-build.log"; exit 1; }
    if rg -n '(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|%Error)' "${prefix}-build.log"; then
        exit 1
    fi
    local seeds=(1)
    if [[ "$name" == tb_retire_queue_dual ]]; then seeds=(1 7 31); fi
    for seed in "${seeds[@]}"; do
        local log="${prefix}-seed${seed}.log"
        "$output/V${name}" "+seed=${seed}" +verilator+rand+reset+2 "+verilator+seed+${seed}" \
            >"$log" 2>&1 || { tail -n 35 "$log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS ${name}" "$log"; then
            tail -n 35 "$log"; exit 1
        fi
        rg "^PASS ${name}" "$log"
        passes=$((passes+1))
    done
}

for depth in 2 4 8; do
    for name in tb_retire_queue_dual tb_retire_queue tb_retire_gpr_query; do
        run_test "$name" 2 "$depth"
    done
done
run_test tb_regfile_dual 2 4
run_test tb_regfile 2 4
# 单发射兼容配置也主动驱动第二口，确认构建开关真正禁用而不是靠输入碰巧为零。
run_test tb_retire_queue_dual 1 4
run_test tb_regfile_dual 1 4
echo "PASS c5-backend RV${xlen}: ${passes} runs, 0 SKIP"
