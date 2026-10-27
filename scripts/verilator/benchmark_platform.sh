# Shared platform selection for benchmark build/run scripts (source after config).
source scripts/verilator/core_build_config.sh
config="${config}-${core_build_tag}"
bench_top=tb_benchmark
bench_tb=tb/benchmark/tb_benchmark.sv
bench_files=scripts/sim_files.f
source scripts/soc_profile.sh
# 供固定 ELF replay 工具读取实际模型参数；它不是冻结软件镜像的兼容条件。
bench_soc_profile="$soc_profile"
bench_soc_profile_id="$soc_profile_id"
bench_local_tcm_enable="${SOC_LOCAL_TCM_ENABLE:-0}"
bench_dma_wide_enable="${SOC_DMA_WIDE_ENABLE:-0}"
bench_dma_block_enable="${SOC_DMA_BLOCK_ENABLE:-0}"
[[ "$bench_dma_block_enable" =~ ^[01]$ ]] || { echo 'SOC_DMA_BLOCK_ENABLE must be 0 or 1' >&2; exit 2; }
bench_cache_block_enable="${SOC_CACHE_BLOCK_ENABLE:-0}"
bench_ddr_model_bytes="${SOC_DDR_MODEL_BYTES:-${SOC_DDR_BYTES:-0}}"
bench_mm3_accel_enable="${SOC_MM3_ACCEL_ENABLE:-0}"
bench_mm3_mac_lanes="${MM3_MAC_LANES:-16}"
[[ "$bench_mm3_accel_enable" =~ ^[01]$ && "$bench_mm3_mac_lanes" =~ ^(1|2|4|8|16|32)$ ]] || { echo "Invalid MiniMind accelerator configuration" >&2; exit 2; }
bench_clock_hz="${SOC_CLOCK_HZ:-50000000}"
bench_uart_divisor="${SOC_UART_DIVISOR:-434}"
[[ "$bench_ddr_model_bytes" =~ ^[0-9]+$ ]] || { echo 'SOC_DDR_MODEL_BYTES must be a nonnegative integer' >&2; exit 2; }
[[ "$bench_clock_hz" =~ ^[1-9][0-9]*$ && "$bench_uart_divisor" =~ ^[1-9][0-9]*$ ]] || {
    echo 'SOC_CLOCK_HZ and SOC_UART_DIVISOR must be positive integers' >&2; exit 2;
}
[[ "$bench_cache_block_enable" =~ ^[01]$ ]] || { echo 'SOC_CACHE_BLOCK_ENABLE must be 0 or 1' >&2; exit 2; }
[[ "$bench_dma_wide_enable" =~ ^[01]$ ]] || { echo 'SOC_DMA_WIDE_ENABLE must be 0 or 1' >&2; exit 2; }
[[ "$bench_local_tcm_enable" =~ ^[01]$ ]] || { echo 'SOC_LOCAL_TCM_ENABLE must be 0 or 1' >&2; exit 2; }
if [[ "${SOC:-0}" == "1" ]]; then
    # SOC_LOCAL_TCM_ENABLE 只选择硬件冷热接线；0/1 模型目录必须隔离，软件 ISA 不变。
    config="${config}-soc-p${bench_soc_profile}-ltcm${bench_local_tcm_enable}"
    config="${config}-dw${bench_dma_wide_enable}-cb${bench_cache_block_enable}-db${bench_dma_block_enable}"
    if [[ "${SOC_DDR_BYTES:-0}" != 0 ]]; then
        config="${config}-ddr${SOC_DDR_BYTES}"
    fi
    if [[ "$bench_ddr_model_bytes" != "${SOC_DDR_BYTES:-0}" ]]; then
        config="${config}-modelmem${bench_ddr_model_bytes}"
    fi
    if [[ "$bench_clock_hz" != 50000000 || "$bench_uart_divisor" != 434 ]]; then
        config="${config}-clk${bench_clock_hz}-uart${bench_uart_divisor}"
    fi
    if [[ "${SOC_DCACHE_ENABLE:-1}" != 1 ]]; then
        config="${config}-dcache${SOC_DCACHE_ENABLE}"
    fi
    if [[ "$bench_mm3_accel_enable" == 1 ]]; then config="${config}-mm3l${bench_mm3_mac_lanes}"; fi
    bench_top=tb_soc_benchmark
    bench_tb=tb/soc/tb_soc_benchmark.sv
    bench_files=scripts/soc_files.f
    if [[ "$core_backend" == scoreboard && "$bench_mm3_accel_enable" == 0 ]]; then
        config="${config}-axi4"
        bench_top=tb_soc_system
        bench_tb=tb/soc/tb_soc_system.sv
    fi
fi
