#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh

xlen="${1:-32}"
case "$xlen" in
    32|64) ;;
    *) echo "XLEN must be 32 or 64" >&2; exit 2 ;;
esac
mul_impl="${MUL_IMPL:-0}"
div_impl="${DIV_IMPL:-0}"
config="rv${xlen}-${core_build_tag}-m${mul_impl}d${div_impl}"
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"

# 保留固定种子，失败可重现；每个 TB 单独编译，不覆盖普通回归模型或日志。
seeds=(1 7 31 101 997)
tests=(tb/unit/tb_branch_result_register.sv tb/unit/tb_ex_stage.sv tb/unit/tb_wb_stage.sv
       tb/core/tb_core_bus_contract.sv tb/core/tb_core_interrupt.sv)
passes=0
for tb_path in "${tests[@]}"; do
    test_name="$(basename "$tb_path" .sv)"
    out="build/verilator/timing-random-${config}/${test_name}"
    prefix="logs/timing-random-${config}-${test_name}"
    mkdir -p "$out"
    # 随机初值必须在编译时保留；只传运行时 seed 不能替代 --x-initial unique。
    MAKEFLAGS="${MAKEFLAGS:-} OPT_FAST=-O0 OPT_SLOW=-O0" \
        verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
        --x-initial unique --x-assign unique \
        -DCORE_XLEN="$xlen" -DCORE_MUL_IMPL="$mul_impl" -DCORE_DIV_IMPL="$div_impl" \
        -Mdir "$out" -f scripts/sim_files.f \
        tb/common/rv_asm_pkg.sv tb/common/store_result_monitor.sv "$tb_path" \
        --top-module "$test_name" >"${prefix}-build.log" 2>&1 \
        || { tail -n 30 "${prefix}-build.log"; exit 1; }
    for seed in "${seeds[@]}"; do
        log="${prefix}-seed${seed}.log"
        "$out/V${test_name}" +verilator+rand+reset+2 "+verilator+seed+${seed}" \
            >"$log" 2>&1 || { tail -n 30 "$log"; exit 1; }
        if rg -q '(%Fatal|%Error|Assertion failed)' "$log" ||
           ! rg -q "PASS ${test_name}" "$log"; then
            tail -n 30 "$log"
            exit 1
        fi
        passes=$((passes + 1))
        echo "PASS random-init ${config} ${test_name} seed=${seed}"
    done
done
echo "PASS timing-boundary-random ${config}: ${passes} runs, 0 SKIP"
