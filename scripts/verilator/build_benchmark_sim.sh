#!/usr/bin/env bash
set -euo pipefail

xlen="$1"
sim_dir="build/verilator/benchmark-rv${xlen}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"

mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "${sim_dir}" logs
verilator -Wall -Wno-fatal --timing --binary \
    -DCORE_XLEN="${xlen}" \
    -Mdir "${sim_dir}" \
    -f scripts/sim_files.f \
    tb/common/store_result_monitor.sv \
    tb/benchmark/tb_benchmark.sv \
    --top-module tb_benchmark \
    >"logs/benchmark-build-rv${xlen}.log" 2>&1
