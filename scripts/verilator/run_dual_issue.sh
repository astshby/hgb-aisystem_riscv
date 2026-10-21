#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# 默认覆盖两XLEN、两发射宽度；队列容量显式列出，q4不伪称持续双退休。
xlen_arg="${1:-all}"
[[ $# -le 1 && "$xlen_arg" =~ ^(32|64|all)$ ]] || {
    echo 'usage: C5_ISSUES="1 2" C5_QUEUES="8" run_dual_issue.sh [32|64|all]' >&2
    exit 2
}
widths=(32 64)
[[ "$xlen_arg" == all ]] || widths=("$xlen_arg")
read -r -a issue_widths <<< "${C5_ISSUES:-1 2}"
read -r -a capacities <<< "${C5_QUEUES:-8}"
[[ ${#issue_widths[@]} -gt 0 && ${#capacities[@]} -gt 0 ]] || exit 2
for issue in "${issue_widths[@]}"; do [[ "$issue" =~ ^(1|2)$ ]] || exit 2; done
for capacity in "${capacities[@]}"; do [[ "$capacity" =~ ^(2|4|8|16)$ ]] || exit 2; done
mul="${MUL_IMPL:-0}"
div="${DIV_IMPL:-1}"
predictor="${PREDICTOR_MODE:-0}"
ras="${RAS_ENABLE:-0}"
[[ "$mul" =~ ^[012]$ && "$div" =~ ^[01]$ && "$predictor" =~ ^[01]$ && "$ras" =~ ^[01]$ ]] || exit 2
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
passes=0
for width in "${widths[@]}"; do
    for capacity in "${capacities[@]}"; do
        for issue in "${issue_widths[@]}"; do
            tag="c5-core-rv${width}-m${mul}d${div}-p${predictor}r${ras}-i${issue}-q${capacity}"
            out="build/verilator/$tag"
            build_log="logs/$tag.build.log"
            run_log="logs/$tag.run.log"
            mkdir -p "$out"
            verilator -Wall -Wno-fatal --assert --timing --binary -j 1 -CFLAGS -O0 \
                -DCORE_XLEN="$width" -DCORE_ISSUE_WIDTH="$issue" -DCORE_RETIRE_ENTRIES="$capacity" \
                -DCORE_MUL_IMPL="$mul" -DCORE_DIV_IMPL="$div" \
                -DCORE_PREDICTOR_MODE="$predictor" -DCORE_RAS_ENABLE="$ras" \
                -Mdir "$out" -f scripts/sim_files.f tb/common/rv_asm_pkg.sv \
                tb/core/tb_core_dual_issue.sv --top-module tb_core_dual_issue >"$build_log" 2>&1 || {
                    tail -n 30 "$build_log"; exit 1;
                }
            if rg -n '%(Error|Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER))' "$build_log"; then exit 1; fi
            # 旧CSR地址宽度等告警保留日志；新TB不允许增加宽度告警。
            if rg -n '%Warning-WIDTH[^:]*: tb/core/tb_core_dual_issue.sv:' "$build_log"; then exit 1; fi
            "$out/Vtb_core_dual_issue" >"$run_log" 2>&1 || { tail -n 25 "$run_log"; exit 1; }
            if rg -q '(%Fatal|%Error|Assertion failed)' "$run_log" ||
               ! rg -q '^PASS tb_core_dual_issue ' "$run_log"; then
                tail -n 25 "$run_log"; exit 1
            fi
            rg '^(DUAL scenario=0 |PASS tb_core_dual_issue )' "$run_log"
            passes=$((passes+1))
        done
    done
done
echo "PASS C5 Core matrix: $passes configurations, 0 SKIP"
