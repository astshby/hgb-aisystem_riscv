#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
xlen="${1:-32}"
source scripts/rt-thread/sim_config.sh
app="${RT_APP:-smoke}"
out="build/verilator/rt-thread-rv$xlen-${rt_sim_tag}"
top=tb_rt_thread
if [[ "$app" == coremark ]]; then
    out="build/verilator/rt-thread-coremark-rv$xlen-${rt_sim_tag}"
    top=tb_rt_thread_coremark
fi
host_cflags=()
if [[ "${DIV_IMPL:-0}" == 1 ]]; then host_cflags=(-CFLAGS -O0); fi
if [[ -n "${RT_HOST_OPT:-}" ]]; then host_cflags=(-CFLAGS "$RT_HOST_OPT"); fi
mkdir -p "$out" logs build/ccache-tmp build/ccache
export CCACHE_TEMPDIR="$PWD/build/ccache-tmp" CCACHE_DIR="$PWD/build/ccache"
verilator "${core_microarch_flags[@]}" -Wall -Wno-fatal --assert --timing --binary --output-split-cfuncs 500 "${host_cflags[@]}" -DCORE_XLEN="$xlen" \
    -DCORE_MUL_IMPL="${MUL_IMPL:-0}" -DCORE_DIV_IMPL="${DIV_IMPL:-0}" \
    -Mdir "$out" -f scripts/soc_files.f tb/common/store_result_monitor.sv \
    tb/soc/axi_memory_model.sv tb/soc/axi_block_memory_model.sv tb/soc/tb_soc_benchmark.sv tb/soc/tb_rt_thread.sv \
    tb/soc/tb_rt_thread_coremark.sv \
    -GLOCAL_TCM_ENABLE="$local_tcm" \
    -GCACHE_BLOCK_ENABLE="$cache_block" -GDMA_WIDE_ENABLE="$dma_wide" -GDMA_BLOCK_ENABLE="$dma_block" \
    -GSOC_PROFILE="$soc_profile_id" \
    --top-module "$top" > "logs/rt-thread-$app-sim-build-rv$xlen-${rt_sim_tag}.log" 2>&1 || {
    tail -n 50 "logs/rt-thread-$app-sim-build-rv$xlen-${rt_sim_tag}.log"; exit 1;
}
