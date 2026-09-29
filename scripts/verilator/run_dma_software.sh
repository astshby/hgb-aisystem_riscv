#!/usr/bin/env bash
set -euo pipefail

xlen="${1:-32}"
tool_prefix="${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-"
mkdir -p logs
for ddr_bytes in 0 65536; do
    export SOC=1 SOC_DDR_BYTES="${ddr_bytes}"
    config="m${MUL_IMPL:-0}d${DIV_IMPL:-0}"
    source scripts/verilator/benchmark_platform.sh
    image_dir="build/benchmark/soc-dma-rv${xlen}-${config}"
    sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
    log="logs/soc-dma-rv${xlen}-${config}.log"
    bash scripts/verilator/build_benchmark_sim.sh "${xlen}"
    bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${image_dir}" \
        -march="rv${xlen}im_zicsr_zifencei" -DSOC_DDR_BYTES="${ddr_bytes}" tb/soc/irq_crt0.S tb/soc/dma_smoke.c \
        benchmark/bsp/runtime.c benchmark/bsp/softarith.c \
        >"logs/soc-dma-build-rv${xlen}-${config}.log" 2>&1
    tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
    console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
    "${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
        +TOHOST="${tohost_addr}" +CONSOLE="${console_addr}" \
        +TEST="soc-dma-ddr${ddr_bytes}" +MAX_CYCLES=2000000 >"${log}" 2>&1
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then
        tail -n 20 "${log}"
        exit 1
    fi
    grep "PASS soc-dma-ddr${ddr_bytes} RV${xlen}" "${log}"
done
