#!/usr/bin/env bash
set -euo pipefail

xlen="$1"
mul_impl="${MUL_IMPL:-0}"
div_impl="${DIV_IMPL:-0}"
config="m${mul_impl}d${div_impl}"
source scripts/verilator/benchmark_platform.sh
sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
export CCACHE_TEMPDIR="${PWD}/build/ccache-tmp"
export CCACHE_DIR="${PWD}/build/ccache"

mkdir -p "${CCACHE_TEMPDIR}" "${CCACHE_DIR}" "${sim_dir}" logs
extra_sources=()
extra_options=()
if [[ "${SOC:-0}" == "1" ]]; then
    extra_sources+=(tb/soc/axi_memory_model.sv)
    extra_options+=("-GDDR_BYTES=${SOC_DDR_BYTES:-0}" "-GDCACHE_ENABLE=${SOC_DCACHE_ENABLE:-1}")
fi
verilator -Wall -Wno-fatal --assert --timing --binary \
    -DCORE_XLEN="${xlen}" \
    -DCORE_MUL_IMPL="${mul_impl}" -DCORE_DIV_IMPL="${div_impl}" \
    -Mdir "${sim_dir}" \
    -f "${bench_files}" \
    tb/common/store_result_monitor.sv \
    "${extra_sources[@]}" "${bench_tb}" \
    "${extra_options[@]}" --top-module "${bench_top}" \
    >"logs/benchmark-build-rv${xlen}-${config}.log" 2>&1
