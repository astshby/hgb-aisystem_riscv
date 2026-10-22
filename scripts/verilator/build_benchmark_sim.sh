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
host_cflags=()
if [[ "${div_impl}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi
if [[ "$core_backend" == scoreboard ]]; then host_cflags=(-CFLAGS -O1); fi
extra_sources=()
extra_options=()
if [[ "$core_backend" == scoreboard ]]; then
    extra_sources+=(tb/common/scoreboard_metrics.sv tb/benchmark/bind_scoreboard_metrics.sv
                    tb/common/scoreboard_scheduler_metrics.sv tb/benchmark/bind_scheduler_metrics.sv)
fi
if [[ "${SOC:-0}" == "1" ]]; then
    extra_sources+=(tb/soc/axi_memory_model.sv tb/soc/axi_block_memory_model.sv)
    extra_options+=("-GDDR_BYTES=${SOC_DDR_BYTES:-0}" "-GDDR_MODEL_BYTES=${bench_ddr_model_bytes}" "-GDCACHE_ENABLE=${SOC_DCACHE_ENABLE:-1}"
                    "-GCLOCK_HZ=${bench_clock_hz}" "-GUART_DIVISOR=${bench_uart_divisor}"
                    "-GLOCAL_TCM_ENABLE=${bench_local_tcm_enable}"
                    "-GDMA_WIDE_ENABLE=${bench_dma_wide_enable}"
                    "-GDMA_BLOCK_ENABLE=${bench_dma_block_enable}"
                    "-GCACHE_BLOCK_ENABLE=${bench_cache_block_enable}"
                    "-GSOC_PROFILE=${bench_soc_profile_id}")
fi
verilator -Wall -Wno-fatal --assert --timing --binary -j 2 \
    "${core_microarch_flags[@]}" \
    "${host_cflags[@]}" \
    -DCORE_XLEN="${xlen}" \
    -DCORE_MUL_IMPL="${mul_impl}" -DCORE_DIV_IMPL="${div_impl}" \
    -Mdir "${sim_dir}" \
    -f "${bench_files}" \
    tb/common/store_result_monitor.sv \
    "${extra_sources[@]}" "${bench_tb}" \
    "${extra_options[@]}" --top-module "${bench_top}" \
    >"logs/benchmark-build-rv${xlen}-${config}.log" 2>&1
