#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
[[ "$xlen" =~ ^(32|64)$ ]] || { echo 'Usage: bash scripts/verilator/run_dma_block_software.sh [32|64]' >&2; exit 2; }
export SOC=1 SOC_DDR_BYTES=65536 SOC_LOCAL_TCM_ENABLE="${SOC_LOCAL_TCM_ENABLE:-1}"
export SOC_DMA_WIDE_ENABLE=1 SOC_DMA_BLOCK_ENABLE=1 SOC_CACHE_BLOCK_ENABLE=1
export ISSUE_WIDTH=2 RETIRE_ENTRIES="${RETIRE_ENTRIES:-8}" MUL_IMPL=0 DIV_IMPL=1
export PREDICTOR_MODE="${PREDICTOR_MODE:-1}" RAS_ENABLE="${RAS_ENABLE:-1}"
tool_prefix="${RISCV_TOOL_ROOT:?set RISCV_TOOL_ROOT to the toolchain bin directory}/riscv64-unknown-elf-"
config="m${MUL_IMPL}d${DIV_IMPL}"
source scripts/verilator/benchmark_platform.sh
image_dir="build/benchmark/soc-dma-block-rv${xlen}-${config}"
sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
log="logs/soc-dma-block-rv${xlen}-${config}.log"
build_log="logs/benchmark-build-rv${xlen}-${config}.log"
mkdir -p logs

# 使用公共 SoC harness/BSP；它必须真正传播块开关，不能静默运行旧单拍模型。
[[ "${bench_dma_block_enable:-unset}" == 1 ]] || {
    echo 'FAIL benchmark platform does not propagate SOC_DMA_BLOCK_ENABLE' >&2; exit 2;
}
if ! bash scripts/verilator/build_benchmark_sim.sh "$xlen"; then
    tail -n 35 "$build_log"; exit 1;
fi
if grep -Eq '(%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)|%Error)' "$build_log"; then
    grep -E '(%Warning-(UNOPTFLAT|LATCH|MULTIDRIVEN|ALWCOMBORDER)|%Error)' "$build_log"; exit 1;
fi
if ! bash scripts/verilator/build_benchmark_image.sh "$xlen" "$image_dir" \
    -march="rv${xlen}im_zicsr_zifencei" -Wall -Wextra -Werror \
    benchmark/bsp/crt0.S tb/soc/dma_block_smoke.c \
    benchmark/bsp/runtime.c benchmark/bsp/softarith.c \
    >"logs/soc-dma-block-build-rv${xlen}-${config}.log" 2>&1; then
    tail -n 35 "logs/soc-dma-block-build-rv${xlen}-${config}.log"; exit 1;
fi
tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
[[ -n "$tohost_addr" && -n "$console_addr" ]] || { echo 'FAIL missing BSP result symbols'; exit 1; }
if ! "${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
    +TOHOST="$tohost_addr" +CONSOLE="$console_addr" +TEST=soc-dma-block \
    +MAX_CYCLES=6000000 +DMA_BLOCK_CHECK >"$log" 2>&1; then
    tail -n 40 "$log"; exit 1;
fi
if grep -Eq '(%Fatal|%Error|Assertion failed)' "$log"; then tail -n 40 "$log"; exit 1; fi
grep "PASS soc-dma-block RV${xlen}" "$log"
grep '^PASS DMA_BLOCK_AXI' "$log"
[[ "$(grep -c '^DMA BLOCK .* OK$' "$log")" == 6 ]] || {
    echo 'FAIL missing byte-checked software cases'; tail -n 40 "$log"; exit 1;
}
