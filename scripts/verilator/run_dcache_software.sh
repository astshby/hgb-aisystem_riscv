#!/usr/bin/env bash
set -euo pipefail
xlen="${1:-32}"
tool_prefix="${RISCV_TOOL_ROOT:-/opt/riscv/bin}/riscv64-unknown-elf-"
export SOC=1 SOC_DDR_BYTES=65536
printf -v fault_addr '%x' "$((0x80000100 + xlen/8))"
mkdir -p logs
for enabled in 1 0; do
    export SOC_DCACHE_ENABLE="${enabled}"
    config="m${MUL_IMPL:-0}d${DIV_IMPL:-0}"
    source scripts/verilator/benchmark_platform.sh
    image_dir="build/benchmark/soc-dcache-rv${xlen}-${config}"
    sim_dir="build/verilator/benchmark-rv${xlen}-${config}"
    log="logs/soc-dcache-rv${xlen}-${config}.log"
    bash scripts/verilator/build_benchmark_sim.sh "${xlen}"
    bash scripts/verilator/build_benchmark_image.sh "${xlen}" "${image_dir}" \
        -march="rv${xlen}im_zicsr_zifencei" -DTEST_DCACHE_ENABLE="${enabled}" \
        benchmark/bsp/crt0.S tb/cache/dcache_smoke.c benchmark/bsp/runtime.c benchmark/bsp/softarith.c \
        >"logs/soc-dcache-build-rv${xlen}-${config}.log" 2>&1
    tohost_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "tohost" { print $1; exit }')"
    console_addr="$("${tool_prefix}nm" -n "${image_dir}/program.elf" | awk '$3 == "sim_console" { print $1; exit }')"
    "${sim_dir}/V${bench_top}" +IMEM="${image_dir}/imem.hex" +DMEM="${image_dir}/dmem.hex" \
        +TOHOST="${tohost_addr}" +CONSOLE="${console_addr}" +DCACHE_CHECKS +FAULT_WRITE="${fault_addr}" \
        +TEST="soc-dcache-${enabled}" +MAX_CYCLES=2000000 >"${log}" 2>&1 || { tail -n 20 "${log}"; exit 1; }
    if grep -Eq '(%Fatal|%Error|Assertion failed)' "${log}"; then tail -n 20 "${log}"; exit 1; fi
    grep -E '^(PASS soc-dcache|DCACHE )' "${log}"
done
