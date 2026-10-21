#!/usr/bin/env bash
# Run independent local/slow ownership and physical TCM tests; keep S2a throughput unchanged.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
xlen="${1:-32}"
local_tcm="${SOC_LOCAL_TCM_ENABLE:-0}"
[[ $# -le 1 && "$xlen" =~ ^(32|64)$ && "$local_tcm" =~ ^[01]$ ]] || {
    echo "Usage: SOC_LOCAL_TCM_ENABLE=0|1 $0 [32|64]" >&2; exit 2;
}
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
suffix="rv${xlen}-ltcm${local_tcm}"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" logs
for test_name in tb_soc_memory_router tb_tcm_local_fabric tb_soc_local_tcm; do
    out_dir="build/verilator/soc-local-tcm-${suffix}/${test_name}"
    log="logs/${test_name}-${suffix}.log"
    mkdir -p "$out_dir"
    parameters=()
    if [[ "$test_name" != tb_tcm_local_fabric ]]; then parameters+=("-GLOCAL_TCM_ENABLE=$local_tcm"); fi
    echo "LOCAL_TCM build ${test_name} XLEN=${xlen} LOCAL_TCM_ENABLE=${local_tcm} log=${log}"
    if ! verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
        -DCORE_XLEN="$xlen" -Mdir "$out_dir" -f scripts/soc_files.f \
        "tb/soc/${test_name}.sv" "${parameters[@]}" --top-module "$test_name" > "$log" 2>&1; then
        tail -n 35 "$log"; exit 1;
    fi
    if ! "$out_dir/V${test_name}" >> "$log" 2>&1; then tail -n 35 "$log"; exit 1; fi
    if grep -Eq '(%Fatal|%Error|Assertion failed|%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN))' "$log"; then
        tail -n 35 "$log"; exit 1;
    fi
    grep -E '^(THROUGHPUT |OFFER |COUNTS |SCENARIO |PASS )' "$log"
    grep -q "^PASS ${test_name} RV${xlen} " "$log"
done
