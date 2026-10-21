#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

xlen="${1:-32}"
if (( $# > 1 )); then echo "Usage: $0 [32|64]" >&2; exit 2; fi
case "$xlen" in
    32|64) ;;
    *) echo "XLEN must be 32 or 64" >&2; exit 2 ;;
esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp"
export CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"

# 独立 C4a 单元，不构建/选择第二套 Core；每次只启动一个 -j1 编译进程。
passes=0
run_case() {
    local top="$1" config="$2"
    shift 2
    local out="build/verilator/predictor-units-rv${xlen}-${config}"
    local prefix="logs/predictor-units-rv${xlen}-${config}"
    mkdir -p "$out"
    verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
        --x-initial unique --x-assign unique -DCORE_XLEN="$xlen" \
        -Mdir "$out" -f scripts/predictor_unit_files.f "tb/unit/${top}.sv" \
        --top-module "$top" "$@" >"${prefix}-build.log" 2>&1 \
        || { tail -n 40 "${prefix}-build.log"; return 1; }
    # -Wno-fatal 只容许未使用/时间单位等提示，协议和时序结构告警仍阻止执行模型。
    if rg -q '(%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|WIDTH))' "${prefix}-build.log"; then
        rg -n -A5 '(%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER|WIDTH))' "${prefix}-build.log"
        return 1
    fi
    "$out/V${top}" +verilator+rand+reset+2 +verilator+seed+17 >"${prefix}.log" 2>&1 \
        || { tail -n 40 "${prefix}.log"; return 1; }
    if rg -q '(%Fatal|%Error|Assertion failed)' "${prefix}.log" ||
       ! rg -q "^PASS ${top} " "${prefix}.log"; then
        tail -n 40 "${prefix}.log"
        return 1
    fi
    rg "^PASS ${top} " "${prefix}.log"
    passes=$((passes + 1))
}

# 默认对照加小/大参数：恢复槽数独立于 RAS 深度与退休队列容量。
run_case tb_predictor_ras ras4-replay8 -GDEPTH=4 -GREPLAY_SLOTS=8
run_case tb_predictor_ras ras1-replay1 -GDEPTH=1 -GREPLAY_SLOTS=1
run_case tb_predictor_ras ras8-replay10 -GDEPTH=8 -GREPLAY_SLOTS=10
run_case tb_predictor_direction local64-h8-choice32 -GLHT_ENTRIES=64 -GHISTORY_W=8 -GCHOOSER_ENTRIES=32
run_case tb_predictor_direction local2-h1-choice2 -GLHT_ENTRIES=2 -GHISTORY_W=1 -GCHOOSER_ENTRIES=2
run_case tb_predictor_direction local8-h4-choice4 -GLHT_ENTRIES=8 -GHISTORY_W=4 -GCHOOSER_ENTRIES=4
run_case tb_predictor_read_first btb64-gshare64
echo "PASS predictor-units RV${xlen}: ${passes} runs, 0 SKIP"
