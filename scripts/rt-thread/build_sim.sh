#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
out="build/verilator/rt-thread-rv$xlen"
mkdir -p "$out" logs build/ccache-tmp build/ccache
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
verilator -Wall -Wno-fatal --assert --timing --binary -DCORE_XLEN="$xlen" \
    -Mdir "$out" -f scripts/soc_files.f tb/common/store_result_monitor.sv \
    tb/soc/axi_memory_model.sv tb/soc/tb_soc_benchmark.sv tb/soc/tb_rt_thread.sv \
    --top-module tb_rt_thread > "logs/rt-thread-sim-build-rv$xlen.log" 2>&1 || {
    tail -n 50 "logs/rt-thread-sim-build-rv$xlen.log"; exit 1;
}
