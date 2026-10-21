#!/usr/bin/env bash
# Fixed traffic measures the real register/fabric/TCM boundary; no RTL substitutions.
set -euo pipefail
xlen="${1:-32}"
interval="${EXPECT_INTERVAL:-3}"
latency="${EXPECT_LATENCY:-3}"
if [[ $# -gt 1 || ! "$xlen" =~ ^(32|64)$ || ! "$interval" =~ ^[1-9][0-9]*$ || ! "$latency" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: EXPECT_INTERVAL=3 EXPECT_LATENCY=3 $0 [32|64]" >&2
    exit 2
fi
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"
suffix="rv${xlen}-i${interval}-l${latency}"
out_dir="build/verilator/soc-throughput-${suffix}"
log="logs/tb_soc_throughput-${suffix}.log"
mkdir -p "$CCACHE_TEMPDIR" "$CCACHE_DIR" "$out_dir" logs
echo "THROUGHPUT build XLEN=${xlen} EXPECT_INTERVAL=${interval} EXPECT_LATENCY=${latency} log=${log}"
# 不使用并行编译；调用者逐个 XLEN 运行，保留每种期望值的独立日志。
if ! verilator -Wall -Wno-fatal --assert --timing --binary -j 1 \
    -DCORE_XLEN="$xlen" -Mdir "$out_dir" \
    -f scripts/soc_files.f tb/soc/tb_soc_throughput.sv \
    -GEXPECT_INTERVAL="$interval" -GEXPECT_LATENCY="$latency" \
    --top-module tb_soc_throughput >"$log" 2>&1; then
    tail -n 30 "$log"
    exit 1
fi
if ! "$out_dir/Vtb_soc_throughput" >>"$log" 2>&1; then
    tail -n 30 "$log"
    exit 1
fi
if grep -Eq '(%Fatal|%Error|Assertion failed)' "$log"; then
    tail -n 30 "$log"
    exit 1
fi
grep -E '^(THROUGHPUT |SCENARIO PASS |PASS tb_soc_throughput )' "$log"
grep -q "^PASS tb_soc_throughput RV${xlen} " "$log"
