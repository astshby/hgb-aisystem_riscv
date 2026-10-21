#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/verilator/core_build_config.sh
xlen="${1:-32}"
case "$xlen" in 32|64) ;; *) echo 'XLEN must be 32 or 64' >&2; exit 2 ;; esac
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
mkdir -p logs "$CCACHE_TEMPDIR" "$CCACHE_DIR"
ulimit -c 0
expected=(REQ_BUSY RSP_ORPHAN RSP_ID RSP_DUPLICATE RETIRE_ORPHAN RETIRE_ID
          RETIRE_BEFORE_RSP RETIRE_AFTER_ERROR RSP_ORPHAN RSP_ORPHAN
          RETIRE_ORPHAN RSP_ID REQ_CANCEL RSP_ID RETIRE_ID)
positive=0
negative=0
for bytes in 4 8; do
    tag="store-monitor-rv${xlen}-${core_build_tag}-b${bytes}"
    out="build/verilator/$tag"
    mkdir -p "$out"
    verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary -j 1 \
        --x-initial unique --x-assign unique -DCORE_XLEN="$xlen" -GRESULT_BYTES="$bytes" \
        -Mdir "$out" -f scripts/rtl_files.f tb/common/store_result_monitor.sv \
        tb/unit/tb_store_result_monitor.sv --top-module tb_store_result_monitor \
        >"logs/$tag-build.log" 2>&1 || { tail -n 30 "logs/$tag-build.log"; exit 1; }
    if rg -q '%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)' "logs/$tag-build.log"; then
        rg '%Error|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)' "logs/$tag-build.log"
        exit 1
    fi
    binary="$out/Vtb_store_result_monitor"
    "$binary" +verilator+seed+7 >"logs/$tag.log" 2>&1 \
        || { tail -n 20 "logs/$tag.log"; exit 1; }
    if rg -q '%Fatal|%Error|Assertion failed' "logs/$tag.log" ||
       ! rg -q '^PASS tb_store_result_monitor ' "logs/$tag.log"; then
        tail -n 20 "logs/$tag.log"; exit 1
    fi
    rg '^PASS tb_store_result_monitor ' "logs/$tag.log"
    positive=$((positive+1))
    # 期望错误必须是监视器针对本例给出的唯一标签；普通崩溃/超时/其它断言均为失败。
    for index in "${!expected[@]}"; do
        number=$((index+1))
        log="logs/$tag-negative${number}.log"
        if "$binary" "+NEG_CASE=$number" +verilator+seed+7 >"$log" 2>&1; then
            echo "Negative case unexpectedly succeeded: $tag/$number"; exit 1
        fi
        token="STORE_MONITOR_${expected[$index]}"
        if ! rg -q "Assertion failed.*: ${token}$" "$log" ||
           rg -q 'UNEXPECTED_|STORE_MONITOR_UNKNOWN_ERROR' "$log" ||
           [[ "$(rg -c 'Assertion failed' "$log")" != 1 ]]; then
            tail -n 20 "$log"; exit 1
        fi
        negative=$((negative+1))
    done
done
echo "PASS store-result-monitor RV${xlen}: positive=${positive} expected_reject=${negative} SKIP=0"
