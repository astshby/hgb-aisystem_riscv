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

# 三种容量、两类测试分别编译；查询模型用多个固定种子，编译始终单进程。
passes=0
for depth in 2 4 8; do
    for name in tb_retire_gpr_query tb_ex_operand_register; do
        out="build/verilator/retire-operands-rv${xlen}-${core_build_tag}-n${depth}-${name}"
        prefix="logs/retire-operands-rv${xlen}-${core_build_tag}-n${depth}-${name}"
        mkdir -p "$out"
        verilator "${core_microarch_flags[@]:0:2}" "-DCORE_ISSUE_WIDTH=$core_issue_width" -Wall -Wno-fatal --assert --timing --binary -j 1 \
            --x-initial unique --x-assign unique \
            -DCORE_XLEN="$xlen" -DCORE_RETIRE_ENTRIES="$depth" \
            -Mdir "$out" -f scripts/rtl_files.f "tb/unit/${name}.sv" \
            --top-module "$name" >"${prefix}-build.log" 2>&1 \
            || { tail -n 30 "${prefix}-build.log"; exit 1; }
        # -Wno-fatal 只容许已有未使用信号等告警，组合环/锁存器/多驱动和位宽错误必须阻断。
        if rg -q '%(Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|WIDTH))' "${prefix}-build.log"; then
            tail -n 30 "${prefix}-build.log"
            exit 1
        fi
        seeds=(1)
        if [[ "$name" == tb_retire_gpr_query ]]; then seeds=(1 7 31); fi
        for seed in "${seeds[@]}"; do
            log="${prefix}-seed${seed}.log"
            "$out/V${name}" "+seed=${seed}" +verilator+rand+reset+2 \
                "+verilator+seed+${seed}" >"$log" 2>&1 \
                || { tail -n 30 "$log"; exit 1; }
            if rg -q '(%Fatal|%Error|Assertion failed)' "$log" || ! rg -q "^PASS ${name} " "$log"; then
                tail -n 30 "$log"
                exit 1
            fi
            rg "^PASS ${name} " "$log"
            passes=$((passes + 1))
        done
    done
done
echo "PASS retire-operands RV${xlen}: ${passes} runs, 0 SKIP"
