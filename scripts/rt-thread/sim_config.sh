# Shared RT simulation-only hardware selection; software layout and BSP ABI are separate.
source scripts/verilator/core_build_config.sh
source scripts/soc_profile.sh
local_tcm="${SOC_LOCAL_TCM_ENABLE:-0}"
cache_block="${SOC_CACHE_BLOCK_ENABLE:-0}"
dma_wide="${SOC_DMA_WIDE_ENABLE:-0}"
dma_block="${SOC_DMA_BLOCK_ENABLE:-0}"
for rt_option in "$local_tcm" "$cache_block" "$dma_wide" "$dma_block"; do
    [[ "$rt_option" =~ ^[01]$ ]] || { echo 'invalid RT SoC hardware option (expected 0 or 1)' >&2; return 2; }
done
rt_sim_tag="${core_build_tag}-p${soc_profile}-ltcm${local_tcm}-cb${cache_block}-dw${dma_wide}-db${dma_block}"
